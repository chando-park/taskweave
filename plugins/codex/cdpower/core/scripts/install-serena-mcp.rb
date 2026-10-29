#!/usr/bin/env ruby

require "json"
require "optparse"
require "open3"
require "fileutils"
require "rbconfig"
require "securerandom"

module SerenaMcpInstall
  VERSION = "1.5.3".freeze
  HELPERS = %w[serena-project.rb serena-mcp.rb].freeze

  class CommandError < StandardError
    attr_reader :output

    def initialize(output)
      @output = output
      super("host command failed")
    end
  end

  class Installer
    def initialize(home: Dir.home, source: __dir__, runner: nil, path: ENV.fetch("PATH", ""))
      @home = File.expand_path(home)
      @source = source
      @path = path
      @runner = runner || lambda do |command, *arguments|
        env = { "HOME" => @home, "CLAUDE_CONFIG_DIR" => nil }
        env["CODEX_HOME"] = File.directory?(File.join(@home, ".codex")) ? File.join(@home, ".codex") : nil
        stdout, stderr, status = Open3.capture3(env, command, *arguments, chdir: @home)
        raise CommandError, stdout + stderr unless status.success?
        stdout
      end
      @destination = File.join(@home, ".local/share/ai-workflow/tools/serena-mcp")
    end

    def executable(name)
      @path.split(File::PATH_SEPARATOR).map { |directory| File.join(directory, name) }.find { |file| File.file?(file) && File.executable?(file) }
    end

    def run(client: "both", apply: false, check: false)
      hosts = client == "both" ? %w[codex claude] : [client]
      raise "client must be codex|claude|both" unless (hosts - %w[codex claude]).empty?
      registrations = hosts.to_h { |host| [host, registration(host)] }
      registrations.each { |host, registration| validate_registration(host, registration) }
      registered_commands = hosts.to_h do |host|
        candidate = installed_command(registrations[host])
        [host, candidate && File.file?(candidate) && File.executable?(candidate) ? candidate : nil]
      end
      command = executable("serena") || registered_commands.values.compact.first
      # Each host keeps its working executable; PATH supplies only unregistered/missing ones.
      commands = hosts.to_h { |host| [host, registered_commands[host] || command] }
      uv = command ? nil : executable("uv")
      result = { "schema" => "serena-mcp-install-v1", "client" => client, "dry_run" => !apply, "check" => check, "version_if_installed" => VERSION,
                 "serena" => command ? "reuse" : "missing", "managed_directory" => @destination,
                 "clients" => hosts.to_h { |host| [host, { "registration" => registration_kind(host, registrations[host]), "action" => "register-user-wrapper" }] },
                 "commands" => command || check ? [] : [[uv || "uv", "tool", "install", "serena-agent==#{VERSION}"]] }
      hosts.each { |host| planned_config(host, registrations[host], commands[host] || "/pending/serena") }
      result["commands"] += hosts.map { |host| ["user-mcp-config", host, RbConfig.ruby, *wrapper_args(host, commands[host] || "/pending/serena")] } unless check
      return result if check || !apply
      raise "uv is required to install Serena; install uv separately" if !command && !uv
      # Validate every migration before downloading or changing any host configuration.
      HELPERS.each { |name| raise "missing runtime helper: #{name}" unless File.file?(File.join(@source, name)) }
      lock = File.join(@destination, ".install-lock")
      FileUtils.mkdir_p(@destination, mode: 0o700)
      raise "managed directory symlink is not supported" if File.symlink?(@destination)
      begin
        Dir.mkdir(lock)
      rescue Errno::EEXIST
        raise "another Serena installation is running"
      end
      begin
        unless command
          @runner.call(uv, "tool", "install", "serena-agent==#{VERSION}")
          command = executable("serena")
          unless command
            bin = @runner.call(uv, "tool", "dir", "--bin").strip
            candidate = File.join(bin, "serena")
            command = candidate if File.file?(candidate) && File.executable?(candidate)
          end
          raise "uv installed no executable Serena entrypoint" unless command
        end
        hosts.each { |host| commands[host] ||= command }
        HELPERS.each do |name|
          destination = File.join(@destination, name)
          raise "managed helper symlink is not supported" if File.symlink?(destination)
          temporary = "#{destination}.#{SecureRandom.hex(6)}.tmp"
          File.write(temporary, File.binread(File.join(@source, name)), mode: "wb", perm: 0o600)
          File.rename(temporary, destination)
        end
        backups = {}
        hosts.each do |host|
          # Refuse concurrent edits discovered since the read-only planning phase.
          current = registration(host)
          raise "#{host}: registration changed during installation" unless current == registrations[host]
          file, before, after = planned_config(host, current, commands[host])
          next if before == after
          FileUtils.mkdir_p(File.dirname(file), mode: 0o700)
          if before
            backup = "#{file}.serena-backup-#{SecureRandom.hex(6)}"
            File.write(backup, before, mode: "wb", perm: 0o600)
            backups[host] = backup
          end
          temporary = "#{file}.serena-#{SecureRandom.hex(6)}.tmp"
          File.write(temporary, after, mode: "wb", perm: File.exist?(file) ? File.stat(file).mode & 0o777 : 0o600)
          File.rename(temporary, file)
        end
        result.merge("dry_run" => false, "serena" => command, "serena_commands" => commands, "backups" => backups, "requires_fresh_session" => true)
      ensure
        Dir.rmdir(lock)
      end
    end

    def registration(host)
      raise "#{host} CLI is required" unless executable(host)
      if host == "codex"
        output = @runner.call(executable(host), "mcp", "get", "serena", "--json")
        JSON.parse(output)
      else
        file = File.join(@home, ".claude.json")
        config = File.exist?(file) ? JSON.parse(File.read(file)) : {}
        entry = config.fetch("mcpServers", {})["serena"]
        # The host can resolve a project registration shadowing the user scope.
        output = @runner.call(executable(host), "mcp", "get", "serena")
        raise "claude: only user-scope Serena may be managed" unless output.include?("Scope: User config")
        raise "claude: user registration could not be read" unless entry
        entry
      end
    rescue CommandError => error
      missing = host == "codex" ? error.output.include?("No MCP server named 'serena' found.") : error.output.include?('No MCP server found with name: "serena".')
      raise "#{host}: cannot inspect Serena registration" unless missing
      if host == "claude"
        file = File.join(@home, ".claude.json")
        config = File.exist?(file) ? JSON.parse(File.read(file)) : {}
        raise "claude: host/config registration mismatch" if config.fetch("mcpServers", {}).key?("serena")
      end
      nil
    end

    def installed_command(registration)
      return nil unless registration
      transport = registration["transport"] || registration
      return transport["args"][2] if transport["command"] == RbConfig.ruby && transport.fetch("args", [])[0] == File.join(@destination, "serena-mcp.rb")
      raw_command(registration)
    end

    def raw_command(registration)
      return nil unless registration
      transport = registration["transport"] || registration
      args = transport["args"]
      transport["command"] if args.is_a?(Array) && args.first == "start-mcp-server"
    end

    def wrapper_args(host, command)
      [File.join(@destination, "serena-mcp.rb"), "--serena-command", command, "--context=#{host == 'codex' ? 'codex' : 'claude-code'}", "--project-from-cwd"]
    end

    def registration_kind(host, registration)
      return "absent" unless registration
      transport = registration["transport"] || registration
      return "managed-wrapper" if transport["command"] == RbConfig.ruby && transport["args"] == wrapper_args(host, transport.fetch("args", [])[2])
      return "known-raw" if raw_command(registration) && File.basename(transport["command"]) == "serena" && transport["args"] == ["start-mcp-server", "--context=#{host == 'codex' ? 'codex' : 'claude-code'}", "--project-from-cwd"] && (!transport["type"] || transport["type"] == "stdio")
      "custom"
    end

    def validate_registration(host, registration)
      raise "#{host}: custom Serena registration preserved; migrate it manually" if registration_kind(host, registration) == "custom"
    end

    def planned_config(host, registration, command)
      file = File.join(@home, host == "codex" ? ".codex/config.toml" : ".claude.json")
      raise "#{host}: config symlink preserved" if File.symlink?(file)
      before = File.exist?(file) ? File.read(file, encoding: "UTF-8") : nil
      args = wrapper_args(host, command)
      if host == "claude"
        config = before ? JSON.parse(before) : {}
        config["mcpServers"] ||= {}
        config["mcpServers"]["serena"] = (registration || { "type" => "stdio" }).merge("command" => RbConfig.ruby, "args" => args)
        return [file, before, "#{JSON.pretty_generate(config)}\n"]
      end
      text = before || ""
      replacement = "command = #{JSON.generate(RbConfig.ruby)}\nargs = #{JSON.generate(args)}\n"
      unless registration
        raise "codex: existing Serena table could not be verified" if text.match?(/^\s*\[.*mcp_servers.*(?:serena|["'])/)
        return [file, before, "#{text}#{text.end_with?("\n") || text.empty? ? '' : "\n"}\n[mcp_servers.serena]\n#{replacement}"]
      end
      # Host JSON is authoritative. Limit text editing to conventional single-line
      # command/args values; preserve all other TOML bytes rather than reserializing it.
      raise "codex: multiline TOML requires manual migration" if text.include?('"""') || text.include?("'''")
      matches = text.enum_for(:scan, /^\[mcp_servers\.serena\][ \t]*(?:#[^\n]*)?\n(.*?)(?=^\s*\[|\z)/m).map { Regexp.last_match }
      raise "codex: unsupported or ambiguous Serena table" unless matches.length == 1
      match = matches.first
      body = match[1]
      transport = registration.fetch("transport")
      %w[command args].each do |key|
        lines = body.lines.select { |line| line.match?(/^#{key}\s*=/) }
        raise "codex: #{key} must be a single-line JSON-compatible TOML value" unless lines.length == 1
        value = lines.first.sub(/^#{key}\s*=\s*/, "").strip
        raise "codex: #{key} value differs from host configuration" unless JSON.parse(value) == transport[key]
        body = body.sub(lines.first, "#{key} = #{JSON.generate(key == 'command' ? RbConfig.ruby : args)}\n")
      end
      [file, before, text[0...match.begin(1)] + body + text[match.end(1)..]]
    rescue JSON::ParserError
      raise "#{host}: unsupported configuration; original preserved"
    end
  end

  def self.main(argv)
    options = { client: "both", apply: false, check: false }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: install-serena-mcp --client codex|claude|both [--apply|--install|--check|--dry-run]"
      opts.on("--client CLIENT") { |value| options[:client] = value }
      opts.on("--apply") { options[:apply] = true }
      opts.on("--install") { options[:apply] = true }
      opts.on("--check") { options[:check] = true }
      opts.on("--dry-run") { options[:dry_run] = true }
    end
    parser.parse!(argv)
    raise "unexpected arguments" unless argv.empty?
    options[:apply] = false if options.delete(:dry_run) || options[:check]
    puts JSON.pretty_generate(Installer.new.run(**options))
  rescue StandardError => error
    warn JSON.generate("schema" => "serena-mcp-install-v1", "status" => "error", "error" => error.message)
    1
  end
end

exit(SerenaMcpInstall.main(ARGV) || 0) if $PROGRAM_NAME == __FILE__
