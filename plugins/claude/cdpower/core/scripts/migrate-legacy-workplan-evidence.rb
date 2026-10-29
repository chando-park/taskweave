#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "open3"
require "optparse"
require "pathname"
require "time"
require "yaml"
require_relative "workplan-layout"

RUNTIME_TARGETS = {
  "BUG-20260814-CENTRAL-PROJECT-AGENT-ROUTING" => ["20_AI/Codex/Runtime/scripts/resolve-workplan-policy.rb"],
  "BUG-20260814-DESIGN-SYSTEM-WORKPLAN-HANDOFF" => ["20_AI/Codex/Runtime/references/design-system-implementation-contract.md"],
  "BUG-20260814-PROJECT-BASELINE-INVESTIGATION-ROUTING" => ["20_AI/Codex/Runtime/skills/project-baseline/SKILL.md"],
  "BUG-20260814-QUERY-SCOPE-EVIDENCE-LEAK" => ["20_AI/Codex/Runtime/references/query-evidence-contract.md"],
  "BUG-20260814-UI-MIGRATION-SCOPE-BOUNDARY" => ["20_AI/Codex/Runtime/skills/plan-ui-with-design-system/SKILL.md"],
  "BUG-20260818-COMPLETION-STATE-AND-USER-INTENT-DRIFT" => ["20_AI/Codex/Runtime/references/execution-contract.md"],
  "BUG-20260818-FIGMA-COMPONENT-SOURCE-GATE" => ["20_AI/Codex/Runtime/references/design-system-implementation-contract.md"],
  "BUG-20260818-FIGMA-DESIGN-CONTEXT-GATE-MISSING" => ["20_AI/Codex/Runtime/references/context-pack.md"],
  "BUG-20260819-FIGMA-SOURCE-INTERPRETATION-DRIFT" => ["20_AI/Codex/Runtime/references/design-system-implementation-contract.md"],
  "BUG-20260819-TARGET-PLATFORM-VERIFICATION-GATE" => ["20_AI/Codex/Runtime/references/verification-evidence.md"],
  "BUG-20260820-WORKPLAN-LIFECYCLE-BUNDLE-MIGRATION" => ["20_AI/Codex/Runtime/references/workplan-layout.md"],
  "FEATURE-20260819-SELECTIVE-CONTEXT-LOADING" => ["20_AI/Codex/Runtime/references/context-profiles.yaml"],
  "FEATURE-DESIGN-SYSTEM-BASELINE-DISCOVERY" => ["20_AI/Codex/Runtime/skills/project-baseline/references/baseline-contract.md"],
  "FEATURE-DESIGN-SYSTEM-COMPONENT-WORKFLOW" => ["20_AI/Codex/Runtime/skills/plan-design-system-component/SKILL.md"],
  "FEATURE-DESIGN-SYSTEM-MINIMUM-VERIFICATION" => [],
  "FEATURE-DESIGN-SYSTEM-PLAN-APPLY-INSTALLATION" => ["20_AI/Codex/Runtime/scripts/install.sh"],
  "FEATURE-DESIGN-SYSTEM-UI-ORCHESTRATION" => ["20_AI/Codex/Runtime/skills/implement-ui-with-design-system/SKILL.md"],
  "PERSONAL-LLM-EXECUTION-CONTRACT-V2" => ["20_AI/Codex/Runtime/references/execution-contract.md"],
  "PERSONAL-LLM-RUNTIME-REGRESSION-REPAIR" => ["20_AI/Codex/Runtime/references/company-workplan-adapter.md"]
}.freeze

START_MARKER = "<!-- legacy-original:start -->\n"
END_MARKER = "<!-- legacy-original:end -->"

def remove_key(raw, key)
  lines = raw.lines
  index = lines.index { |line| line.match?(/^#{Regexp.escape(key)}:/) }
  return raw unless index

  lines.delete_at(index)
  lines.delete_at(index) while index < lines.length && lines[index].match?(/^\s+-\s/)
  lines.join
end

def upsert_scalar(raw, key, value)
  line = "#{key}: #{value}\n"
  return raw.sub(/^#{Regexp.escape(key)}:.*\n/, line) if raw.match?(/^#{Regexp.escape(key)}:/)

  raw.rstrip + "\n#{line}"
end

def upsert_list(raw, key, values)
  raw = remove_key(raw, key)
  rendered = values.empty? ? "#{key}: []\n" : "#{key}:\n#{values.map { |value| "  - #{value}\n" }.join}"
  raw.rstrip + "\n#{rendered}"
end

def demote_headings(text)
  text.lines.map { |line| line.sub(/\A(#+)(\s)/) { "#{$1}##{$2}" } }.join
end

def revision(script, main)
  stdout, stderr, status = Open3.capture3("ruby", script.to_s, main.to_s)
  raise stderr.strip unless status.success?

  stdout.strip
end

options = { apply: false }
OptionParser.new do |parser|
  parser.on("--root PATH") { |value| options[:root] = value }
  parser.on("--apply") { options[:apply] = true }
end.parse!

begin
  root = Pathname(options.fetch(:root)).expand_path
  revision_script = Pathname(__dir__).join("workplan-approval-revision.rb")
  timestamp = Time.now.iso8601
  bundles = root.glob("*/*.md").select do |main|
    main.basename(".md").to_s == main.dirname.basename.to_s && main.dirname.join("Evidence").directory?
  end.sort
  raise "migration target mapping이 누락되었습니다" unless (bundles.map { |main| main.basename(".md").to_s } - RUNTIME_TARGETS.keys).empty?

  bundles.each do |main|
    original_main = main.read(encoding: "UTF-8")
    raw, data = WorkplanLayout.frontmatter(original_main)
    id = data.fetch("id")
    evidence = main.dirname.join("Evidence")
    required = %w[original.md investigation.md change.md verification.md].map { |name| evidence.join(name) }
    missing = required.reject(&:file?)
    raise "Evidence 파일 누락: #{missing.join(', ')}" unless missing.empty?

    original = evidence.join("original.md").read(encoding: "UTF-8")
    expected_sha = data.fetch("legacy_source_sha256")
    actual_sha = Digest::SHA256.hexdigest(original)
    raise "legacy 원문 SHA 불일치: #{id}" unless expected_sha == actual_sha

    stored_revision = data["approval_revision"].to_s
    before_revision = revision(revision_script, main) unless stored_revision.empty?
    raise "승인 revision 불일치: #{id}" if before_revision && before_revision != stored_revision

    status = data.fetch("status")
    authority = WorkplanLayout::COMPLETED.include?(status) ? "historical_record" : "proposal"
    changed_raw = raw.dup
    %w[evidence_root legacy_source migrated_at].each { |key| changed_raw = remove_key(changed_raw, key) }
    changed_raw = changed_raw.sub(/^legacy_source_sha256:/, "legacy_original_sha256:")
    changed_raw = upsert_scalar(changed_raw, "details_root", "Details")
    changed_raw = upsert_scalar(changed_raw, "authority_status", authority)
    changed_raw = upsert_list(changed_raw, "runtime_targets", RUNTIME_TARGETS.fetch(id))
    changed_raw = upsert_scalar(changed_raw, "development_status", status == "superseded" ? "completed" : status) unless data.key?("development_status")
    changed_raw = upsert_scalar(changed_raw, "legacy_metadata_status", "partial") if data["approved_at"].to_s.empty? && WorkplanLayout::COMPLETED.include?(status)
    changed_raw = upsert_scalar(changed_raw, "last_reviewed_at", %("#{timestamp}")) unless WorkplanLayout::COMPLETED.include?(status)
    if data["approval_basis"]
      changed_raw = upsert_scalar(changed_raw, "approval_basis", "Details/description.md")
      changed_raw = upsert_scalar(changed_raw, "approval_basis_payload", "legacy-original")
    end

    body = original_main.sub(/\A---\s*\n.*?\n---\s*\n/m, "")
    body = body.gsub(%r{Evidence/original\.md}, "Details/description.md")
               .gsub(%r{Evidence/investigation\.md}, "Details/description.md")
               .gsub(%r{Evidence/change\.md}, "Details/change.md")
               .gsub(%r{Evidence/verification\.md}, "Details/verification.md")
               .gsub(
                 "## 상세 근거\n- [원문](Details/description.md)\n- [조사](Details/description.md)\n",
                 "## 문서\n- [작업 설명](Details/description.md)\n"
               )
    changed_main = "---\n#{changed_raw.rstrip}\n---\n#{body}"

    investigation = evidence.join("investigation.md").read(encoding: "UTF-8")
    description = <<~MD
      # #{id} 작업 설명

      ## 보존된 legacy 원문

      #{START_MARKER}#{original}#{END_MARKER}

      ## 추가 조사 기록

      #{demote_headings(investigation).strip}
    MD
    change = evidence.join("change.md").read(encoding: "UTF-8").gsub("original.md", "description.md")
    verification = evidence.join("verification.md").read(encoding: "UTF-8").gsub("original.md", "description.md")

    puts [id, status, actual_sha, stored_revision.empty? ? "approval=legacy-unavailable" : "approval=#{stored_revision}"].join("\t")
    next unless options[:apply]

    details = main.dirname.join("Details")
    raise "Details가 이미 존재합니다: #{details}" if details.exist?
    temporary = main.dirname.join(".Details.migration-#{Process.pid}")
    begin
      temporary.mkpath
      temporary.join("description.md").write(description, encoding: "UTF-8")
      temporary.join("change.md").write(change, encoding: "UTF-8")
      temporary.join("verification.md").write(verification, encoding: "UTF-8")
      FileUtils.mv(temporary, details)
      main.write(changed_main, encoding: "UTF-8")

      extracted = details.join("description.md").read(encoding: "UTF-8").split(START_MARKER, 2).fetch(1).split(END_MARKER, 2).fetch(0)
      raise "migration 후 원문 SHA 불일치: #{id}" unless Digest::SHA256.hexdigest(extracted) == actual_sha
      after_revision = revision(revision_script, main) unless stored_revision.empty?
      raise "migration 후 승인 revision 불일치: #{id}" if after_revision && after_revision != stored_revision
      FileUtils.rm_rf(evidence)
    rescue StandardError
      main.write(original_main, encoding: "UTF-8")
      FileUtils.rm_rf(details)
      FileUtils.rm_rf(temporary)
      raise
    end
  end

  puts "OK: #{bundles.size} legacy Evidence bundles #{options[:apply] ? 'migrated' : 'validated'}"
rescue KeyError, RuntimeError, Errno::ENOENT, IndexError => error
  warn error.message
  exit 1
end
