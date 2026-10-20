#!/usr/bin/env ruby

require "fileutils"
require "json"
require "open3"
require "pathname"
require "securerandom"
require "yaml"

module SerenaProject
  EXCLUDES = %w[.git .serena node_modules Pods Carthage vendor build .build dist .gradle DerivedData .idea .next .venv venv __pycache__ target].freeze
  EXTENSIONS = {
    "swift" => "swift", "kt" => "kotlin", "kts" => "kotlin", "java" => "java",
    "js" => "typescript", "jsx" => "typescript", "mjs" => "typescript", "cjs" => "typescript",
    "ts" => "typescript", "tsx" => "typescript", "mts" => "typescript", "cts" => "typescript",
    "py" => "python", "pyi" => "python", "rb" => "ruby", "sh" => "bash", "bash" => "bash",
    "rs" => "rust", "go" => "go", "dart" => "dart", "cs" => "csharp", "php" => "php",
    "c" => "cpp", "h" => "cpp", "cc" => "cpp", "cpp" => "cpp", "cxx" => "cpp", "hpp" => "cpp",
    "m" => "cpp", "mm" => "cpp", "ex" => "elixir", "exs" => "elixir", "jl" => "julia",
    "lua" => "lua", "scala" => "scala", "sc" => "scala", "pl" => "perl", "pm" => "perl",
    "r" => "r", "clj" => "clojure", "cljs" => "clojure", "tf" => "terraform", "zig" => "zig"
  }.freeze

  def self.git_root(directory)
    output, _, status = Open3.capture3("git", "-C", directory.to_s, "rev-parse", "--show-toplevel")
    status.success? ? Pathname(output.strip).realpath : nil
  end

  def self.plugin_cache?(directory)
    directory.to_s.match?(%r{/(?:\.codex|\.claude)/plugins/(?:cache|marketplaces)(?:/|$)})
  end

  def self.detect(repository)
    output, error, status = Open3.capture3("git", "-C", repository.to_s, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
    raise "Git source detection failed: #{error.strip}" unless status.success?

    output.split("\0").uniq.map do |relative|
      parts = relative.split("/")
      next if parts.any? { |part| EXCLUDES.include?(part) } || relative.end_with?(".gradle.kts")
      current = repository
      next if parts.any? { |part| current = current.join(part); current.symlink? }
      next unless current.file?

      EXTENSIONS[File.extname(relative).delete_prefix(".").downcase]
    end.compact.uniq.sort
  end

  def self.prepare(repository)
    repository = Pathname(repository).expand_path.realpath
    raise "repository must equal the Git root" unless git_root(repository) == repository
    raise "plugin cache cannot be a Serena project" if plugin_cache?(repository)

    directory = repository.join(".serena")
    raise "Serena directory must not be a symlink" if directory.symlink?
    FileUtils.mkdir_p(directory)
    raise "Serena directory escaped repository" unless directory.realpath == directory

    lock_path = directory.join(".ai-workflow-project.lock")
    flags = File::RDWR | File::CREAT | File::NOFOLLOW
    File.open(lock_path, flags, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      filename = directory.join("project.yml")
      raise "Serena project.yml must not be a symlink" if filename.symlink?
      original = filename.exist? ? filename.read : ""
      data = original.empty? ? {} : YAML.safe_load(original, aliases: false)
      document = original.empty? ? nil : Psych.parse(original) || nil
      mapping = document&.root
      data = {} if data.nil? && mapping.nil?
      raise "Serena project.yml must be a YAML mapping" unless data.is_a?(Hash)
      raise "Serena project.yml must contain one YAML document" if !original.empty? && Psych.parse_stream(original).children.length > 1
      keys = mapping&.children&.each_slice(2)&.map { |key, _| key.value } || []
      raise "Serena project.yml contains duplicate keys" unless keys.uniq == keys
      lists = %w[languages language_servers].to_h do |key|
        value = data[key]
        if data.key?(key) && (!value.is_a?(Array) || value.any? { |language| !language.is_a?(String) || language.strip.empty? })
          raise "#{key} must be a list of language names"
        end
        [key, value]
      end
      explicit = lists.values.compact.reject(&:empty?)
      raise "languages and language_servers disagree; reconcile the explicit lists" if explicit.length == 2 && explicit[0] != explicit[1]
      legacy = data["language"]
      raise "language must be a language name" if data.key?("language") && (!legacy.is_a?(String) || legacy.strip.empty?)
      languages = explicit.first || (legacy ? [legacy] : detect(repository))
      changes = lists.map { |key, value| [key, languages] if value.nil? || (value.empty? && !languages.empty?) }.compact.to_h
      changes["project_name"] = repository.basename.to_s unless data.key?("project_name")
      changes["encoding"] = "utf-8" unless data.key?("encoding")
      updated = patch(original, mapping, changes)
      if updated != original
        raise "Serena project.yml changed during preparation" if filename.exist? && filename.read != original
        temporary = directory.join(".project-#{SecureRandom.hex(8)}.tmp")
        begin
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, filename.exist? ? filename.stat.mode & 0o777 : 0o644) do |file|
            file.write(updated)
            file.flush
            file.fsync
          end
          File.rename(temporary, filename)
        ensure
          FileUtils.rm_f(temporary)
        end
      end
      { "status" => original.empty? ? "created" : updated == original ? "unchanged" : "updated", "path" => filename.to_s, "languages" => languages }
    end
  rescue Psych::Exception => error
    raise "Invalid Serena project.yml; preserved existing file: #{error.message}"
  end

  def self.patch(original, mapping, changes)
    updated = original.dup
    replacements = []
    mapping&.children&.each_slice(2) do |key, value|
      next unless changes.key?(key.value)

      lines = original.lines
      start = lines.take(value.start_line).sum(&:length) + value.start_column
      finish = lines.take(value.end_line).sum(&:length) + value.end_column
      replacements << [start, finish, JSON.generate(changes.delete(key.value))]
    end
    replacements.sort_by(&:first).reverse_each { |start, finish, value| updated[start...finish] = value }
    unless changes.empty?
      # 기존 주석과 표기를 보존하며 YAML 문서 끝 표시 앞에 키를 추가한다.
      insertion = changes.map { |key, value| "#{key}: #{JSON.generate(value)}\n" }.join
      if mapping&.style == Psych::Nodes::Mapping::FLOW
        closing = original.lines.take(mapping.end_line).sum(&:length) + mapping.end_column - 1
        closing += replacements.sum { |start, finish, value| start < closing ? value.length - (finish - start) : 0 }
        values = changes.map { |key, value| "#{JSON.generate(key)}: #{JSON.generate(value)}" }.join(", ")
        updated.insert(closing, "#{mapping.children.empty? ? '' : ', '}#{values}")
        return updated
      end
      ending = updated.match(/^\.\.\.[ \t]*(?:#.*)?(?:\r?\n|\z)/)
      position = ending ? ending.begin(0) : updated.length
      insertion = "\n#{insertion}" if position.positive? && updated[position - 1] != "\n"
      updated.insert(position, insertion)
    end
    updated
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    require "optparse"
    repository = nil
    OptionParser.new { |opts| opts.on("--repository PATH") { |value| repository = value } }.parse!
    raise "--repository is required" unless repository
    puts JSON.generate(SerenaProject.prepare(repository))
  rescue StandardError => error
    warn "Serena project preparation failed: #{error.message}"
    exit 1
  end
end
