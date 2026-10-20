#!/usr/bin/env ruby

require "json"
require "pathname"

root = Pathname.new(ARGV.fetch(0)).expand_path
provider = ARGV.fetch(1)

candidates = case provider
             when "gitlab"
               [
                 root.join(".gitlab/merge_request_templates/Default.md"),
                 *root.glob(".gitlab/merge_request_templates/*.md").sort,
                 root.join(".gitlab/merge_request_template.md")
               ]
             when "github"
               [
                 root.join(".github/PULL_REQUEST_TEMPLATE.md"),
                 root.join(".github/pull_request_template.md"),
                 *root.glob(".github/PULL_REQUEST_TEMPLATE/*.md").sort
               ]
             else
               warn "ERROR: 지원하지 않는 provider입니다: #{provider}"
               exit 1
             end

selected = candidates.uniq.find(&:file?)
puts JSON.pretty_generate(
  "source" => selected ? "official" : "fallback",
  "path" => selected&.realpath&.to_s
)
