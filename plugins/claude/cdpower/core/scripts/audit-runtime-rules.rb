#!/usr/bin/env ruby

require "pathname"
require "yaml"

runtime = Pathname(__dir__).parent
registry = Pathname(ARGV.fetch(0, runtime.join("runtime-rules.yml").to_s)).expand_path
data = YAML.safe_load(registry.read, permitted_classes: [], aliases: false) || {}
abort "unsupported rule registry schema" unless data["schema_version"] == 1

statuses = %w[documented_only connected behavior_test_declared]
rules = data.fetch("rules")
abort "rules must be an array" unless rules.is_a?(Array)

connection_count = 0
behavior_test_count = 0
mapping_test_count = 0

rules.each do |rule|
  id = rule.fetch("id")
  status = rule.fetch("status")
  abort "invalid status for #{id}: #{status}" unless statuses.include?(status)

  definition = runtime.join(rule.fetch("definition"))
  abort "missing definition for #{id}: #{definition}" unless definition.file?

  connections = rule.fetch("connections", [])
  behavior_tests = rule.fetch("gate_behavior_tests", [])
  mapping_tests = rule.fetch("mapping_tests", [])
  abort "#{id} is connected without consumers" if status != "documented_only" && connections.empty?
  if status == "behavior_test_declared" && behavior_tests.empty?
    abort "#{id} declares gate behavior evidence without behavior test entries"
  end
  if status != "behavior_test_declared" && behavior_tests.any?
    abort "#{id} declares gate behavior tests but status is #{status}"
  end

  connections.each do |connection|
    path = runtime.join(connection.fetch("path"))
    abort "missing connection for #{id}: #{path}" unless path.file?
    marker = connection.fetch("marker")
    content = path.read.gsub(/"(\$\{AI_RUNTIME_BIN:-\$HOME\/\.codex\/bin\}\/[a-z-]+)"/, '\\1')
    abort "disconnected rule #{id}: #{path} lacks #{marker.inspect}" unless content.include?(marker)
    connection_count += 1
  end

  { "gate behavior" => behavior_tests, "mapping" => mapping_tests }.each do |kind, entries|
    entries.each do |entry|
    path = runtime.join(entry.fetch("path"))
      abort "missing #{kind} test declaration for #{id}: #{path}" unless path.file?
    test_name = entry.fetch("test")
      abort "missing #{kind} test entry #{test_name} for #{id}" unless path.read.include?(test_name)
      kind == "gate behavior" ? behavior_test_count += 1 : mapping_test_count += 1
    end
  end
end

puts "Runtime rule declaration audit passed (#{rules.length} rules)."
puts "Connection marker declarations: #{connection_count}"
puts "Gate behavior test entry declarations: #{behavior_test_count}"
puts "Mapping test entry declarations: #{mapping_test_count}"
puts "Actual gate runs and agent dispatches: not inspected by this audit."
