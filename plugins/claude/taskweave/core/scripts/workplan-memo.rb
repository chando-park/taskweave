#!/usr/bin/env ruby

require "base64"
require "date"
require "digest"
require "json"
require "open3"
require "optparse"
require "pathname"
require "rbconfig"
require "tempfile"
require "time"
require "yaml"
require_relative "workplan-layout"

module WorkplanMemo
  class ValidationError < StandardError; end

  SCHEMA = WorkplanLayout::APPROVAL_MEMO_SCHEMA
  PREPARATION_SCHEMA = "approval-memo-preparation-v1"
  FEEDBACK_PREPARATION_SCHEMA = "approval-memo-feedback-preparation-v1"
  RESULT_SCHEMA = "approval-memo-result-v1"
  SNAPSHOT_RELATIVE = "Artifacts/prepared-scope.json"
  FEEDBACK_SNAPSHOT_RELATIVE = "Artifacts/feedback-prepared-scope.json"
  CORRECTION_SEQUENCE_RELATIVE = "Artifacts/correction-sequence.json"
  COMPLETION_RELATIVE = "Completion.md"
  UI_NONE_EVIDENCE_RELATIVE = "Artifacts/ui-none-evidence.json"
  KINDS = %w[features bugs investigations direct].freeze
  SOURCE_EXTENSIONS = %w[.swift .m .mm .h .hpp .c .cc .cpp .kt .kts .java .js .jsx .ts .tsx .rb .py .go .rs].freeze
  APPROVABLE = %w[awaiting_approval needs_reapproval].freeze
  APPLICABLE = %w[approved].freeze
  RESULT_STATUSES = %w[implementing verifying verification_blocked awaiting_completion].freeze
  RESULT_TARGET_STATUS = {
    "not_run" => "verifying",
    "blocked" => "verification_blocked",
    "passed" => "awaiting_completion"
  }.freeze
  COMPLETION_STATUSES = RESULT_TARGET_STATUS.values.freeze
  SHA256 = /\Asha256:[0-9a-f]{64}\z/

  module_function

  def create(root:, repository:, project_id:, title:, kind:, reason:, scope_paths:, excluded_paths:, verification:, id: nil, slug: nil, jira_key: nil, ui_tier: nil, ui_reason: nil, at: Time.now.iso8601)
    root = Pathname(root).expand_path
    repository = git_root(repository)
    jira_key = jira_key.to_s.strip.upcase unless jira_key.nil?
    if jira_key && !jira_key.match?(/\A[A-Z][A-Z0-9_]*-[1-9][0-9]*\z/)
      raise ValidationError, "--jira-key는 IOS-234와 같은 Jira 티켓 번호여야 합니다"
    end
    id = creation_id(id: id, slug: slug, jira_key: jira_key, at: at)
    jira_key ||= id[/\A\d{8}-([A-Z][A-Z0-9_]*-[1-9][0-9]*)-/, 1]
    raise ValidationError, "지원하지 않는 Workplan kind입니다: #{kind}" unless KINDS.include?(kind)
    raise ValidationError, "title이 비어 있습니다" unless text?(title)
    title = title.strip
    if jira_key && !title.match?(/\A#{Regexp.escape(jira_key)}(?:\z|[\s·:])/)
      title = "#{jira_key} · #{title}"
    end
    raise ValidationError, "resolver project_id가 비어 있습니다" unless text?(project_id)
    raise ValidationError, "변경 이유가 비어 있습니다" unless text?(reason)
    scopes = normalize_paths(scope_paths, repository, "scope")
    exclusions = normalize_paths(excluded_paths, repository, "exclude", allow_missing: true)
    raise ValidationError, "scope path가 비어 있습니다" if scopes.empty?
    raise ValidationError, "scope와 exclude가 겹칩니다: #{(scopes & exclusions).join(', ')}" unless (scopes & exclusions).empty?
    checks = Array(verification).map(&:strip).reject(&:empty?).uniq
    raise ValidationError, "minimal verification이 비어 있습니다" if checks.empty?
    if ui_tier && !%w[none regression conformance full].include?(ui_tier)
      raise ValidationError, "지원하지 않는 UI verification tier입니다: #{ui_tier}"
    end

    timestamp = iso8601!(at)
    root.mkpath
    bundle = root.join(id)
    begin
      Dir.mkdir(bundle)
    rescue Errno::EEXIST
      raise ValidationError, "Workplan bundle 경로가 이미 존재합니다: #{bundle}"
    end

    metadata = {
      "workplan_schema" => SCHEMA,
      "id" => id,
      "project_id" => project_id.strip,
      "title" => title.strip,
      "workplan_kind" => kind,
      "status" => "draft",
      "development_status" => "draft",
      "authority_status" => "proposal",
      "readiness" => "ready",
      "verification_status" => "not_run",
      "knowledge_sync_status" => "not_evaluated",
      "created" => timestamp,
      "updated" => timestamp,
      "repository" => repository.basename.to_s,
      "repository_root" => repository.to_s,
      "reason" => reason.strip,
      "scope_paths" => scopes,
      "excluded_paths" => exclusions,
      "minimal_verification" => checks,
      "verification_plan_required" => %w[features bugs].include?(kind),
      "ui_verification_tier" => ui_tier || "none",
      "ui_verification_required" => !ui_tier.nil?,
      "ui_verification_reason" => text?(ui_reason) ? ui_reason.strip : (ui_tier ? "Explicit UI verification classification" : "No UI source declared for this task"),
      "approval_revision" => nil,
      "approved_at" => nil,
      "approved_by" => nil
    }
    metadata["jira_key"] = jira_key if jira_key
    body = render_memo(id, title, reason, scopes, exclusions, checks, repository, kind)
    workplan = bundle.join("#{id}.md")
    write_exclusive(workplan, render_document(metadata, body))
    { "status" => "created", "workplan" => workplan.to_s, "schema" => SCHEMA }
  rescue StandardError
    Dir.rmdir(bundle) if defined?(bundle) && bundle&.directory? && bundle.children.empty?
    raise
  end

  def prepare(workplan, repository:, at: Time.now.iso8601)
    workplan, data, body = load_memo(workplan)
    repository = matching_repository!(data, repository)
    raise ValidationError, "prepare 가능한 상태가 아닙니다: #{data['status'].inspect}" unless data["status"] == "draft"
    raise ValidationError, "Workplan은 이미 prepare되었습니다" if text?(data["prepared_snapshot"])
    validate_readiness_for_approval!(data)
    validate_memo_content!(data, body, repository)
    validate_plan_concept!(data, body)

    scopes = data.fetch("scope_paths")
    packet = {
      "schema" => PREPARATION_SCHEMA,
      "prepared_at" => iso8601!(at),
      "repository_identity" => repository_identity(repository),
      "targets" => scopes.to_h { |relative| [relative, prepared_fingerprint(repository, relative)] },
      "ambient_dirty_paths" => git_changed_paths(repository) - scopes
    }
    snapshot = workplan.dirname.join(SNAPSHOT_RELATIVE)
    raise ValidationError, "Artifacts parent symlink는 허용하지 않습니다" if snapshot.dirname.symlink?
    snapshot.dirname.mkpath
    unless snapshot.dirname.realpath.relative_path_from(workplan.dirname.realpath).to_s == "Artifacts"
      raise ValidationError, "Artifacts parent가 Workplan bundle 밖입니다"
    end
    write_exclusive(snapshot, JSON.pretty_generate(packet) + "\n")
    updates = {
      "status" => "awaiting_approval",
      "development_status" => "awaiting_approval",
      "prepared_snapshot" => SNAPSHOT_RELATIVE,
      "prepared_snapshot_hash" => sha_file(snapshot),
      "updated" => packet["prepared_at"]
    }
    update_frontmatter(workplan, data.merge(updates), body)
    { "status" => "prepared", "workplan" => workplan.to_s, "prepared_snapshot" => snapshot.to_s }
  rescue StandardError
    snapshot.delete if defined?(snapshot) && snapshot&.file? && !(defined?(updates) && updates)
    raise
  end

  def prepare_feedback(workplan, repository:, scope_paths:, reason:, verification:, at: Time.now.iso8601)
    workplan, data, body = load_memo(workplan)
    repository = matching_repository!(data, repository)
    unless RESULT_STATUSES.include?(data["status"])
      raise ValidationError, "추가 변경을 준비할 수 없는 상태입니다: #{data['status'].inspect}"
    end
    raise ValidationError, "추가 변경 이유가 비어 있습니다" unless substantive?(reason)
    checks = clean_strings(verification)
    raise ValidationError, "추가 변경의 최소 검증이 비어 있습니다" if checks.empty?

    validate_approval!(workplan, data)
    initial = load_preparation(workplan, data)
    validate_repository_identity!(initial.fetch("repository_identity"), repository)
    added_scopes = normalize_paths(scope_paths, repository, "feedback scope")
    scopes = (Array(data["scope_paths"]) + added_scopes).uniq.sort
    packet = {
      "schema" => FEEDBACK_PREPARATION_SCHEMA,
      "prepared_at" => iso8601!(at),
      "previous_approval_revision" => data["approval_revision"],
      "repository_identity" => repository_identity(repository),
      "targets" => scopes.to_h { |relative| [relative, prepared_fingerprint(repository, relative)] }
    }
    snapshot = workplan.dirname.join(FEEDBACK_SNAPSHOT_RELATIVE)
    raise ValidationError, "추가 변경 기록 parent symlink는 허용하지 않습니다" if snapshot.dirname.symlink?
    snapshot.dirname.mkpath
    atomic_write(snapshot, JSON.pretty_generate(packet) + "\n")
    timestamp = packet["prepared_at"]
    updates = data.merge(
      "status" => "needs_reapproval",
      "development_status" => "needs_reapproval",
      "authority_status" => "proposal",
      "scope_paths" => scopes,
      "minimal_verification" => (Array(data["minimal_verification"]) + checks).uniq,
      "feedback_reason" => reason.strip,
      "feedback_prepared_snapshot" => FEEDBACK_SNAPSHOT_RELATIVE,
      "feedback_prepared_snapshot_hash" => sha_file(snapshot),
      "previous_approval_revision" => data["approval_revision"],
      "approval_revision" => nil,
      "approved_at" => nil,
      "approved_by" => nil,
      "approval_source" => nil,
      "approval_scope" => nil,
      "updated" => timestamp
    )
    update_frontmatter(workplan, updates, body)
    {
      "status" => "needs_reapproval",
      "workplan" => workplan.to_s,
      "feedback_snapshot" => snapshot.to_s,
      "scope_paths" => scopes
    }
  end

  def start_correction(workplan, repository:, scope_paths:, reason:, at: Time.now.iso8601)
    workplan, data, body = load_memo(workplan)
    unless RESULT_STATUSES.include?(data["status"])
      raise ValidationError, "correction을 시작할 수 없는 상태입니다: #{data['status'].inspect}"
    end
    raise ValidationError, "correction 이유가 비어 있습니다" unless substantive?(reason)

    repository = matching_repository!(data, repository)
    validate_approval!(workplan, data)
    initial = load_preparation(workplan, data)
    validate_repository_identity!(initial.fetch("repository_identity"), repository)

    scopes = normalize_paths(scope_paths, repository, "correction scope", allow_missing: true)
    raise ValidationError, "correction scope가 비어 있습니다" if scopes.empty?
    outside = scopes - Array(data["scope_paths"])
    unless outside.empty?
      raise ValidationError, "correction은 기존 승인 범위 안에서만 시작할 수 있습니다: #{outside.join(', ')}"
    end

    sequence_path = workplan.dirname.join(CORRECTION_SEQUENCE_RELATIVE)
    raise ValidationError, "correction 기록 parent symlink는 허용하지 않습니다" if sequence_path.dirname.symlink?
    previous_sequence = sequence_path.file? ? sequence_path.binread : nil
    packet = if sequence_path.file?
               JSON.parse(sequence_path.read(encoding: "UTF-8"))
             else
               { "schema" => "approval-memo-correction-sequence-v1", "entries" => [] }
             end
    unless packet["schema"] == "approval-memo-correction-sequence-v1" && packet["entries"].is_a?(Array)
      raise ValidationError, "correction sequence schema 불일치"
    end

    timestamp = iso8601!(at)
    packet["entries"] << {
      "sequence" => packet["entries"].length + 1,
      "started_at" => timestamp,
      "from_status" => data["status"],
      "reason" => reason.strip,
      "scope_paths" => scopes,
      "approval_revision" => data["approval_revision"],
      "starting_targets" => scopes.to_h { |relative| [relative, prepared_fingerprint(repository, relative)] }
    }
    sequence_path.dirname.mkpath
    atomic_write(sequence_path, JSON.pretty_generate(packet) + "\n")
    update_frontmatter(workplan, data.merge(
      "status" => "implementing",
      "development_status" => "implementing",
      "verification_status" => "not_run",
      "updated" => timestamp
    ), body)
    {
      "status" => "implementing",
      "workplan" => workplan.to_s,
      "correction_sequence" => packet["entries"].length,
      "scope_paths" => scopes
    }
  rescue JSON::ParserError => error
    raise ValidationError, "correction sequence를 읽을 수 없습니다: #{error.message}"
  rescue StandardError
    if defined?(sequence_path) && sequence_path
      if previous_sequence
        atomic_write(sequence_path, previous_sequence)
      elsif sequence_path.file?
        sequence_path.delete
      end
    end
    raise
  end

  def validate(workplan, phase:, repository:)
    workplan, data, body = load_memo(workplan)
    repository = matching_repository!(data, repository)
    raise ValidationError, "지원하지 않는 phase입니다: #{phase}" unless %w[approval apply completion].include?(phase)
    validate_memo_content!(data, body, repository, verify_before: phase == "approval")
    preparation = phase == "completion" ? result_preparation(workplan, data) : validation_preparation(workplan, data)
    validate_repository_identity!(preparation.fetch("repository_identity"), repository)

    case phase
    when "approval"
      raise ValidationError, "approval validation 가능한 상태가 아닙니다: #{data['status'].inspect}" unless APPROVABLE.include?(data["status"])
      validate_readiness_for_approval!(data)
      validate_target_fingerprints!(preparation, repository)
      validate_ui_plan!(workplan, data, repository)
      return "Workplan memo valid: approval\n\n#{plan_report(workplan)}"
    when "apply"
      validate_approval!(workplan, data)
      validate_target_fingerprints!(preparation, repository)
    when "completion"
      validate_approval!(workplan, data)
      validate_completion!(workplan, data, body, preparation, repository)
    end
    "Workplan memo valid: #{phase}"
  end

  def apply(workplan, repository:, at: Time.now.iso8601)
    workplan, data, body = load_memo(workplan)
    raise ValidationError, "apply 가능한 상태가 아닙니다: #{data['status'].inspect}" unless APPLICABLE.include?(data["status"])
    if text?(data["feedback_prepared_snapshot"])
      raise ValidationError, "추가 변경은 feedback-apply로 시작해야 합니다"
    end
    validate(workplan, phase: "apply", repository: repository)
    timestamp = iso8601!(at)
    update_frontmatter(workplan, data.merge("status" => "implementing", "development_status" => "implementing", "updated" => timestamp), body)
    { "status" => "implementing", "workplan" => workplan.to_s, "scope_paths" => data.fetch("scope_paths") }
  end

  def apply_feedback(workplan, repository:, at: Time.now.iso8601)
    workplan, data, body = load_memo(workplan)
    raise ValidationError, "추가 변경을 시작할 수 없는 상태입니다: #{data['status'].inspect}" unless data["status"] == "approved"
    raise ValidationError, "추가 변경 준비 기록이 없습니다" unless text?(data["feedback_prepared_snapshot"])
    validate_approval!(workplan, data)
    repository = matching_repository!(data, repository)
    preparation = load_feedback_preparation(workplan, data)
    validate_repository_identity!(preparation.fetch("repository_identity"), repository)
    validate_target_fingerprints!(preparation, repository)
    timestamp = iso8601!(at)
    update_frontmatter(workplan, data.merge("status" => "implementing", "development_status" => "implementing", "updated" => timestamp), body)
    { "status" => "implementing", "workplan" => workplan.to_s, "scope_paths" => data.fetch("scope_paths") }
  end

  def plan_report(workplan)
    workplan, data, body = load_memo(workplan)
    unless APPROVABLE.include?(data["status"])
      raise ValidationError, "계획 설명을 만들 수 없는 상태입니다: #{data['status'].inspect}"
    end
    validate_readiness_for_approval!(data)
    revision = approval_revision(workplan)
    lines = [
      "## 구현 전 확인할 계획", "",
      "### 무엇을 바꾸는가", "", (data["feedback_reason"] || data.fetch("reason")), "",
      "### 변경 컨셉", ""
    ]
    concept = plan_concept(body)
    lines << (concept.empty? ? "- Workplan의 현재 코드에서 제안 코드로 변경합니다." : concept)
    implementation_flow = body[/^## 구현 구상\s*$\n(.*?)(?=^## |\z)/m, 1].to_s.strip
    lines.concat(["", "### 핵심 구현 코드", "", implementation_flow]) unless implementation_flow.empty?
    if implementation_flow.empty? || !implementation_flow.include?("```")
      source_paths = Array(data["scope_paths"]).select { |path| source_path?(path) }
      unless source_paths.empty?
        lines.concat(["", "### 대표 코드", ""])
        source_paths.each do |path|
          before = code_evidence(body, path, :before)
          after = code_evidence(body, path, :after)
          next unless before && after
          language = language_for(path)
          lines.concat([
            "#### `#{path}`", "", "현재:", "", "```#{language}", before, "```", "",
            "제안:", "", "```#{language}", after, "```", ""
          ])
        end
      end
    end
    lines.concat(["### 변경 파일", ""] + Array(data["scope_paths"]).map { |path| "- `#{path}`" })
    lines.concat(["", "### 이번에 하지 않는 것", ""])
    exclusions = Array(data["excluded_paths"])
    lines.concat(exclusions.empty? ? ["- 선언된 변경 범위 밖의 파일과 동작"] : exclusions.map { |path| "- `#{path}`" })
    if data["verification_plan_required"]
      lines.concat(["", "### 테스트 계획", "", verification_plan_section(body)])
    else
      lines.concat(["", "### 확인 방법", ""] + Array(data["minimal_verification"]).map { |item| "- #{item}" })
    end
    lines.concat(["", "계획 버전: `#{revision}`"])
    lines.join("\n")
  end

  # The direct lane records the same approval artifacts as the normal lane, but
  # accepts the user's unambiguous implementation request as its approval source.
  # It intentionally does not infer risk: callers must have selected `direct`.
  def direct_apply(workplan, repository:, approved_by:, source:, at: Time.now.iso8601)
    raise ValidationError, "direct-apply 승인 source가 비어 있습니다" unless substantive?(source)
    path, data, = load_memo(workplan)
    raise ValidationError, "direct-apply는 direct Workplan에만 사용할 수 있습니다" unless data["workplan_kind"] == "direct"
    raise ValidationError, "direct-apply 가능한 상태가 아닙니다: #{data['status'].inspect}" unless data["status"] == "draft"

    prepare(path, repository: repository, at: at)
    validate(path, phase: "approval", repository: repository)
    revision = approval_revision(path)
    script = Pathname(__dir__).join("record-workplan-approval.rb")
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, script.to_s, "--expected-revision", revision,
      "--approved-by", approved_by.to_s, "--source", source.to_s, "--at", at.to_s, path.to_s
    )
    raise ValidationError, stderr.strip unless status.success?
    approval = JSON.parse(stdout)
    applied = apply(path, repository: repository, at: at)
    applied.merge("approval" => approval, "approval_revision" => revision)
  end

  def result(workplan, repository:, summary:, verification:, verification_result: nil, verification_status: "not_run", explanations: {}, knowledge_result: "not_evaluated", knowledge_destinations: [], knowledge_claims: [], knowledge_conflicts: [], publication_attempts: [], completion_requested_at: nil, completion_source: nil, status: nil, at: Time.now.iso8601)
    workplan, data, body = load_memo(workplan)
    repository = matching_repository!(data, repository)
    raise ValidationError, "result를 기록할 수 없는 상태입니다: #{data['status'].inspect}" unless RESULT_STATUSES.include?(data["status"])
    raise ValidationError, "result summary가 비어 있습니다" unless text?(summary)
    checks = Array(verification).map(&:strip).reject(&:empty?).uniq
    raise ValidationError, "result verification이 비어 있습니다" if checks.empty?
    raise ValidationError, "verification status 불일치" unless %w[not_run passed blocked].include?(verification_status)
    expected_status = RESULT_TARGET_STATUS.fetch(verification_status)
    status ||= expected_status
    raise ValidationError, "result status 불일치: #{status}" unless COMPLETION_STATUSES.include?(status)
    unless status == expected_status
      raise ValidationError, "verification_status #{verification_status}에는 status #{expected_status}만 허용됩니다: #{status}"
    end
    raise ValidationError, "knowledge result 불일치" unless %w[not_evaluated candidate no_change].include?(knowledge_result)
    destinations = clean_strings(knowledge_destinations)
    claims = clean_strings(knowledge_claims)
    conflicts = clean_strings(knowledge_conflicts)
    attempts = clean_strings(publication_attempts)
    if knowledge_result == "candidate" && (destinations.empty? || claims.empty?)
      raise ValidationError, "knowledge candidate에는 destination과 claim이 필요합니다"
    end
    authorization = nil
    if completion_requested_at || completion_source
      raise ValidationError, "completion authorization에는 requested_at과 source가 모두 필요합니다" unless completion_requested_at && text?(completion_source)
      authorization = { "requested_at" => iso8601!(completion_requested_at), "source" => completion_source.strip }
    end
    if knowledge_result != "not_evaluated" && authorization.nil?
      raise ValidationError, "knowledge 최종 판정에는 explicit completion authorization이 필요합니다"
    end
    if status == "completed" && (knowledge_result == "not_evaluated" || authorization.nil?)
      raise ValidationError, "completed result에는 최종 knowledge 판정과 completion authorization이 필요합니다"
    end
    evidence_path = workplan.dirname.join(UI_NONE_EVIDENCE_RELATIVE)
    previous_evidence = evidence_path.file? ? evidence_path.binread : nil
    data = attach_ui_none_evidence(workplan, data, verification_result, verification_status) if verification_result
    preparation = result_preparation(workplan, data)
    validate_approval!(workplan, data)
    changed = changed_scope_entries(preparation, repository)
    explanation_map = normalize_explanations(explanations)
    source_changes = changed.keys.select { |path| source_path?(path) }
    missing = source_changes - explanation_map.keys
    raise ValidationError, "변경 코드 설명 누락: #{missing.join(', ')}" unless missing.empty?
    extra = explanation_map.keys - source_changes
    raise ValidationError, "실제 변경 코드가 아닌 설명 path: #{extra.join(', ')}" unless extra.empty?

    core = {
      "schema" => RESULT_SCHEMA,
      "generated_at" => iso8601!(at),
      "summary" => summary.strip,
      "repository_identity" => repository_identity(repository),
      "changed_files" => changed_file_list(changed),
      "verification" => checks,
      "verification_status" => verification_status,
      "code_explanations" => explanation_map,
      "knowledge" => {
        "result" => knowledge_result,
        "destinations" => destinations,
        "claims" => claims,
        "conflicts" => conflicts,
        "publication_attempts" => attempts
      },
      "completion_requested_at" => authorization && authorization["requested_at"],
      "completion_source" => authorization && authorization["source"]
    }
    completion = workplan.dirname.join(COMPLETION_RELATIVE)
    previous_workplan = workplan.binread
    previous_completion = completion.file? ? completion.binread : nil
    if completion.file?
      previous = result_packet(completion)
      previous_knowledge = previous.dig("knowledge", "result")
      transition = previous_knowledge == "not_evaluated" && %w[candidate no_change].include?(knowledge_result)
      if %w[candidate no_change].include?(previous_knowledge)
        %w[summary repository_identity changed_files verification verification_status code_explanations].each do |key|
          raise ValidationError, "최종 Completion.md의 #{key}와 다른 result로 덮어쓸 수 없습니다" unless previous[key] == core[key]
        end
      end
      %w[result destinations claims conflicts].each do |key|
        next if transition || previous_knowledge == "not_evaluated" && knowledge_result == "not_evaluated"
        raise ValidationError, "최종 Completion.md의 knowledge.#{key}와 다른 result로 덮어쓸 수 없습니다" unless previous.dig("knowledge", key) == core.dig("knowledge", key)
      end
      previous_authorization = previous["completion_requested_at"] && { "requested_at" => previous["completion_requested_at"], "source" => previous["completion_source"] }
      unless previous_authorization.nil? || previous_authorization == authorization
        raise ValidationError, "기존 completion authorization과 다른 값으로 덮어쓸 수 없습니다"
      end
      core["generated_at"] = previous["generated_at"]
      core["knowledge"]["publication_attempts"] = (Array(previous.dig("knowledge", "publication_attempts")) + attempts).uniq
      atomic_write(completion, render_result(data.fetch("id"), core, human_result_report(core, preparation, repository)))
    else
      write_exclusive(completion, render_result(data.fetch("id"), core, human_result_report(core, preparation, repository)))
    end
    timestamp = iso8601!(at)
    update_frontmatter(workplan, data.merge(
      "status" => status,
      "development_status" => status,
      "verification_status" => verification_status,
      "knowledge_sync_status" => { "not_evaluated" => "not_evaluated", "candidate" => "ready_on_completion", "no_change" => "not_needed" }.fetch(knowledge_result),
      "completion_result" => COMPLETION_RELATIVE,
      "updated" => timestamp
    ), body)
    validate(workplan, phase: "completion", repository: repository) if verification_status == "passed"
    { "status" => status, "workplan" => workplan.to_s, "completion_result" => completion.to_s }
  rescue StandardError
    atomic_write(workplan, previous_workplan) if defined?(previous_workplan) && previous_workplan
    if defined?(completion) && completion
      previous_completion ? atomic_write(completion, previous_completion) : completion.delete if completion.file?
    end
    if defined?(evidence_path) && evidence_path
      previous_evidence ? atomic_write(evidence_path, previous_evidence) : evidence_path.delete if evidence_path.file?
    end
    raise
  end

  def attach_ui_none_evidence(workplan, data, result_path, verification_status)
    raise ValidationError, "--verification-result는 ui tier none에서만 사용할 수 있습니다" unless data["ui_verification_tier"] == "none"
    raise ValidationError, "--verification-result는 passed 결과 기록에만 사용할 수 있습니다" unless verification_status == "passed"

    source = Pathname(result_path).expand_path
    raise ValidationError, "verification result artifact가 없습니다: #{source}" unless source.file?
    raise ValidationError, "verification result artifact symlink는 허용하지 않습니다" if source.symlink?
    result = JSON.parse(source.read(encoding: "UTF-8"))
    raise ValidationError, "verification result schema 불일치" unless result["schema"] == "verification-result-v1"
    raise ValidationError, "verification result는 passed/exit_status 0이어야 합니다" unless result["status"] == "passed" && result["exit_status"] == 0

    kind, executed_count = case result["kind"]
                           when "test"
                             count = result["test_count"]
                             raise ValidationError, "test verification result의 test_count는 1 이상이어야 합니다" unless count.is_a?(Integer) && count.positive?
                             ["behavior", count]
                           when "compile"
                             ["compile", 1]
                           else
                             raise ValidationError, "verification result kind는 test 또는 compile이어야 합니다"
                           end
    artifact = workplan.dirname.join(UI_NONE_EVIDENCE_RELATIVE)
    artifact.dirname.mkpath
    payload = {
      "schema" => "ui-none-evidence-v1",
      "kind" => kind,
      "exit_status" => 0,
      "executed_count" => executed_count
    }
    atomic_write(artifact, JSON.generate(payload) + "\n")
    data.merge("ui_none_evidence" => {
      "kind" => kind,
      "artifact" => UI_NONE_EVIDENCE_RELATIVE,
      "hash" => sha_file(artifact)
    })
  rescue JSON::ParserError => error
    raise ValidationError, "verification result JSON을 읽을 수 없습니다: #{error.message}"
  end

  def validate_implementation_explanation(workplan, repository:)
    workplan, data, body = load_memo(workplan)
    repository = matching_repository!(data, repository)
    preparation = result_preparation(workplan, data)
    completion = workplan.dirname.join(data["completion_result"] || COMPLETION_RELATIVE)
    raise ValidationError, "Completion.md가 없습니다" unless completion.file?
    packet = result_packet(completion)
    changed = changed_scope_entries(preparation, repository)
    raise ValidationError, "Completion changed_files가 실제 approved scope diff와 다릅니다" unless packet["changed_files"] == changed_file_list(changed)
    source_changes = changed.keys.select { |path| source_path?(path) }
    explanations = packet["code_explanations"]
    unless explanations.is_a?(Hash) && explanations.keys.sort == source_changes.sort && explanations.values.all? { |value| substantive?(value) }
      raise ValidationError, "Completion code explanation coverage가 실제 source diff와 다릅니다"
    end
    "Implementation explanation gate valid: approval memo, #{source_changes.size} source files"
  end

  def validate_memo_content!(data, body, repository, verify_before: true)
    errors = []
    errors << "workplan_schema 불일치" unless data["workplan_schema"] == SCHEMA
    errors << "지원하지 않는 workplan_kind" unless KINDS.include?(data["workplan_kind"])
    errors << "변경 이유가 비어 있습니다" unless substantive?(data["reason"])
    scopes = data["scope_paths"]
    exclusions = data["excluded_paths"]
    checks = data["minimal_verification"]
    errors << "scope_paths가 비어 있습니다" unless string_list?(scopes)
    errors << "excluded_paths는 문자열 배열이어야 합니다" unless exclusions.is_a?(Array) && exclusions.all? { |value| text?(value) }
    errors << "minimal_verification이 비어 있습니다" unless string_list?(checks)
    validate_verification_plan(body, errors) if data["verification_plan_required"]
    if scopes.is_a?(Array) && exclusions.is_a?(Array)
      overlap = scopes & exclusions
      errors << "scope와 exclude가 겹칩니다: #{overlap.join(', ')}" unless overlap.empty?
      (scopes + exclusions).each { |path| errors << "안전하지 않은 repository 상대 경로: #{path.inspect}" unless safe_relative?(path) }
    end
    errors << "memo body의 변경 이유가 비어 있습니다" unless body.lines.any? { |line| !line.strip.empty? && !line.lstrip.start_with?("#", "<!--") && substantive?(line) }
    validate_code_evidence(data, body, repository, errors, verify_before: verify_before) if scopes.is_a?(Array)
    raise ValidationError, errors.join("\n") unless errors.empty?
    true
  end

  def validate_code_evidence(data, body, repository, errors, verify_before: true)
    sources = Array(data["scope_paths"]).select { |path| source_path?(path) }
    evidence_paths = sources.select { |path| !section_text(body, path, :before).empty? || !section_text(body, path, :after).empty? }
    errors << "code-changing memo에는 최소 하나의 substantive before/after code pair가 필요합니다" if !sources.empty? && evidence_paths.empty?
    evidence_paths.each do |path|
      before = code_evidence(body, path, :before)
      after = code_evidence(body, path, :after)
      exists = repository.join(path).file?
      if exists
        if before.nil?
          errors << "#{path}의 substantive before code가 없습니다"
        elsif placeholder?(before)
          errors << "#{path}의 before code가 placeholder입니다"
        elsif verify_before && !normalize_code(repository.join(path).read(encoding: "UTF-8")).include?(normalize_code(before))
          errors << "#{path}의 before code가 현재 source와 다릅니다"
        end
      elsif !explicit_new_file?(section_text(body, path, :before))
        errors << "#{path}의 before에는 new file 사유가 필요합니다"
      end
      after_section = section_text(body, path, :after)
      if after.nil? && !explicit_deletion?(after_section)
        errors << "#{path}의 substantive after code가 없습니다"
      elsif after && placeholder?(after)
        errors << "#{path}의 after code가 placeholder입니다"
      elsif before && after && normalize_code(before) == normalize_code(after)
        errors << "#{path}의 before/after code가 같습니다"
      end
    rescue ArgumentError, Encoding::InvalidByteSequenceError
      errors << "#{path} source를 UTF-8 코드 근거로 확인할 수 없습니다"
    end
  end

  def approval_projection(workplan, data: nil, body: nil)
    workplan = Pathname(workplan).expand_path
    unless data && body
      workplan, data, body = load_memo(workplan)
    end
    snapshot = load_preparation(workplan, data)
    projection = {
      "workplan_schema" => SCHEMA,
      "id" => data["id"],
      "project_id" => data["project_id"],
      "title" => data["title"],
      "workplan_kind" => data["workplan_kind"],
      "reason" => data["reason"],
      "scope_paths" => data["scope_paths"],
      "excluded_paths" => data["excluded_paths"],
      "minimal_verification" => data["minimal_verification"],
      "ui_verification_tier" => data["ui_verification_tier"],
      "ui_verification_required" => data["ui_verification_required"],
      "ui_verification_reason" => data["ui_verification_reason"],
      "prepared_scope" => snapshot.slice("repository_identity", "targets"),
      "memo" => body.rstrip
    }
    if text?(data["feedback_prepared_snapshot"])
      feedback = load_feedback_preparation(workplan, data)
      projection["feedback_scope"] = feedback.slice("previous_approval_revision", "repository_identity", "targets")
      projection["feedback_reason"] = data["feedback_reason"]
    end
    projection
  end

  def validate_artifact_placement(workplan, phase:, repository:)
    workplan, data, _body = load_memo(workplan)
    case phase
    when "plan" then validate(workplan, phase: "approval", repository: repository)
    when "apply" then validate(workplan, phase: "apply", repository: repository)
    when "feedback"
      raise ValidationError, "feedback은 활성 승인 Workplan에서만 시작할 수 있습니다" unless RESULT_STATUSES.include?(data["status"])
      repository = matching_repository!(data, repository)
      validate_approval!(workplan, data)
      preparation = result_preparation(workplan, data)
      validate_repository_identity!(preparation.fetch("repository_identity"), repository)
      "Artifact placement gate valid: feedback (approval memo scope retained)"
    when "completion" then validate(workplan, phase: "completion", repository: repository)
    else raise ValidationError, "지원하지 않는 phase입니다: #{phase}"
    end
  end

  def approved_scope_paths(workplan)
    path, data, = load_memo(workplan)
    validate_approval!(path, data)
    Array(data["scope_paths"])
  end

  def validate_completion!(workplan, data, body, preparation, repository)
    raise ValidationError, "completion 가능한 상태가 아닙니다: #{data['status'].inspect}" unless (RESULT_STATUSES + ["completed"]).include?(data["status"])
    completion = workplan.dirname.join(data["completion_result"] || COMPLETION_RELATIVE)
    raise ValidationError, "Completion.md가 없습니다" unless completion.file?
    packet = result_packet(completion)
    raise ValidationError, "completion result schema 불일치" unless packet["schema"] == RESULT_SCHEMA
    actual_changed = changed_scope_entries(preparation, repository)
    raise ValidationError, "Completion changed_files가 실제 approved scope diff와 다릅니다" unless packet["changed_files"] == changed_file_list(actual_changed)
    raise ValidationError, "Completion verification이 비어 있습니다" unless string_list?(packet["verification"])
    raise ValidationError, "Completion verification_status가 passed가 아닙니다" unless packet["verification_status"] == "passed"
    explanations = packet["code_explanations"]
    source_changes = actual_changed.keys.select { |path| source_path?(path) }
    raise ValidationError, "Completion code explanation coverage가 실제 source diff와 다릅니다" unless explanations.is_a?(Hash) && explanations.keys.sort == source_changes.sort && explanations.values.all? { |value| substantive?(value) }
    validate_repository_documents!(workplan, data, preparation, repository)
    validate_ui_completion!(workplan, data, repository)
    true
  end

  def validate_repository_documents!(workplan, data, preparation, repository)
    allowed = Array(data["scope_paths"])
    ambient = Array(preparation["ambient_dirty_paths"])
    generated = generated_bundle_paths(workplan, repository)
    unexpected = (git_changed_paths(repository) - allowed - ambient - generated).select { |path| document_path?(path) }
    raise ValidationError, "계획에 없는 제품 저장소 문서 diff: #{unexpected.join(', ')}" unless unexpected.empty?
  end

  def generated_bundle_paths(workplan, repository)
    bundle = workplan.dirname.realpath
    relative = bundle.relative_path_from(repository.realpath).to_s
    return [] if relative == ".." || relative.start_with?("../")
    [workplan.basename.to_s, SNAPSHOT_RELATIVE, "Artifacts/approval-snapshot.json", COMPLETION_RELATIVE].map do |suffix|
      bundle.join(suffix).relative_path_from(repository.realpath).to_s
    end
  rescue ArgumentError, Errno::ENOENT
    []
  end

  def validate_ui_completion!(workplan, data, repository)
    return unless data["ui_verification_required"] == true
    script = Pathname(__dir__).join("ui-verification-gate.rb")
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, script.to_s, "validate", "--phase", "completion", "--repository", repository.to_s, workplan.to_s)
    raise ValidationError, "UI completion gate가 통과하지 못했습니다: #{stderr.strip.empty? ? stdout.strip : stderr.strip}" unless status.success?
  end

  def validate_ui_plan!(workplan, data, repository)
    return if data["ui_verification_tier"] == "none"

    script = Pathname(__dir__).join("ui-verification-gate.rb")
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, script.to_s, "validate", "--phase", "plan", "--repository", repository.to_s, workplan.to_s)
    return if status.success?

    detail = stderr.strip.empty? ? stdout.strip : stderr.strip
    raise ValidationError, "UI 계획 검사가 통과하지 못했습니다. 기존 Golden이 없는 regression은 승인 전에 원천 대조가 필요한 conformance로 변경하거나, Snapshot 제외가 승인된 데이터 전용 변경이면 none으로 분류하세요: #{detail}"
  end

  def validate_approval!(workplan, data)
    errors = []
    errors << "authority_status가 approved가 아닙니다" unless data["authority_status"] == "approved"
    errors << "approved_by가 비어 있습니다" unless text?(data["approved_by"])
    errors << "approved_at이 비어 있습니다" unless text?(data["approved_at"])
    recorded = data["approval_revision"]
    errors << "approval_revision 형식 불일치" unless recorded.is_a?(String) && recorded.match?(SHA256)
    current = approval_revision(workplan)
    errors << "승인된 semantic scope가 변경되었습니다" unless current == recorded
    raise ValidationError, errors.join("\n") unless errors.empty?
  end

  def validate_readiness_for_approval!(data)
    return if %w[ready conditional].include?(data["readiness"])

    raise ValidationError, "readiness가 blocked이면 부족한 입력을 질문하고 같은 draft Workplan에서 재개해야 합니다"
  end

  def validate_plan_concept!(data, body)
    return unless %w[features bugs].include?(data["workplan_kind"])
    return if substantive?(plan_concept(body))

    raise ValidationError, "기능·버그 승인 계획에는 변경 컨셉이 필요합니다"
  end

  def plan_concept(body)
    body[/^## 변경 컨셉\s*$\n(.*?)(?=^## |\z)/m, 1].to_s.strip
  end

  def validate_target_fingerprints!(preparation, repository)
    actual_identity = repository_identity(repository)
    expected_identity = preparation.fetch("repository_identity")
    if actual_identity.slice("worktree_root", "git_dir", "head") != expected_identity.slice("worktree_root", "git_dir", "head")
      raise ValidationError, "현재 repository identity/HEAD가 prepared scope와 다릅니다"
    end
    drift = preparation.fetch("targets").keys.reject { |path| fingerprint_projection(preparation["targets"][path]) == fingerprint(repository, path) }
    raise ValidationError, "승인 대상 파일이 prepare 이후 변경되었습니다: #{drift.join(', ')}" unless drift.empty?
  end

  def changed_scope_entries(preparation, repository)
    preparation.fetch("targets").keys.sort.each_with_object({}) do |path, result|
      before = fingerprint_projection(preparation["targets"].fetch(path))
      after = fingerprint(repository, path)
      next if before == after
      result[path] = after.merge("change" => change_kind(before, after))
    end
  end

  def changed_file_list(entries)
    entries.keys.sort.map { |path| { "path" => path }.merge(entries.fetch(path)) }
  end

  def change_kind(before, after)
    return "create" unless before["exists"]
    return "delete" unless after["exists"]
    "update"
  end

  def load_preparation(workplan, data)
    path = WorkplanLayout.approval_memo_snapshot_path(workplan, data)
    raise ValidationError, "prepared snapshot이 없습니다" unless path&.file?
    raise ValidationError, "prepared snapshot hash 불일치" unless data["prepared_snapshot_hash"] == sha_file(path)
    packet = JSON.parse(path.read(encoding: "UTF-8"))
    raise ValidationError, "prepared snapshot schema 불일치" unless packet["schema"] == PREPARATION_SCHEMA
    packet
  rescue JSON::ParserError, RuntimeError => error
    raise ValidationError, error.message
  end

  def load_feedback_preparation(workplan, data)
    relative = data["feedback_prepared_snapshot"]
    raise ValidationError, "추가 변경 준비 기록이 없습니다" unless text?(relative)
    path = safe_bundle_artifact(workplan, relative, "추가 변경 준비 기록")
    raise ValidationError, "추가 변경 준비 기록 hash 불일치" unless data["feedback_prepared_snapshot_hash"] == sha_file(path)
    packet = JSON.parse(path.read(encoding: "UTF-8"))
    raise ValidationError, "추가 변경 준비 기록 schema 불일치" unless packet["schema"] == FEEDBACK_PREPARATION_SCHEMA
    packet
  rescue JSON::ParserError, RuntimeError => error
    raise ValidationError, error.message
  end

  def validation_preparation(workplan, data)
    text?(data["feedback_prepared_snapshot"]) ? load_feedback_preparation(workplan, data) : load_preparation(workplan, data)
  end

  def result_preparation(workplan, data)
    initial = load_preparation(workplan, data)
    return initial unless text?(data["feedback_prepared_snapshot"])

    feedback = load_feedback_preparation(workplan, data)
    initial_targets = initial.fetch("targets")
    feedback_targets = feedback.fetch("targets")
    initial.merge("targets" => Array(data["scope_paths"]).to_h do |path|
      [path, initial_targets[path] || feedback_targets.fetch(path)]
    end)
  end

  def safe_bundle_artifact(workplan, relative, label)
    raise ValidationError, "#{label} 경로가 안전하지 않습니다" unless safe_relative?(relative)
    bundle = workplan.dirname.realpath
    path = workplan.dirname.join(relative).cleanpath
    raise ValidationError, "#{label}가 없습니다" unless path.file?
    raise ValidationError, "#{label} symlink는 허용하지 않습니다" if path.symlink?
    inside = path.realpath.relative_path_from(bundle).to_s
    raise ValidationError, "#{label}가 Workplan 밖입니다" if inside == ".." || inside.start_with?("../")
    path
  rescue ArgumentError, Errno::ENOENT
    raise ValidationError, "#{label} 경로를 확인할 수 없습니다"
  end

  def result_packet(path)
    text = Pathname(path).read(encoding: "UTF-8")
    fence = text.match(/```ya?ml(?:\s+workplan-result)?\s*\n(.*?)\n```/m)
    raise ValidationError, "Completion.md workplan-result YAML block이 없습니다" unless fence
    parsed = YAML.safe_load(fence[1], permitted_classes: [], aliases: false) || {}
    packet = parsed["workplan_result"]
    raise ValidationError, "Completion.md workplan_result mapping이 없습니다" unless packet.is_a?(Hash)
    packet
  rescue Psych::SyntaxError => error
    raise ValidationError, "Completion.md YAML을 읽을 수 없습니다: #{error.message}"
  end

  def load_memo(path)
    workplan = Pathname(path).expand_path
    raise ValidationError, "Workplan이 없습니다: #{workplan}" unless workplan.file?
    raw = workplan.read(encoding: "UTF-8")
    _frontmatter, data = WorkplanLayout.frontmatter(raw)
    raise ValidationError, "approval memo Workplan이 아닙니다" unless WorkplanLayout.approval_memo?(data)
    body = raw.sub(/\A---\s*\n.*?\n---\s*\n/m, "")
    [workplan, data, body]
  rescue RuntimeError, Psych::SyntaxError => error
    raise ValidationError, error.message
  end

  def matching_repository!(data, value)
    repository = git_root(value)
    expected = Pathname(data.fetch("repository_root")).expand_path.realpath
    raise ValidationError, "Workplan repository_root가 대상 Git root와 다릅니다" unless repository == expected
    repository
  rescue KeyError, Errno::ENOENT => error
    raise ValidationError, "repository identity를 확인할 수 없습니다: #{error.message}"
  end

  def validate_repository_identity!(expected, repository)
    actual = repository_identity(repository)
    keys = %w[worktree_root git_dir]
    raise ValidationError, "prepared snapshot이 다른 Git worktree입니다" unless actual.slice(*keys) == expected.slice(*keys)
  end

  def repository_identity(repository)
    {
      "worktree_root" => repository.realpath.to_s,
      "git_dir" => git!(repository, "rev-parse", "--absolute-git-dir").strip.then { |value| Pathname(value).realpath.to_s },
      "head" => git!(repository, "rev-parse", "HEAD").strip,
      "remote" => git_optional(repository, "remote", "get-url", "origin"),
      "branch" => git_optional(repository, "branch", "--show-current")
    }
  end

  def fingerprint(repository, relative)
    path = repository.join(relative).cleanpath
    raise ValidationError, "scope path symlink는 허용하지 않습니다: #{relative}" if path.symlink?
    return { "exists" => false, "mode" => "absent", "hash" => sha256("") } unless path.exist?
    raise ValidationError, "scope path는 파일이어야 합니다: #{relative}" unless path.file?
    { "exists" => true, "mode" => path.stat.executable? ? "100755" : "100644", "hash" => sha_file(path) }
  end

  def prepared_fingerprint(repository, relative)
    result = fingerprint(repository, relative)
    path = repository.join(relative)
    if result["exists"] && source_path?(relative)
      result["source_content_base64"] = Base64.strict_encode64(path.binread)
    end
    result
  end

  def fingerprint_projection(value)
    value.slice("exists", "mode", "hash")
  end

  def normalize_paths(values, repository, label, allow_missing: true)
    Array(values).map(&:to_s).map(&:strip).reject(&:empty?).map do |value|
      raise ValidationError, "#{label} path는 안전한 repository 상대 경로여야 합니다: #{value.inspect}" unless safe_relative?(value)
      relative = Pathname(value).cleanpath.to_s
      path = repository.join(relative)
      raise ValidationError, "#{label} path symlink는 허용하지 않습니다: #{relative}" if path.symlink?
      raise ValidationError, "#{label} path는 파일이어야 합니다: #{relative}" if path.exist? && !path.file?
      raise ValidationError, "#{label} path가 없습니다: #{relative}" if !allow_missing && !path.exist?
      relative
    end.uniq.sort
  end

  def code_evidence(body, path, side)
    section = section_text(body, path, side)
    match = section.to_s.match(/```[A-Za-z0-9_+.#-]*\s*\n(.+?)\n```/m)
    match && match[1].strip
  end

  def section_text(body, path, side)
    labels = side == :before ? /(?:before|current|existing|기존|변경\s*전|현재)/i : /(?:after|proposed|result|제안|변경\s*후|이후)/i
    headings = body.lines.each_index.select do |index|
      line = body.lines[index]
      line.match?(/^\#{1,6}\s+/) && line.include?(path) && line.match?(labels)
    end
    index = headings.first
    return "" unless index
    level = body.lines[index][/^#+/].length
    boundary = Regexp.new("^#{Regexp.escape('#')}{1,#{level}}\\s+")
    body.lines[(index + 1)..].take_while { |line| !line.match?(boundary) }.join
  end

  def verification_plan_section(body)
    body[/^## 검증 계획\s*$\n(.*?)(?=^## |\z)/m, 1].to_s.strip
  end

  def validate_verification_plan(body, errors)
    section = verification_plan_section(body)
    rows = section.lines.map(&:strip).select { |line| line.start_with?("|") && line.end_with?("|") }
    if rows.length < 3
      errors << "검증 계획에 대상·방법/위치·실행·통과 기준을 담은 행이 필요합니다"
      return
    end
    rows.drop(2).each_with_index do |row, index|
      cells = row.split("|", -1)[1..-2].map(&:strip)
      if cells.length != 4 || cells.any? { |cell| cell.empty? || cell.include?("적어 주세요") }
        errors << "검증 계획 #{index + 1}행의 대상·방법/위치·실행·통과 기준을 채워 주세요"
      end
    end
    unless section.lines.any? { |line| line.match?(/\A- 제외:\s*\S/) && !line.include?("적어 주세요") }
      errors << "검증 계획의 제외 검증과 이유를 적어 주세요"
    end
  end

  def render_memo(id, title, reason, scopes, exclusions, checks, repository, kind)
    lines = ["# #{id} — #{title}", "", "## 변경 이유", "", reason.strip, ""]
    if %w[features bugs].include?(kind)
      lines.concat(["## 변경 컨셉", "", "작성 필요: 바뀔 코드 흐름과 유지할 동작을 짧게 설명합니다.", ""])
    end
    lines.concat(["## 변경 계획", ""])
    scopes.select { |path| source_path?(path) }.each do |path|
      language = language_for(path)
      state = repository.join(path).file? ? "현재 코드에서 관련 부분을 넣어 주세요." : "신규 파일"
      lines.concat(["### `#{path}` — 현재 코드", "", "```#{language}", state, "```", "", "### `#{path}` — 제안 코드", "", "```#{language}", "제안 코드를 넣어 주세요.", "```", ""])
    end
    non_source = scopes.reject { |path| source_path?(path) }
    unless non_source.empty?
      lines.concat(["### 기타 변경 파일", ""] + non_source.map { |path| "- `#{path}`" } + [""])
    end
    lines.concat(["## 제외 범위", ""] + (exclusions.empty? ? ["- 선언된 변경 범위 밖의 파일과 동작"] : exclusions.map { |path| "- `#{path}`" }) + ["", "## 최소 검증", ""] + checks.map { |item| "- #{item}" } + [""])
    if %w[features bugs].include?(kind)
      lines.concat([
        "## 검증 계획", "",
        "| 검증 대상/실패 조건 | 방법·파일/식별자 | 실행 명령 | 통과 기준 |",
        "|---|---|---|---|",
        "| 검증할 동작을 적어 주세요 | 기존/신규 테스트 파일과 이름을 적어 주세요 | 실행 명령을 적어 주세요 | 기대 결과를 적어 주세요 |",
        "", "- 제외: 제외할 검증과 이유를 적어 주세요.", ""
      ])
    end
    lines.join("\n")
  end

  def human_result_report(packet, preparation, repository)
    lines = ["## 구현 결과", "", packet.fetch("summary"), "", "## 실제 변경", ""]
    source_files = packet.fetch("changed_files").map { |entry| entry.fetch("path") }.select { |path| source_path?(path) }
    if source_files.empty?
      lines << "- 변경된 소스 코드 파일이 없습니다."
    else
      source_files.each do |path|
        before = preparation.fetch("targets").fetch(path)["source_content_base64"]
        before = before ? Base64.strict_decode64(before) : ""
        target = repository.join(path)
        after = target.file? ? target.binread : ""
        lines.concat([
          "### `#{path}`", "",
          packet.fetch("code_explanations").fetch(path), "",
          "```diff", unified_diff(path, before, after).rstrip, "```", ""
        ])
      end
    end
    lines.concat(["## 검증", ""])
    lines.concat(packet.fetch("verification").map { |item| "- #{item}" })
    lines.join("\n")
  end

  def unified_diff(path, before, after)
    Tempfile.create("workplan-before") do |left|
      Tempfile.create("workplan-after") do |right|
        left.binmode
        right.binmode
        left.write(before)
        right.write(after)
        left.flush
        right.flush
        output, error, status = Open3.capture3("diff", "-u", "--label", "before/#{path}", "--label", "after/#{path}", left.path, right.path)
        raise ValidationError, "source diff 생성 실패: #{error.strip}" unless [0, 1].include?(status.exitstatus)
        output.empty? ? "(no textual diff)\n" : output
      end
    end
  end

  def render_result(id, packet, report)
    yaml = YAML.dump("workplan_result" => packet).sub(/\A---\s*\n/, "")
    "# #{id} 완료 결과\n\n#{report}\n\n## 기계 판독 결과\n\n```yaml\n#{yaml}```\n"
  end

  def render_document(metadata, body)
    yaml = YAML.dump(metadata).sub(/\A---\s*\n/, "")
    "---\n#{yaml}---\n#{body}"
  end

  def update_frontmatter(path, metadata, body)
    atomic_write(path, render_document(metadata, body))
  end

  def write_exclusive(path, content)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
      file.write(content)
      file.flush
      file.fsync
    end
  rescue Errno::EEXIST
    raise ValidationError, "기존 파일을 덮어쓸 수 없습니다: #{path}"
  end

  def atomic_write(path, content)
    Tempfile.create([".workplan-memo-", ".tmp"], path.dirname.to_s) do |temporary|
      temporary.chmod(path.file? ? path.stat.mode : 0o644)
      temporary.write(content)
      temporary.flush
      temporary.fsync
      temporary.close
      File.rename(temporary.path, path.to_s)
    end
  end

  def git_root(value)
    input = Pathname(value).expand_path
    output, error, status = Open3.capture3("git", "-C", input.to_s, "rev-parse", "--show-toplevel")
    raise ValidationError, "Git root를 확인할 수 없습니다: #{error.strip}" unless status.success?
    root = Pathname(output.strip).realpath
    raise ValidationError, "--repository는 Git worktree root여야 합니다: #{input}" unless input.realpath == root
    root
  rescue Errno::ENOENT => error
    raise ValidationError, "repository를 확인할 수 없습니다: #{error.message}"
  end

  def git!(repository, *arguments)
    output, error, status = Open3.capture3("git", "-C", repository.to_s, *arguments)
    raise ValidationError, "Git #{arguments.first} 실패: #{error.strip}" unless status.success?
    output
  end

  def git_optional(repository, *arguments)
    output, _error, status = Open3.capture3("git", "-C", repository.to_s, *arguments)
    status.success? ? output.strip.then { |value| value.empty? ? nil : value } : nil
  end

  def git_changed_paths(repository)
    output = git!(repository, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--")
    fields = output.split("\0", -1).reject(&:empty?)
    fields.map { |field| field.byteslice(3..).to_s }.sort
  end

  def approval_revision(workplan)
    script = Pathname(__dir__).join("workplan-approval-revision.rb")
    output, error, status = Open3.capture3(RbConfig.ruby, script.to_s, workplan.to_s)
    raise ValidationError, "approval revision 계산 실패: #{error.strip}" unless status.success?
    output.strip
  end

  def normalize_explanations(value)
    value.to_h.each_with_object({}) do |(path, explanation), result|
      raise ValidationError, "code explanation이 비어 있습니다: #{path}" unless substantive?(explanation)
      result[Pathname(path).cleanpath.to_s] = explanation.strip
    end.sort.to_h
  end

  def clean_strings(values)
    Array(values).map(&:to_s).map(&:strip).reject(&:empty?).uniq
  end

  def source_path?(path)
    SOURCE_EXTENSIONS.include?(File.extname(path.to_s).downcase)
  end

  def document_path?(path)
    normalized = path.to_s.tr("\\", "/").downcase
    normalized.split("/").any? { |part| %w[docs .codex].include?(part) } || File.basename(normalized).match?(/\Areadme(?:\..+)?\z|\.(?:md|mdx|rst|adoc|txt)\z/)
  end

  def safe_relative?(value)
    return false unless text?(value)
    path = Pathname(value)
    parts = path.each_filename.to_a
    !path.absolute? && !parts.include?("..") && !parts.any? { |part| part.downcase == ".git" }
  end

  def explicit_new_file?(text)
    text.to_s.match?(/\bnew[ _-]?file\b|신규\s*파일/i)
  end

  def explicit_deletion?(text)
    text.to_s.match?(/\bdelete[ds]?\b|\bremove[ds]?\b|삭제/i)
  end

  def substantive?(value)
    text?(value) && !placeholder?(value)
  end

  def placeholder?(value)
    value.to_s.match?(/replace with|todo|tbd|placeholder|작성\s*필요|예정|넣어\s*주세요|관련\s*부분/i)
  end

  def text?(value)
    value.is_a?(String) && !value.strip.empty?
  end

  def string_list?(value)
    value.is_a?(Array) && !value.empty? && value.all? { |item| text?(item) }
  end

  def normalize_code(value)
    value.to_s.lines.map(&:rstrip).reject { |line| line.strip.empty? }.join("\n").strip
  end

  def sha_file(path)
    "sha256:#{Digest::SHA256.file(path).hexdigest}"
  end

  def sha256(value)
    "sha256:#{Digest::SHA256.hexdigest(value.to_s.b)}"
  end

  def iso8601!(value)
    parsed = Time.iso8601(value.to_s)
    raise ArgumentError unless value.to_s.match?(/T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/)
    parsed.iso8601
  rescue ArgumentError
    raise ValidationError, "시각은 초와 UTC offset을 포함한 ISO 8601이어야 합니다"
  end

  def validate_id!(id)
    raise ValidationError, "Workplan ID 형식이 올바르지 않습니다" unless id.to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
  end

  # 새 파일의 명명만 통일한다. 기존 문서를 여는 경로의 ID 검사는 변경하지 않는다.
  def creation_id(id:, slug:, at:, jira_key: nil)
    if id.nil? == slug.nil?
      raise ValidationError, "create에는 --slug <짧은-영문-작업명> 또는 --id <YYYYMMDD-작업명> 중 하나만 지정하세요"
    end

    if slug
      name = slug.strip.downcase.gsub(/[\s_]+/, "-")
      unless name.match?(/\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/)
        raise ValidationError, "--slug는 영문으로 시작하는 소문자·숫자·하이픈 작업명이어야 합니다"
      end
      return [Time.iso8601(iso8601!(at)).strftime('%Y%m%d'), jira_key, name].compact.join("-")
    end

    match = id.to_s.match(/\A(\d{8})-(?:([A-Z][A-Z0-9_]*-[1-9][0-9]*)-)?([a-z][a-z0-9]*(?:-[a-z0-9]+)*)\z/)
    unless match
      raise ValidationError, "새 Workplan ID는 YYYYMMDD-[Jira번호-]짧은-영문-작업명 형식이어야 합니다. --slug 사용을 권장합니다"
    end
    if jira_key && match[2] != jira_key
      raise ValidationError, "--id의 Jira 번호와 --jira-key가 일치해야 합니다"
    end
    begin
      Date.strptime(match[1], "%Y%m%d")
    rescue Date::Error
      raise ValidationError, "Workplan ID의 날짜가 유효하지 않습니다: #{match[1]}"
    end
    id
  end

  def language_for(path)
    { ".swift" => "swift", ".rb" => "ruby", ".py" => "python", ".js" => "javascript", ".jsx" => "jsx", ".ts" => "typescript", ".tsx" => "tsx", ".kt" => "kotlin", ".java" => "java" }.fetch(File.extname(path).downcase, "text")
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  options = { scope_paths: [], excluded_paths: [], verification: [], explanations: {}, knowledge_destinations: [], knowledge_claims: [], knowledge_conflicts: [], publication_attempts: [] }
  parser = OptionParser.new do |opts|
    opts.on("--root PATH") { |value| options[:root] = value }
    opts.on("--repository PATH") { |value| options[:repository] = value }
    opts.on("--project-id ID") { |value| options[:project_id] = value }
    opts.on("--id ID") { |value| options[:id] = value }
    opts.on("--slug SLUG") { |value| options[:slug] = value }
    opts.on("--jira-key KEY") { |value| options[:jira_key] = value }
    opts.on("--title TITLE") { |value| options[:title] = value }
    opts.on("--kind KIND") { |value| options[:kind] = { "feature" => "features", "bug" => "bugs", "investigation" => "investigations", "direct" => "direct" }.fetch(value, value) }
    opts.on("--reason TEXT") { |value| options[:reason] = value }
    opts.on("--scope PATH") { |value| options[:scope_paths] << value }
    opts.on("--exclude PATH") { |value| options[:excluded_paths] << value }
    opts.on("--verification TEXT") { |value| options[:verification] << value }
    opts.on("--ui-tier TIER") { |value| options[:ui_tier] = value }
    opts.on("--ui-reason TEXT") { |value| options[:ui_reason] = value }
    opts.on("--expected-revision REVISION") { |value| options[:expected_revision] = value }
    opts.on("--approved-by NAME") { |value| options[:approved_by] = value }
    opts.on("--source SOURCE") { |value| options[:source] = value }
    opts.on("--approval-scope TEXT") { |value| options[:approval_scope] = value }
    opts.on("--summary TEXT") { |value| options[:summary] = value }
    opts.on("--verification-status STATUS") { |value| options[:verification_status] = value }
    opts.on("--verification-result PATH") { |value| options[:verification_result] = value }
    opts.on("--explanation VALUE") do |value|
      path, explanation = value.split("=", 2)
      raise OptionParser::InvalidArgument, "--explanation은 PATH=TEXT 형식이어야 합니다" unless path && explanation
      options[:explanations][path] = explanation
    end
    opts.on("--knowledge-result RESULT") { |value| options[:knowledge_result] = value }
    opts.on("--knowledge-destination TEXT") { |value| options[:knowledge_destinations] << value }
    opts.on("--knowledge-claim TEXT") { |value| options[:knowledge_claims] << value }
    opts.on("--knowledge-conflict TEXT") { |value| options[:knowledge_conflicts] << value }
    opts.on("--publication-attempt TEXT") { |value| options[:publication_attempts] << value }
    opts.on("--completion-requested-at ISO8601") { |value| options[:completion_requested_at] = value }
    opts.on("--completion-source SOURCE") { |value| options[:completion_source] = value }
    opts.on("--status STATUS") { |value| options[:status] = value }
    opts.on("--phase PHASE") { |value| options[:phase] = value }
    opts.on("--at ISO8601") { |value| options[:at] = value }
  end

  begin
    parser.parse!
    at = options[:at] || Time.now.iso8601
    result = case command
             when "create"
               required = %i[root repository project_id title kind reason]
               raise WorkplanMemo::ValidationError, parser.to_s unless required.all? { |key| options[key] }
               WorkplanMemo.create(**options.slice(:root, :repository, :project_id, :id, :slug, :jira_key, :title, :kind, :reason, :scope_paths, :excluded_paths, :verification, :ui_tier, :ui_reason).merge(at: at))
             when "prepare"
               raise WorkplanMemo::ValidationError, parser.to_s unless ARGV.length == 1 && options[:repository]
               WorkplanMemo.prepare(ARGV.first, repository: options[:repository], at: at)
             when "feedback-prepare"
               raise WorkplanMemo::ValidationError, parser.to_s unless ARGV.length == 1 && options[:repository] && options[:reason]
               WorkplanMemo.prepare_feedback(ARGV.first, repository: options[:repository], scope_paths: options[:scope_paths], reason: options[:reason], verification: options[:verification], at: at)
             when "correction-start"
               raise WorkplanMemo::ValidationError, parser.to_s unless ARGV.length == 1 && options[:repository] && options[:reason] && !options[:scope_paths].empty?
               WorkplanMemo.start_correction(ARGV.first, repository: options[:repository], scope_paths: options[:scope_paths], reason: options[:reason], at: at)
             when "validate"
               raise WorkplanMemo::ValidationError, parser.to_s unless ARGV.length == 1 && options[:repository] && options[:phase]
               WorkplanMemo.validate(ARGV.first, phase: options[:phase], repository: options[:repository])
             when "approve"
               raise WorkplanMemo::ValidationError, parser.to_s unless ARGV.length == 1 && options[:expected_revision]
               script = Pathname(__dir__).join("record-workplan-approval.rb")
               arguments = [RbConfig.ruby, script.to_s, "--expected-revision", options[:expected_revision], "--approved-by", options[:approved_by] || "user", "--source", options[:source] || "conversation", "--at", at]
               arguments.concat(["--scope", options[:approval_scope]]) if options[:approval_scope]
               arguments << ARGV.first
               stdout, stderr, status = Open3.capture3(*arguments)
               raise WorkplanMemo::ValidationError, stderr.strip unless status.success?
               JSON.parse(stdout)
             when "direct-apply"
               raise WorkplanMemo::ValidationError, parser.to_s unless ARGV.length == 1 && options[:repository] && options[:source]
               WorkplanMemo.direct_apply(ARGV.first, repository: options[:repository], approved_by: options[:approved_by] || "user", source: options[:source], at: at)
             when "apply"
               raise WorkplanMemo::ValidationError, parser.to_s unless ARGV.length == 1 && options[:repository]
               WorkplanMemo.apply(ARGV.first, repository: options[:repository], at: at)
             when "feedback-apply"
               raise WorkplanMemo::ValidationError, parser.to_s unless ARGV.length == 1 && options[:repository]
               WorkplanMemo.apply_feedback(ARGV.first, repository: options[:repository], at: at)
             when "plan-report"
               raise WorkplanMemo::ValidationError, parser.to_s unless ARGV.length == 1
               WorkplanMemo.plan_report(ARGV.first)
             when "result"
               raise WorkplanMemo::ValidationError, parser.to_s unless ARGV.length == 1 && options[:repository]
               WorkplanMemo.result(ARGV.first, repository: options[:repository], summary: options[:summary], verification: options[:verification], verification_result: options[:verification_result], verification_status: options[:verification_status] || "not_run", explanations: options[:explanations], knowledge_result: options[:knowledge_result] || "not_evaluated", knowledge_destinations: options[:knowledge_destinations], knowledge_claims: options[:knowledge_claims], knowledge_conflicts: options[:knowledge_conflicts], publication_attempts: options[:publication_attempts], completion_requested_at: options[:completion_requested_at], completion_source: options[:completion_source], status: options[:status], at: at)
             else
               raise WorkplanMemo::ValidationError, "usage: workplan-memo.rb create|prepare|feedback-prepare|correction-start|validate|approve|direct-apply|apply|feedback-apply|plan-report|result ..."
             end
    puts(result.is_a?(String) ? result : JSON.generate(result))
  rescue WorkplanMemo::ValidationError, OptionParser::ParseError, JSON::ParserError => error
    warn error.message
    exit 1
  end
end
