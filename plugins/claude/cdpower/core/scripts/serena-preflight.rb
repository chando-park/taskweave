#!/usr/bin/env ruby

require "json"
require "optparse"
require "open3"
require "pathname"
require_relative "serena-project"

REQUIRED_TOOLS = %w[
  initial_instructions
  activate_project
  get_symbols_overview
  find_symbol
  find_referencing_symbols
].freeze

options = { mode: nil, repository: nil, tools: [] }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: serena-preflight --mode semantic|textual --repository <Git-root> [--available-tool NAME ...]"
  opts.on("--mode MODE") { |value| options[:mode] = value }
  opts.on("--repository PATH") { |value| options[:repository] = value }
  opts.on("--available-tool NAME") { |value| options[:tools] << value }
end

begin
  parser.parse!
  raise OptionParser::InvalidArgument, "mode must be semantic or textual" unless %w[semantic textual].include?(options[:mode])
  raise OptionParser::MissingArgument, "repository" if options[:repository].to_s.empty?

  repository = Pathname(options[:repository]).expand_path
  raise "repository must be an existing directory" unless repository.directory?
  stdout, status = Open3.capture2("git", "-C", repository.to_s, "rev-parse", "--show-toplevel")
  raise "repository must be a Git worktree" unless status.success?
  git_root = Pathname(stdout.strip).realpath
  raise "repository must equal the Git root" unless repository.realpath == git_root

  normalized_tools = options[:tools].map { |name| name.to_s.split("__").last }.uniq.sort
  missing = options[:mode] == "semantic" ? REQUIRED_TOOLS - normalized_tools : []
  project = SerenaProject.prepare(git_root) if options[:mode] == "semantic" && missing.empty?
  result = {
    "schema" => "serena-preflight-v1",
    "mode" => options[:mode],
    "repository_root" => git_root.to_s,
    "semantic_required" => options[:mode] == "semantic",
    "required_tools" => options[:mode] == "semantic" ? REQUIRED_TOOLS : [],
    "available_tools" => normalized_tools,
    "missing_tools" => missing,
    "status" => missing.empty? ? "ready" : "blocked"
  }
  result["project"] = project if project
  puts JSON.pretty_generate(result)
  exit(missing.empty? ? 0 : 2)
rescue StandardError => error
  warn JSON.generate("schema" => "serena-preflight-v1", "status" => "invalid", "error" => error.message)
  exit 1
end
