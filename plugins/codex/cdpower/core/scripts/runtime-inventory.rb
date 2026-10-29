#!/usr/bin/env ruby

require "optparse"
require "yaml"

options = {}
OptionParser.new do |parser|
  parser.on("--inventory PATH") { |value| options[:inventory] = value }
  parser.on("--kind KIND") { |value| options[:kind] = value }
end.parse!

abort "ERROR: --inventory is required" unless options[:inventory]
supported_kinds = %w[personal-skill company-skill bin client platform]
abort "ERROR: --kind must be #{supported_kinds.join(', ')}" unless supported_kinds.include?(options[:kind])

inventory = YAML.safe_load(File.read(options[:inventory], encoding: "UTF-8"), permitted_classes: [], aliases: false)
abort "ERROR: unsupported inventory schema" unless inventory.is_a?(Hash) && inventory["schema_version"] == 2

case options[:kind]
when "personal-skill"
  Array(inventory.dig("personal", "skills")).each { |name| puts name }
when "company-skill"
  Array(inventory.dig("company", "skills")).each { |name| puts name }
when "bin"
  Hash(inventory.dig("personal", "bins")).each { |name, path| puts "#{name}\t#{path}" }
when "client"
  Hash(inventory.fetch("clients", {})).each do |name, adapter|
    abort "ERROR: invalid client adapter: #{name}" unless adapter.is_a?(Hash) && adapter["installer"].is_a?(String) && adapter["doctor"].is_a?(String)
    puts "#{name}\t#{adapter.fetch('installer')}\t#{adapter.fetch('doctor')}"
  end
when "platform"
  Hash(inventory.fetch("platforms", {})).each do |name, adapter|
    abort "ERROR: invalid platform adapter: #{name}" unless adapter.is_a?(Hash) && adapter["mode"].is_a?(String)
    puts [
      name,
      adapter.fetch("mode"),
      adapter.fetch("installer", ""),
      Array(adapter["required_commands"]).join(","),
      Array(adapter["optional_commands"]).join(",")
    ].join("\t")
  end
end
