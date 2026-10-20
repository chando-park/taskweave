#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

ruby "$runtime_root/scripts/audit-runtime-rules.rb"

for test_file in "$runtime_root"/tests/*_test.rb; do
    ruby "$test_file"
done

for shell_file in "$runtime_root"/scripts/*.sh; do
    sh -n "$shell_file"
done

ruby -ryaml -e '
  ARGV.each do |path|
    text = File.read(path, encoding: "UTF-8")
    match = text.match(/\A---\n(.*?)\n---\n/m) or abort("missing skill frontmatter: #{path}")
    data = YAML.safe_load(match[1], permitted_classes: [], aliases: false) || {}
    abort("missing skill name: #{path}") if data["name"].to_s.empty?
    abort("missing skill description: #{path}") if data["description"].to_s.empty?
  end
' "$runtime_root"/skills/*/SKILL.md

ruby -e '
  expected = {
    "general-terra" => "gpt-5.6-terra",
    "routine-luna" => "gpt-5.6-luna",
    "high-risk-sol" => "gpt-5.6-sol",
    "ui-spark" => "gpt-5.6-luna"
  }
  root = ARGV.fetch(0)
  expected.each do |name, model|
    path = File.join(root, "#{name}.toml")
    text = File.read(path, encoding: "UTF-8")
    values = text.scan(/^(name|description|model|model_reasoning_effort|developer_instructions)\s*=\s*"(.*)"$/).to_h
    abort("invalid agent name: #{path}") unless values["name"] == name
    abort("invalid agent model: #{path}") unless values["model"] == model
    abort("missing agent instructions: #{path}") if values["developer_instructions"].to_s.empty?
  end
' "$runtime_root/agents"

echo "Runtime verification passed."
