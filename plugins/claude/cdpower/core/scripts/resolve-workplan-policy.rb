#!/usr/bin/env ruby

require "json"
require "open3"
require "optparse"
require "pathname"

class PolicyError < StandardError; end

options = {}
OptionParser.new do |parser|
  parser.banner = "Usage: resolve-workplan-policy.rb [repository] --kind bug|feature|investigation"
  parser.on("--kind KIND") { |value| options[:kind] = value }
end.parse!

begin
  kind = options[:kind]
  raise PolicyError, "kind는 bug, feature 또는 investigation이어야 합니다." unless %w[bug feature investigation].include?(kind)

  repository = Pathname.new(ARGV.shift || Dir.pwd).expand_path
  context_script = Pathname.new(__dir__).join("resolve-task-context.rb").realpath
  stdout, stderr, status = Open3.capture3("ruby", context_script.to_s, repository.to_s, "--require-workplan")
  raise PolicyError, stderr.strip unless status.success?
  context = JSON.parse(stdout)

  workspace_type = context.fetch("workspace_type")
  repository_root = Pathname.new(context.fetch("repository_root"))
  repository_agent = repository_root.join("AGENTS.md")
  root = Pathname.new(ENV.fetch("WORKPLAN_ROOT", context.fetch("workplan_root"))).expand_path.cleanpath
  root = root.realpath if root.exist?
  if ENV.key?("WORKPLAN_ROOT")
    # 회사의 옛 링크와 관리 위치가 같은 문서를 가리키면 같은 프로젝트다.
    # 정확히 확인한 현재 프로젝트 루트만 예외로 허용한다.
    registered_root = Pathname.new(context.fetch("workplan_root")).expand_path.cleanpath
    registered_root = registered_root.realpath if registered_root.exist?
    allowed_root = if workspace_type == "personal-system"
                     Pathname.new(context.fetch("repository_root"))
                   elsif workspace_type == "managed-project"
                     Pathname.new(context.fetch("workplan_root"))
                   else
                     Pathname.new(context.fetch("company_workspace"))
                   end
    allowed_root = allowed_root.realpath if allowed_root.exist?
    allowed_prefix = allowed_root.to_s + File::SEPARATOR
    unless root == registered_root || root == allowed_root || root.to_s.start_with?(allowed_prefix)
      raise PolicyError, "WORKPLAN_ROOT가 허용된 작업공간 밖을 가리킵니다: #{root}"
    end
  end

  case workspace_type
  when "managed-project"
    agent = Pathname.new(context.fetch("project_agent"))
    policy = {
      "workspace_type" => workspace_type,
      "project_id" => context.fetch("project_id"),
      "repository" => context.fetch("repository"),
      "remote" => context["remote"],
      "workplan_layout" => "stable-bundle-v1",
      "workplan_schema" => "approval-memo-v1",
      "workplan_memo_script" => Pathname.new(__dir__).join("workplan-memo.rb").realpath.to_s,
      "workplan_search_root" => root.to_s,
      "workplan_directory" => root.to_s,
      "repository_agent" => repository_agent.file? ? repository_agent.realpath.to_s : nil,
      "project_agent" => agent.file? ? agent.realpath.to_s : nil,
      "ticket_policy" => "none",
      "workplan_sync" => false,
      "workplan_sync_script" => nil,
      "post_verify_hook" => false,
      "post_verify_hook_script" => nil,
      "completion_adapter" => nil,
      "team_wiki" => nil,
      "product_memory" => context.fetch("product_memory")
    }
  when "personal-system"
    policy = {
      "workspace_type" => workspace_type,
      "project_id" => context.fetch("project_id"),
      "repository" => context.fetch("repository"),
      "remote" => context.fetch("remote"),
      "workplan_layout" => "stable-bundle-v1",
      "workplan_schema" => context.fetch("workplan_schema", "approval-memo-v1"),
      "workplan_memo_script" => Pathname.new(__dir__).join("workplan-memo.rb").realpath.to_s,
      "workplan_search_root" => root.to_s,
      "workplan_directory" => root.to_s,
      "repository_agent" => repository_agent.file? ? repository_agent.realpath.to_s : nil,
      "project_agent" => nil,
      "ticket_policy" => "none",
      "workplan_sync" => false,
      "workplan_sync_script" => nil,
      "post_verify_hook" => false,
      "post_verify_hook_script" => nil,
      "completion_adapter" => nil,
      "team_wiki" => nil,
      "product_memory" => false
    }
  when "company-project"
    company_root = Pathname.new(context.fetch("company_workspace"))
    sync_script = company_root.join("AI/scripts/workplan-sync.sh")
    hook_script = company_root.join("AI/scripts/post-verify-hook.rb")
    contract_script = company_root.join("AI/scripts/workplan-contract.rb")
    transition_script = company_root.join("AI/scripts/transition-company-workplan.rb")
    workspace_script = company_root.join("AI/scripts/workspace.rb")
    raise PolicyError, "회사 Workplan sync script가 없습니다: #{sync_script}" unless sync_script.file?
    raise PolicyError, "회사 post-verify hook이 없습니다: #{hook_script}" if kind != "investigation" && !hook_script.file?
    raise PolicyError, "회사 Workplan contract가 없습니다: #{contract_script}" unless contract_script.file?
    raise PolicyError, "회사 Workplan transition script가 없습니다: #{transition_script}" unless transition_script.file?
    layout_out, layout_error, layout_status = Open3.capture3("ruby", workspace_script.to_s, "workplan-layout")
    raise PolicyError, layout_error.strip unless layout_status.success?
    raise PolicyError, "지원하지 않는 회사 Workplan layout입니다: #{layout_out.strip}" unless layout_out.strip == "stable-bundle-v1"
    ticket_out, ticket_error, ticket_status = Open3.capture3("ruby", workspace_script.to_s, "ticket-config")
    raise PolicyError, ticket_error.strip unless ticket_status.success?
    ticket_policy = JSON.parse(ticket_out)
    agent_out, agent_error, agent_status = Open3.capture3("ruby", workspace_script.to_s, "project-agent", context.fetch("project_id"))
    raise PolicyError, agent_error.strip unless agent_status.success?
    project_agent = Pathname.new(agent_out.strip)
    product_id_out, product_id_error, product_id_status = Open3.capture3("ruby", workspace_script.to_s, "product-id", context.fetch("project_id"))
    raise PolicyError, product_id_error.strip unless product_id_status.success?
    product_id = product_id_out.strip
    product_agent_out, product_agent_error, product_agent_status = Open3.capture3("ruby", workspace_script.to_s, "product-agent", context.fetch("project_id"))
    raise PolicyError, product_agent_error.strip unless product_agent_status.success?
    product_agent = product_agent_out.strip.empty? ? nil : Pathname.new(product_agent_out.strip)
    owner_out, owner_error, owner_status = Open3.capture3("ruby", workspace_script.to_s, "workplan-owner", context.fetch("project_id"))
    raise PolicyError, owner_error.strip unless owner_status.success?
    workplan_owner = JSON.parse(owner_out)
    principle_out, principle_error, principle_status = Open3.capture3("ruby", workspace_script.to_s, "principle-context", context.fetch("project_id"))
    raise PolicyError, principle_error.strip unless principle_status.success?
    principle_context = JSON.parse(principle_out)
    completion_out, completion_error, completion_status = Open3.capture3("ruby", workspace_script.to_s, "completion-config")
    raise PolicyError, completion_error.strip unless completion_status.success?
    completion_adapter = JSON.parse(completion_out)

    team_wiki = ENV["COMPANY_WIKI"]
    team_wiki = context["team_wiki"] if team_wiki.to_s.empty?
    _remote, _remote_error, remote_status = Open3.capture3("git", "-C", company_root.to_s, "remote", "get-url", "origin")
    policy = {
      "workspace_type" => workspace_type,
      "project_id" => context.fetch("project_id"),
      "repository" => context.fetch("repository"),
      "remote" => context.fetch("remote"),
      "workplan_layout" => "stable-bundle-v1",
      "workplan_schema" => context.fetch("workplan_schema", "approval-memo-v1"),
      "workplan_memo_script" => Pathname.new(__dir__).join("workplan-memo.rb").realpath.to_s,
      "workplan_search_root" => root.to_s,
      "workplan_directory" => root.to_s,
      "workplan_resolver_script" => contract_script.to_s,
      "workplan_transition_script" => transition_script.to_s,
      "repository_agent" => repository_agent.file? ? repository_agent.realpath.to_s : nil,
      "project_agent" => project_agent.file? ? project_agent.realpath.to_s : nil,
      "product_id" => product_id.empty? ? nil : product_id,
      "product_agent" => product_agent&.file? ? product_agent.realpath.to_s : nil,
      "workplan_owner" => workplan_owner,
      "principle_context_resolver_script" => workspace_script.to_s,
      "principle_context" => principle_context,
      "ticket_policy" => ticket_policy,
      "workplan_sync" => remote_status.success?,
      "workplan_sync_script" => sync_script.to_s,
      "post_verify_hook" => kind != "investigation",
      "post_verify_hook_script" => kind == "investigation" ? nil : hook_script.to_s,
      "completion_adapter" => completion_adapter,
      "team_wiki" => team_wiki,
      "product_memory" => !context["product_memory"].to_s.empty?
    }
  else
    raise PolicyError, "지원하지 않는 workspace_type입니다: #{workspace_type}"
  end

  puts JSON.pretty_generate(policy)
rescue PolicyError, JSON::ParserError, KeyError, Errno::ENOENT => error
  warn JSON.generate("error" => error.message)
  exit 1
end
