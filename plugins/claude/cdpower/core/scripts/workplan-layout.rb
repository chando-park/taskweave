#!/usr/bin/env ruby

require "date"
require "pathname"
require "time"
require "yaml"

module WorkplanLayout
  LAYOUT = "stable-bundle-v1"
  APPROVAL_MEMO_SCHEMA = "approval-memo-v1"
  LIFECYCLE_TIMESTAMPS = %w[created updated approved_at verified_at completed_at].freeze
  TIMESTAMP_CONTRACT_EFFECTIVE_DATE = Date.new(2026, 8, 21)
  ISO8601_SECONDS_WITH_OFFSET = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\z/
  PLAN_CODE_CONTRACT_EFFECTIVE_AT = Time.iso8601("2026-08-21T11:32:35+09:00")
  PLAN_CODE_BEFORE_AFTER_EFFECTIVE_AT = Time.iso8601("2026-08-21T13:34:21+09:00")
  DETAIL_ROUTING_EFFECTIVE_AT = Time.iso8601("2026-08-21T13:49:42+09:00")
  ARCHITECTURE_CONTEXT_EFFECTIVE_AT = Time.iso8601("2026-08-21T16:00:00+09:00")
  PRINCIPLE_CONTEXT_EFFECTIVE_AT = Time.iso8601("2026-08-25T10:31:28+09:00")
  ARCHITECTURE_CONTEXT_REFERENCE = "20_AI/Codex/Runtime/references/project-architecture-context.md"
  DETAIL_LAYOUTS = %w[compact-v1 split-v1].freeze
  ARCHITECTURE_CONTEXT_STATUSES = %w[verified partial not_applicable].freeze
  ARCHITECTURE_CONTEXT_SCOPES = %w[
    module-boundary
    state-management
    flow-navigation
    dependency-domain
    async-lifecycle
    presentation
    ui-system
    testing
  ].freeze
  PLAN_DOCUMENT_ROLES = %w[description requirements code_plan test_plan].freeze
  RESULT_DOCUMENT_ROLES = %w[change verification].freeze
  KNOWLEDGE_DOCUMENT_ROLES = %w[knowledge knowledge_candidate].freeze
  DETAIL_DOCUMENT_PATHS = {
    "description" => "Details/description.md",
    "requirements" => "Details/requirements.md",
    "code_plan" => "Details/code-plan.md",
    "test_plan" => "Details/test-plan.md",
    "change" => "Details/change.md",
    "verification" => "Details/verification.md",
    "knowledge" => "Details/knowledge.md",
    "knowledge_candidate" => "Details/knowledge-candidate.md"
  }.freeze
  ACTIVE = %w[draft awaiting_approval approved implementing verifying].freeze
  WAITING = %w[on_hold needs_reapproval verification_blocked awaiting_completion knowledge_sync_pending].freeze
  COMPLETED = %w[completed superseded].freeze

  module_function

  def approval_memo?(data)
    data["workplan_schema"] == APPROVAL_MEMO_SCHEMA
  end

  def approval_memo_completion_path(main)
    Pathname(main).expand_path.dirname.join("Completion.md")
  end

  def approval_memo_snapshot_path(main, data)
    relative = data["prepared_snapshot"]
    return unless relative.is_a?(String) && !relative.empty?

    bundle = Pathname(main).expand_path.dirname.cleanpath
    path = bundle.join(relative).cleanpath
    inside = path.relative_path_from(bundle).to_s
    raise "prepared_snapshot이 Workplan bundle 밖입니다: #{relative}" if inside == ".." || inside.start_with?("../")
    current = bundle
    Pathname(relative).each_filename do |segment|
      current = current.join(segment)
      raise "prepared_snapshot parent symlink는 허용하지 않습니다: #{relative}" if current.symlink?
      break unless current.exist?
      resolved = current.realpath.relative_path_from(bundle.realpath).to_s
      raise "prepared_snapshot realpath가 Workplan bundle 밖입니다: #{relative}" if resolved == ".." || resolved.start_with?("../")
    end
    path
  rescue ArgumentError, Errno::ENOENT
    raise "prepared_snapshot이 Workplan bundle 밖입니다: #{relative}"
  end

  def lifecycle_timestamp_errors(data)
    precision = data["lifecycle_timestamp_precision"]
    precision = {} unless precision.is_a?(Hash)

    LIFECYCLE_TIMESTAMPS.map do |key|
      value = data[key]
      next if value.nil? || value.to_s.empty?
      next if value.is_a?(String) && value.match?(ISO8601_SECONDS_WITH_OFFSET)

      date = if value.is_a?(Date) && !value.is_a?(DateTime)
               value
             elsif value.is_a?(Time)
               value.to_date
             elsif value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
               Date.iso8601(value)
             elsif value.is_a?(String)
               Time.iso8601(value).to_date
             end
      next if date && date < TIMESTAMP_CONTRACT_EFFECTIVE_DATE
      next if key == "approved_at" && date && precision[key] == "date_only_unrecoverable"

      "#{key}는 초와 UTC offset을 포함한 따옴표로 감싼 ISO 8601 문자열이어야 합니다: #{value.inspect}"
    rescue Date::Error, ArgumentError
      "#{key} timestamp를 해석할 수 없습니다: #{value.inspect}"
    end.compact
  end

  def plan_code_contract_required?(data)
    value = data["created"]
    return false unless value.is_a?(String) && value.match?(ISO8601_SECONDS_WITH_OFFSET)

    Time.iso8601(value) >= PLAN_CODE_CONTRACT_EFFECTIVE_AT
  end

  def plan_code_before_after_required?(data)
    value = data["created"]
    return false unless value.is_a?(String) && value.match?(ISO8601_SECONDS_WITH_OFFSET)

    Time.iso8601(value) >= PLAN_CODE_BEFORE_AFTER_EFFECTIVE_AT
  end

  def detail_routing_required?(data)
    value = data["created"]
    return false unless value.is_a?(String) && value.match?(ISO8601_SECONDS_WITH_OFFSET)

    Time.iso8601(value) >= DETAIL_ROUTING_EFFECTIVE_AT
  end

  def architecture_context_contract_required?(data)
    return false unless data["workplan_kind"] == "features" || data["workplan_kind"] == "bugs"

    runtime_targets = Array(data["runtime_targets"]).map(&:to_s)
    return false unless runtime_targets.include?(ARCHITECTURE_CONTEXT_REFERENCE)

    value = data["created"]
    return false unless value.is_a?(String) && value.match?(ISO8601_SECONDS_WITH_OFFSET)

    Time.iso8601(value) >= ARCHITECTURE_CONTEXT_EFFECTIVE_AT
  end

  def architecture_context_errors(data)
    return [] unless architecture_context_contract_required?(data)

    errors = []
    status = data["architecture_context_status"]
    readiness = data["readiness"]
    scopes = Array(data["architecture_context_scopes"])
    sources = Array(data["architecture_context_sources"])
    note = data["architecture_context_scope_note"].to_s.strip

    errors << "architecture_context_status 누락" unless ARCHITECTURE_CONTEXT_STATUSES.include?(status)
    errors << "architecture_context_scopes 누락" if scopes.empty?
    unknown_scopes = scopes - ARCHITECTURE_CONTEXT_SCOPES
    unknown_scopes.each { |scope| errors << "지원하지 않는 architecture_context_scopes 값: #{scope}" }

    errors << "architecture_context_sources 누락" if sources.empty?
    errors << "partial 상태에서 architecture_context_scope_note 누락" if status == "partial" && note.empty?
    errors << "not_applicable 상태에서 architecture_context_scope_note 누락" if status == "not_applicable" && note.empty?
    if status == "partial" && readiness == "ready"
      errors << "partial 상태에서 readiness는 ready가 될 수 없습니다"
    end

    errors
  end

  def principle_context_errors(data)
    schema = data["principle_context_schema"]
    return [] if schema.to_s.empty?
    return ["지원하지 않는 principle_context_schema: #{schema}"] unless schema == "scoped-v1"

    required = Array(data["required_principle_context"]).map(&:to_s)
    sources = Array(data["architecture_context_sources"]).map { |source| source.is_a?(Hash) ? source["id"].to_s : source.to_s }
    evidence = data["architecture_context_evidence"]
    decisions = data["context_scope_decisions"]
    references = Array(data["reference_implementations"]).map(&:to_s)
    errors = []
    errors << "required_principle_context 누락" if required.empty?
    (required - sources).each { |id| errors << "필수 원칙 source 누락: #{id}" }
    unless evidence.is_a?(Hash)
      errors << "architecture_context_evidence mapping 누락"
    else
      (required - evidence.keys.map(&:to_s)).each { |id| errors << "필수 원칙 소비 증거 누락: #{id}" }
      evidence.each do |id, item|
        unless item.is_a?(Hash) && !item["status"].to_s.empty? && !Array(item["used_claims"]).empty?
          errors << "원칙 소비 증거의 status/used_claims 누락: #{id}"
        end
      end
    end
    errors << "context_scope_decisions mapping 누락" unless decisions.is_a?(Hash) && !decisions.empty?
    if data["architecture_context_status"] == "verified" && references.empty? && data["reference_implementation_note"].to_s.empty?
      errors << "verified 원칙 context의 reference_implementations 또는 예외 사유 누락"
    end
    errors
  end

  def detail_documents(main, data)
    main = Pathname(main).expand_path
    declared = data["detail_documents"]
    return { "description" => main.dirname.join("Details/description.md") } unless declared.is_a?(Hash)

    declared.each_with_object({}) do |(role, relative), documents|
      documents[role.to_s] = main.dirname.join(relative.to_s).cleanpath
    end
  end

  def description_required?(data)
    data["detail_layout"] != "split-v1"
  end

  def detail_document_errors(main, data)
    main = Pathname(main).expand_path
    layout = data["detail_layout"]
    return [] unless detail_routing_required?(data) || layout || data["detail_documents"]

    errors = []
    errors << "detail_layout 불일치: #{layout.inspect}" unless DETAIL_LAYOUTS.include?(layout)
    declared = data["detail_documents"]
    unless declared.is_a?(Hash)
      errors << "detail_documents mapping 누락"
      return errors
    end

    roles = declared.keys.map(&:to_s)
    allowed = PLAN_DOCUMENT_ROLES + RESULT_DOCUMENT_ROLES + KNOWLEDGE_DOCUMENT_ROLES
    (roles - allowed).each { |role| errors << "지원하지 않는 detail role: #{role}" }
    if description_required?(data) && !roles.include?("description")
      errors << "description detail role 누락"
    end
    duplicates = declared.values.map(&:to_s).group_by(&:itself).select { |_path, values| values.size > 1 }.keys
    duplicates.each { |path| errors << "중복 detail path: #{path}" }

    bundle = main.dirname.cleanpath
    documents = detail_documents(main, data)
    documents.each do |role, path|
      expected = DETAIL_DOCUMENT_PATHS[role]
      errors << "detail path 불일치(#{role}): #{declared[role] || declared[role.to_sym]} != #{expected}" if expected && (declared[role] || declared[role.to_sym]).to_s != expected
      begin
        relative = path.relative_path_from(bundle).to_s
        errors << "bundle 밖 detail path: #{role}=#{path}" if relative.start_with?("../") || relative == ".."
      rescue ArgumentError
        errors << "bundle 밖 detail path: #{role}=#{path}"
      end
      errors << "선언한 detail 문서 누락: #{role}=#{path}" unless path.file?
      if path.file?
        meaningful = path.read(encoding: "UTF-8").lines.any? do |line|
          stripped = line.strip
          !stripped.empty? && !stripped.start_with?("#")
        end
        errors << "빈 detail 문서: #{role}=#{path}" unless meaningful
      end
    end

    DETAIL_DOCUMENT_PATHS.each do |role, relative|
      path = bundle.join(relative)
      errors << "선언하지 않은 detail 문서: #{path}" if path.file? && !roles.include?(role)
    end

    description = documents["description"]&.file? ? documents["description"].read(encoding: "UTF-8") : ""
    if layout == "split-v1"
      main_text = main.read(encoding: "UTF-8")
      roles.each do |role|
        relative = (declared[role] || declared[role.to_sym]).to_s
        errors << "main detail 링크 누락: #{role}=#{relative}" unless main_text.include?("](#{relative})")
      end
    else
      (roles - ["description"]).each do |role|
        filename = File.basename(DETAIL_DOCUMENT_PATHS.fetch(role, declared[role].to_s))
        errors << "description detail 링크 누락: #{role}=#{filename}" unless description.include?("](#{filename})")
      end
    end
    nonblank = description.lines.count { |line| !line.strip.empty? }
    legacy_knowledge_backfill = data["detail_layout_compatibility"] == "legacy-knowledge-backfill"
    if layout == "compact-v1"
      errors << "compact description 120줄 초과: #{nonblank}" if nonblank > 120 && !legacy_knowledge_backfill
      source = documents.fetch("code_plan", documents["description"])
      code_ids = source&.file? ? source.read(encoding: "UTF-8").scan(/^\|\s*(CODE-\d+)\s*\|/).flatten.uniq.size : 0
      errors << "compact 계획 코드 ID 2개 초과: #{code_ids}" if code_ids > 2 && !legacy_knowledge_backfill
      if (roles & %w[requirements code_plan test_plan]).any? && !legacy_knowledge_backfill
        errors << "compact에서 분리 계획 문서 사용: #{(roles & %w[requirements code_plan test_plan]).join(', ')}"
      end
    elsif layout == "split-v1"
      errors << "split description 60줄 초과: #{nonblank}" if nonblank > 60
      errors << "split code_plan role 누락" if data["plan_code_evidence"] == "required" && !roles.include?("code_plan")
      if data["approval_revision_schema"] != "scope-v3" && data["detail_layout_compatibility"] != "scope-v2-pilot"
        errors << "split approval revision은 scope-v3여야 함"
      end
    end
    errors.concat(knowledge_document_errors(main, data, documents: documents, roles: roles))
    errors
  end

  def knowledge_document_errors(main, data, documents: detail_documents(main, data), roles: nil)
    roles ||= documents.keys
    candidates = [data["product_memory_candidate"], data["team_wiki_candidate"], data["personal_principle_candidate"]]
    candidate = candidates.include?("candidate")
    errors = []
    lifecycle = data["knowledge_plan_status"].to_s
    valid_lifecycle = %w[not_evaluated not_applicable planned observed verified promotion_ready promoted needs_reapproval]
    errors << "알 수 없는 knowledge_plan_status: #{lifecycle}" if !lifecycle.empty? && !valid_lifecycle.include?(lifecycle)
    errors << "knowledge detail role 누락" if !lifecycle.empty? && !%w[not_evaluated not_applicable].include?(lifecycle) && !roles.include?("knowledge")
    errors << "knowledge candidate detail role 누락" if candidate && !(roles.include?("knowledge") || roles.include?("knowledge_candidate"))
    if data["status"] == "knowledge_sync_pending" && data["completed_at"] && !data["completed_at"].to_s.empty?
      errors << "knowledge_sync_pending 상태에서 completed_at 선기록"
    end

    knowledge_path = documents["knowledge"]
    if knowledge_path&.file?
      text = knowledge_path.read(encoding: "UTF-8")
      %w[지식\ 반영\ 계획 주장 반영\ 제외].each do |heading|
        label = "## #{heading.gsub('\\ ', ' ')}"
        errors << "지식 문서 필수 섹션 누락: #{label}" unless text.include?(label)
      end
      errors << "지식 문서 KNOW ID 누락" unless text.match?(/^### KNOW-\d+/)
      errors << "지식 문서 상태 누락" unless text.match?(/^- 상태: (planned|observed|verified|promotion_ready|promoted|rejected)$/)
    end

    path = documents["knowledge_candidate"]
    return errors unless path&.file?

    text = path.read(encoding: "UTF-8")
    required = [
      "## 후보 메타데이터", "## 검증된 주장", "## 승격 제외",
      "## 민감정보 검사", "## 중복·상충 검사", "## 예상 승격 대상"
    ]
    required.each { |heading| errors << "지식 후보 필수 섹션 누락: #{heading}" unless text.include?(heading) }
    errors << "지식 후보 상태 누락" unless text.match?(/^- candidate_status: (draft|approved|promoted|rejected)$/)
    errors << "지식 후보 CLAIM 누락" unless text.match?(/^### CLAIM-\d+/)
    errors << "지식 후보 근거 누락" unless text.include?("- 근거:") && text.match?(/\]\((change|verification)\.md\)/)
    errors
  end

  def markdown_section(text, heading)
    lines = text.lines
    start = lines.index { |line| line.strip == heading }
    return "" unless start

    level = heading[/\A#+/].length
    fence = nil
    lines[(start + 1)..].each_with_object([]) do |line, body|
      marker = line.lstrip[/\A(`{3,}|~{3,})/, 1]
      if fence
        fence = nil if marker && marker[0] == fence[0] && marker.length >= fence.length
      elsif marker
        fence = marker
      elsif line.match?(/\A#{'#' * level} (?!#)/)
        break body
      end
      body << line
    end.join
  end

  def plan_code_evidence_errors(data, description)
    evidence = data["plan_code_evidence"]
    schema = data["plan_code_evidence_schema"]
    return [] unless plan_code_before_after_required?(data) || schema

    if evidence == "not_applicable"
      errors = []
      errors << "계획 코드 근거 schema 불일치: #{schema.inspect}" unless schema == "not-applicable-v1"
      section = markdown_section(description, "## 코드 변경 없음").strip
      errors << "코드 변경 없음 사유 누락" if section.empty?
      return errors
    end

    return ["계획 코드 근거 판정 누락"] unless evidence == "required"

    errors = []
    errors << "계획 코드 근거 schema 불일치: #{schema.inspect}" unless schema == "before-after-v1"
    section = markdown_section(description, "## 계획 코드 근거 (`proposed`)")
    if section.empty?
      errors << "계획 코드 근거 섹션 누락"
      return errors
    end

    header = section.lines.find { |line| line.lstrip.start_with?("|") && line.include?("변경 ID") }.to_s
    %w[변경\ ID 파일·심볼 변경\ 종류 현재\ 코드 제안\ 코드].each do |column|
      errors << "계획 코드 커버리지 표 열 누락: #{column.gsub('\\ ', ' ')}" unless header.include?(column.gsub("\\ ", " "))
    end

    ids = section.lines.each_with_object([]) do |line, found|
      cells = line.split("|").map(&:strip)
      found << cells[1] if cells.length >= 6 && cells[1]&.match?(/\ACODE-\d+\z/)
    end.uniq
    errors << "계획 코드 커버리지 행 누락" if ids.empty?
    ids.each do |id|
      %w[현재 제안].each do |side|
        heading = "### #{id} #{side} 코드"
        block = markdown_section(section, heading)
        errors << "#{heading} 누락" if block.empty?
        errors << "#{heading} code fence 누락" unless block.match?(/```[^\n]*\n.+?```/m)
      end
    end
    errors
  end

  def frontmatter(text)
    raw = text[/\A---\s*\n(.*?)\n---\s*\n/m, 1]
    raise "frontmatter가 없습니다" unless raw

    data = YAML.safe_load(raw, permitted_classes: [Date, Time], aliases: true) || {}
    [raw, data]
  end

  def state_group(status)
    return "Active" if ACTIVE.include?(status)
    return "Waiting" if WAITING.include?(status)
    return "Completed" if COMPLETED.include?(status)

    raise "지원하지 않는 Workplan status입니다: #{status}"
  end

  def year(data)
    [data["completed_at"], data["created"], data["updated"], data["id"]].compact.each do |value|
      return Regexp.last_match(1) if value.to_s.match(/(20\d{2})/)
    end
    Time.now.year.to_s
  end

  def bundle_directory(root, data)
    id = data.fetch("id")
    state_group(data.fetch("status"))
    Pathname(root).join(id)
  end

  def current_workplan?(path)
    _raw, data = frontmatter(Pathname(path).read(encoding: "UTF-8"))
    data["authority_status"] != "historical_record" && data["status"] != "superseded"
  end

  def resolve(root, id, view: "any")
    root = Pathname(root).expand_path
    matches = root.glob("**/#{id}.md").reject do |path|
      path.each_filename.any? { |part| %w[Evidence Details].include?(part) }
    end
    legacy = root.join("#{id}.md")
    matches << legacy if legacy.file? && !matches.include?(legacy)
    matches.uniq!
    raise "Workplan을 찾지 못했습니다: #{id}" if matches.empty?
    raise "Workplan ID 중복입니다: #{id}: #{matches.join(', ')}" if matches.size > 1

    match = matches.first
    case view.to_s
    when "current"
      raise "현재 Workplan이 아닙니다: #{id}" unless current_workplan?(match)
    when "history"
      raise "역사 Workplan이 아닙니다: #{id}" if current_workplan?(match)
    when "any", ""
      # 기존 resolver 호환 모드
    else
      raise "지원하지 않는 Workplan view입니다: #{view}"
    end
    match
  end
end
