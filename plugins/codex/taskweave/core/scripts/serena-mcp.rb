#!/usr/bin/env ruby

require_relative "serena-project"

begin
  arguments = ARGV.dup
  command_index = arguments.index("--serena-command")
  raise "--serena-command <absolute Serena executable> is required" unless command_index
  command = arguments[command_index + 1]
  raise "Serena executable must be an absolute executable file" unless command && Pathname(command).absolute? && File.file?(command) && File.executable?(command)
  raise "Serena executable points to wrapper" if File.realpath(command) == File.realpath(__FILE__)
  arguments.slice!(command_index, 2)
  arguments.shift if arguments.first == "start-mcp-server"
  project = nil
  project_index = nil
  from_cwd = arguments.include?("--project-from-cwd")
  arguments.each_with_index do |argument, index|
    next unless %w[--project --project-file].include?(argument) || argument.start_with?("--project=", "--project-file=")
    raise "Multiple project selectors are not supported" if project
    project_index = index
    project = argument.include?("=") ? argument.split("=", 2).last : arguments[index + 1]
    raise "Project selector requires a value" if project.nil? || project.empty? || project.start_with?("--")
  end
  raise "--project-from-cwd cannot be combined with --project" if from_cwd && project

  root = nil
  if project
    if File.directory?(project)
      root = SerenaProject.git_root(File.realpath(project))
      raise "Explicit project path is not a Git repository" unless root
    elsif project.include?(File::SEPARATOR) || project.start_with?(".")
      raise "Explicit project path does not exist: #{project}"
    end
  elsif from_cwd
    root = SerenaProject.git_root(Dir.pwd)
    root = nil if SerenaProject.plugin_cache?(Dir.pwd)
  end
  if root
    SerenaProject.prepare(root)
    if project_index
      count = arguments[project_index].include?("=") ? 1 : 2
      arguments.slice!(project_index, count)
    end
    arguments.delete("--project-from-cwd")
    arguments.concat(["--project", root.to_s])
  elsif from_cwd
    # 중립 cwd에서는 Serena의 cwd fallback이 설정 파일을 생성하지 않게 한다.
    arguments.delete("--project-from-cwd")
  end
  exec(command, "start-mcp-server", *arguments)
rescue StandardError => error
  warn "Serena MCP startup failed: #{error.message}"
  exit 1
end
