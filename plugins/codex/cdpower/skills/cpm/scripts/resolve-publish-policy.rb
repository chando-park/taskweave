#!/usr/bin/env ruby

require "json"
require "optparse"

class PolicyError < StandardError; end

options = { mode: "commit" }
OptionParser.new do |parser|
  parser.on("--mode MODE") { |value| options[:mode] = value }
  parser.on("--provider PROVIDER") { |value| options[:provider] = value }
  parser.on("--workspace-type TYPE") { |value| options[:workspace_type] = value }
  parser.on("--explicit-target BRANCH") { |value| options[:explicit_target] = value }
  parser.on("--existing-target BRANCH") { |value| options[:existing_target] = value }
  parser.on("--repository-target BRANCH") { |value| options[:repository_target] = value }
  parser.on("--repository-target-source SOURCE") { |value| options[:repository_target_source] = value }
  parser.on("--remote-default BRANCH") { |value| options[:remote_default] = value }
  parser.on("--existing-url URL") { |value| options[:existing_url] = value }
  parser.on("--explicit-reviewer USER") { |value| options[:explicit_reviewer] = value }
  parser.on("--repository-reviewer USER") { |value| options[:repository_reviewer] = value }
  parser.on("--global-reviewer USER") { |value| options[:global_reviewer] = value }
end.parse!

begin
  mode = options.fetch(:mode)
  raise PolicyError, "지원하지 않는 mode입니다: #{mode}" unless %w[commit commit-push commit-push-mr].include?(mode)

  result = {
    "mode" => mode,
    "action" => mode == "commit" ? "commit" : "push",
    "target" => nil,
    "reviewer" => nil,
    "questions" => []
  }

  if mode == "commit-push-mr"
    provider = options[:provider]
    raise PolicyError, "commit-push-mr에는 provider가 필요합니다." unless %w[github gitlab].include?(provider)

    targets = [
      [options[:explicit_target], "explicit"],
      [options[:existing_target], "existing"],
      [options[:repository_target], options[:repository_target_source] || "repository"]
    ]
    targets << [options[:remote_default], "remote_default"] unless options[:workspace_type] == "company-project"
    target, target_source = targets.find { |value, _source| !value.to_s.empty? }
    result["target"] = { "value" => target, "source" => target_source, "confirmed" => !target.nil? }
    result["questions"] << "target branch를 지정해 주세요." unless target

    if options[:existing_url]
      result["action"] = "reuse_existing"
      result["existing_url"] = options[:existing_url]
      if options[:explicit_target] && options[:existing_target] && options[:explicit_target] != options[:existing_target]
        result["action"] = "update_existing"
        result["questions"] << "기존 PR/MR의 target 변경을 확인해 주세요."
      end
    else
      result["action"] = "create"
    end

    reviewers = if options[:existing_url]
                  [[options[:explicit_reviewer], "explicit", true]]
                else
                  [
                    [options[:explicit_reviewer], "explicit", true],
                    [options[:repository_reviewer], "repository", true],
                    [options[:global_reviewer], "global", false]
                  ]
                end
    reviewer, reviewer_source, reviewer_confirmed = reviewers.find { |value, _source, _confirmed| !value.to_s.empty? }
    if reviewer
      result["reviewer"] = {
        "value" => reviewer,
        "source" => reviewer_source,
        "confirmed" => reviewer_confirmed
      }
      result["action"] = "update_existing" if options[:existing_url]
      result["questions"] << "전역 reviewer 추천을 확정해 주세요." unless reviewer_confirmed
    elsif provider == "gitlab" && !options[:existing_url]
      result["questions"] << "GitLab reviewer를 지정해 주세요."
    end
  end

  result["ready"] = result.fetch("questions").empty?
  puts JSON.pretty_generate(result)
rescue PolicyError => error
  warn JSON.generate("error" => error.message)
  exit 1
end
