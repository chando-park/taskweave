#!/usr/bin/env ruby

require "optparse"
require_relative "workplan-layout"

options = {}
OptionParser.new { |parser| parser.on("--root PATH") { |value| options[:root] = value } }.parse!

begin
  root = Pathname(options.fetch(:root)).expand_path
  id = ARGV.fetch(0)
  current = WorkplanLayout.resolve(root, id)
  _raw, data = WorkplanLayout.frontmatter(current.read(encoding: "UTF-8"))
  WorkplanLayout.state_group(data.fetch("status"))
  target_bundle = WorkplanLayout.bundle_directory(root, data)
  current_bundle = current.dirname
  raise "legacy flat Workplan은 먼저 migration해야 합니다: #{current}" unless current_bundle.basename.to_s == id

  raise "고정 bundle 경로가 아닙니다. migration이 필요합니다: #{current}" unless current_bundle == target_bundle
  puts current
rescue KeyError, IndexError, RuntimeError, Errno::ENOENT => error
  warn error.message
  exit 1
end
