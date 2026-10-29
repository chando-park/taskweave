#!/usr/bin/env ruby

require "json"
require "open3"
require "optparse"
require "pathname"
require "yaml"

class ContextError < StandardError; end

def capture!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  raise ContextError, stderr.strip.empty? ? "명령 실행 실패: #{command.join(' ')}" : stderr.strip unless status.success?

  stdout.strip
end

def normalize_remote(value)
  remote = value.to_s.strip.sub(/\.git\z/, "")
  if remote.match?(/\Agit@([^:]+):(.+)\z/)
    match = remote.match(/\Agit@([^:]+):(.+)\z/)
    remote = "https://#{match[1]}/#{match[2]}"
  end
  remote.sub(%r{/\z}, "")
end

def load_yaml(path)
  data = YAML.safe_load(path.read, permitted_classes: [], aliases: false)
  raise ContextError, "YAML root가 객체가 아닙니다: #{path}" unless data.is_a?(Hash)

  data
rescue Psych::Exception => error
  raise ContextError, "YAML을 읽을 수 없습니다: #{path}: #{error.message}"
end

# 아직 만들지 않은 관리 폴더도 실제 조상 경로를 기준으로 검사한다.
# 단순 expand_path만 사용하면 중간 symlink를 통해 허용 root 밖으로 나갈 수 있다.
def canonical_location(path)
  path = Pathname.new(path).expand_path
  return path.realpath if path.exist? || path.symlink?

  canonical_location(path.parent).join(path.basename)
end

def registered_project(root)
  registry = ENV["AI_WORKFLOW_REGISTRY"]
  return nil if registry.to_s.empty?

  data = JSON.parse(Pathname.new(registry).read)
  raise ContextError, "지원하지 않는 프로젝트 등록 형식입니다." unless data["schemaVersion"] == 1
  projects = data.fetch("projects")
  project_id = ENV["AI_WORKFLOW_PROJECT_ID"]
  candidates = projects.select do |id, project|
    (project_id.to_s.empty? || id == project_id) && canonical_location(project.fetch("repositoryPath")) == root
  end
  raise ContextError, "등록 프로젝트와 현재 저장소가 일치하지 않습니다." unless candidates.size == 1

  id, project = candidates.first
  raise ContextError, "프로젝트 실행 신뢰 확인이 필요합니다." unless project["executionTrusted"] == true && !project["trustSource"].to_s.strip.empty?
  raise ContextError, "등록 프로젝트 ID가 잘못되었습니다." unless id.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}\z/)
  workspace_id = project.fetch("workspaceId")
  raise ContextError, "작업공간 ID가 잘못되었습니다." unless workspace_id.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}\z/)
  workspace = data.fetch("workspaces").fetch(workspace_id)
  data_root = Pathname.new(ENV.fetch("AI_WORKFLOW_DATA_ROOT", File.expand_path("~/.local/share/ai-workflow")))
  managed = canonical_location(data_root.join("workspaces", workspace_id, "projects", id))
  allowed = [managed]
  allowed << canonical_location(workspace.fetch("root")) if workspace["trusted"] == true
  %w[workplanRoot productMemoryRoot instructionsRoot].each do |key|
    target = canonical_location(project.fetch(key))
    # 회사 정책을 유지한 프로젝트도 Workplan만 공통 관리 위치를 사용한다.
    # 다른 프로젝트의 기록이나 지식·지침 폴더까지 허용하지 않는다.
    default_workplans = if key == "workplanRoot" && data["workplanStorage"] == "managed-default-v1"
                          canonical_location(data_root).join("workspaces/personal/projects", id, "Workplans")
                        end
    unless target == default_workplans || allowed.any? { |base| target == base || target.to_s.start_with?(base.to_s + File::SEPARATOR) }
      raise ContextError, "등록 기록 위치가 신뢰한 작업공간 밖입니다: #{key}"
    end
    if target == root || target.to_s.start_with?(root.to_s + File::SEPARATOR)
      raise ContextError, "제품 저장소 안에는 AI 작업 기록을 만들 수 없습니다."
    end
  end
  { "id" => id, "project" => project, "workspace" => workspace, "managed_root" => managed.to_s }
rescue JSON::ParserError, TypeError => error
  raise ContextError, "프로젝트 등록 정보를 읽을 수 없습니다: #{error.message}"
end

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: resolve-task-context.rb [path] [options]"
  opts.on("--expect-repository NAME") { |value| options[:repository] = value }
  opts.on("--expect-remote URL") { |value| options[:remote] = normalize_remote(value) }
  opts.on("--expect-branch NAME") { |value| options[:branch] = value }
  opts.on("--require-workplan") { options[:require_workplan] = true }
end
parser.parse!

begin
  input = Pathname.new(ARGV.shift || Dir.pwd).expand_path
  root = Pathname.new(capture!("git", "-C", input.to_s, "rev-parse", "--show-toplevel")).realpath
  branch = capture!("git", "-C", root.to_s, "branch", "--show-current")
  remote_raw, = Open3.capture3("git", "-C", root.to_s, "remote", "get-url", "origin")
  remote = normalize_remote(remote_raw)
  repository = root.basename.to_s
  result = {
    "repository" => repository,
    "repository_root" => root.to_s,
    "remote" => remote.empty? ? nil : remote,
    "branch" => branch.empty? ? nil : branch,
    "workspace_type" => "unregistered",
    "project_id" => nil,
    "workplan_root" => nil,
    "write_scope" => root.to_s
  }

  manifest_path = root.join("20_AI/Codex/system.yaml")
  if manifest_path.file?
    manifest = load_yaml(manifest_path)
    schema_version = manifest["schema_version"]
    raise ContextError, "지원하지 않는 system.yaml schema입니다." unless [1, 2, 3].include?(schema_version)
    if schema_version >= 2 && manifest["workplan_layout"] != "stable-bundle-v1"
      raise ContextError, "system.yaml workplan_layout이 stable-bundle-v1이 아닙니다."
    end
    raise ContextError, "system.yaml repository가 실제 저장소와 다릅니다." unless manifest["repository"] == repository
    allowed = Array(manifest["allowed_remotes"]).map { |value| normalize_remote(value) }
    raise ContextError, "system.yaml allowed_remotes가 비어 있습니다." if allowed.empty?
    raise ContextError, "origin이 system.yaml 허용 목록과 다릅니다: #{remote.empty? ? '(없음)' : remote}" unless allowed.include?(remote)
    workplan_root = root.join(manifest.fetch("workplan_root")).cleanpath
    raise ContextError, "Workplan 경로가 저장소 밖을 가리킵니다." unless workplan_root.to_s.start_with?(root.to_s + File::SEPARATOR)
    if schema_version == 3 && workplan_root.basename.to_s != manifest.fetch("system_id")
      raise ContextError, "개인 Workplan root는 system_id 프로젝트 폴더여야 합니다."
    end
    result.merge!(
      "workspace_type" => "personal-system",
      "project_id" => manifest.fetch("system_id"),
      "workplan_root" => workplan_root.to_s,
      "workplan_layout" => manifest["workplan_layout"] || "flat-v1",
      "workplan_schema" => "approval-memo-v1"
    )
  else
    registration = registered_project(root)
    workspace_value = ENV["AI_WORKFLOW_WORKSPACE"] || ENV["COMPANY_WORKSPACE"]
    if registration && registration.fetch("workspace")["trusted"] == true
      workspace_value ||= registration.fetch("workspace").fetch("root")
    elsif registration
      # 관리되지 않은 기존 홈 링크를 찾아 실행하지 않는다.
      workspace_value = registration.fetch("managed_root")
    end
    workspace_value = File.expand_path("~/.codex/company-workspace") if workspace_value.to_s.empty?
    workspace = Pathname.new(workspace_value).expand_path
    resolver = workspace.join("AI/scripts/workspace.rb")
    if resolver.file?
      project_id, _error, project_status = Open3.capture3("ruby", resolver.to_s, "project-id", root.to_s)
      if project_status.success?
        workplan_root = capture!("ruby", resolver.to_s, "workplan-root", root.to_s)
        if registration
          raise ContextError, "회사 정책과 등록 프로젝트 ID가 다릅니다." unless project_id.strip == registration.fetch("id")
          workplan_root = canonical_location(registration.fetch("project").fetch("workplanRoot")).to_s
        end
        team_wiki, _team_error, team_status = Open3.capture3("ruby", resolver.to_s, "team-wiki")
        product_memory, _memory_error, memory_status = Open3.capture3("ruby", resolver.to_s, "product-memory")
        publishing_raw, _publishing_error, publishing_status = Open3.capture3("ruby", resolver.to_s, "publishing-policy", root.to_s)
        publishing_policy = if publishing_status.success?
                              begin
                                JSON.parse(publishing_raw)
                              rescue JSON::ParserError => error
                                raise ContextError, "회사 publishing policy를 읽을 수 없습니다: #{error.message}"
                              end
                            end
        result.merge!(
          "workspace_type" => "company-project",
          "project_id" => project_id.strip,
          "workplan_root" => workplan_root,
          "workplan_schema" => "approval-memo-v1",
          "company_workspace" => workspace.realpath.to_s,
          "team_wiki" => team_status.success? ? team_wiki.strip : nil,
          "product_memory" => memory_status.success? ? product_memory.strip : nil,
          "publishing_policy" => publishing_policy
        )
      end
    end
    if registration && result["workspace_type"] == "unregistered"
      project = registration.fetch("project")
      result.merge!(
        "workspace_type" => "managed-project",
        "project_id" => registration.fetch("id"),
        "workspace_id" => project.fetch("workspaceId"),
        "workplan_root" => canonical_location(project.fetch("workplanRoot")).to_s,
        "workplan_layout" => "stable-bundle-v1",
        "workplan_schema" => "approval-memo-v1",
        "product_memory" => canonical_location(project.fetch("productMemoryRoot")).to_s,
        "project_agent" => canonical_location(project.fetch("instructionsRoot")).join("AGENTS.md").to_s
      )
    end
  end

  raise ContextError, "예상 저장소가 다릅니다: #{options[:repository]} != #{repository}" if options[:repository] && options[:repository] != repository
  raise ContextError, "예상 remote가 다릅니다: #{options[:remote]} != #{remote}" if options[:remote] && options[:remote] != remote
  raise ContextError, "예상 branch가 다릅니다: #{options[:branch]} != #{branch}" if options[:branch] && options[:branch] != branch
  if options[:require_workplan] && result["workplan_root"].nil?
    raise ContextError, "등록된 Workplan 루트를 찾지 못했습니다."
  end

  puts JSON.pretty_generate(result)
rescue ContextError, KeyError, Errno::ENOENT, Errno::ELOOP => error
  warn JSON.generate("error" => error.message)
  exit 1
end
