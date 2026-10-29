#!/usr/bin/env ruby

require "optparse"
require "pathname"
require_relative "workplan-layout"

options = { root: nil }
OptionParser.new do |parser|
  parser.on("--root PATH") { |value| options[:root] = value }
end.parse!

abort "usage: report-workplan-complexity.rb --root <Workplans>" unless options[:root]
root = Pathname(options[:root]).expand_path

puts "id\tdescription_lines\tcode_ids\tcurrent_layout\trecommended_layout"
root.glob("*/*.md").select { |path| path.basename(".md").to_s == path.dirname.basename.to_s }.sort.each do |main|
  _raw, data = WorkplanLayout.frontmatter(main.read(encoding: "UTF-8"))
  documents = WorkplanLayout.detail_documents(main, data)
  description = documents["description"]&.file? ? documents["description"].read(encoding: "UTF-8") : ""
  code_source = documents.fetch("code_plan", documents["description"])
  code_text = code_source&.file? ? code_source.read(encoding: "UTF-8") : ""
  lines = description.lines.count { |line| !line.strip.empty? }
  code_ids = code_text.scan(/^\|\s*(CODE-\d+)\s*\|/).flatten.uniq.size
  recommended = lines > 120 || code_ids > 2 ? "split-v1" : "compact-v1"
  puts [data.fetch("id"), lines, code_ids, data["detail_layout"] || "legacy", recommended].join("\t")
end
