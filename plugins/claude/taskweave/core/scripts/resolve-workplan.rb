#!/usr/bin/env ruby

require "optparse"
require_relative "workplan-layout"

options = {}
OptionParser.new do |parser|
  parser.on("--root PATH") { |value| options[:root] = value }
  parser.on("--view VIEW", %w[any current history]) { |value| options[:view] = value }
end.parse!

begin
  root = options.fetch(:root)
  id = ARGV.fetch(0)
  puts WorkplanLayout.resolve(root, id, view: options.fetch(:view, "any")).expand_path
rescue KeyError, IndexError, RuntimeError => error
  warn error.message
  exit 1
end
