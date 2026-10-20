#!/usr/bin/env ruby

require "optparse"
require "pathname"
require "digest"
require "json"
require "open3"
require "yaml"
require "rbconfig"
require "time"
require_relative "workplan-layout"

module FeaturePlanGate
  class ValidationError < StandardError; end

  SCHEMA = "feature-plan-completeness-v1"
  PROFILES = %w[logic ui mixed].freeze
  UI_PROFILES = %w[ui mixed].freeze
  FLOW_KEYS = %w[state action effect delegate flow].freeze
  VERIFICATION_KINDS = %w[existing_test static_review].freeze
  STATIC_REVIEW_TYPES = %w[source_review visual_review static_analysis].freeze
  UI_SOURCE_ROLES = %w[screen container content component state].freeze
  APPROVED_APPLY_STATUSES = %w[
    approved implementing verifying verification_blocked awaiting_completion
  ].freeze
  SHA256 = /\Asha256:[0-9a-f]{64}\z/
  APPROVAL_TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/

  module_function

  def validate(workplan, phase:, expected_sources: nil, repository: nil)
    workplan = Pathname(workplan).expand_path
    raise ValidationError, "Workplan이 없습니다: #{workplan}" unless workplan.file?

    _raw, data = WorkplanLayout.frontmatter(workplan.read(encoding: "UTF-8"))
    return "Feature plan gate skipped: completed historical Workplan" if completed?(data)
    raise ValidationError, "feature Workplan이 아닙니다" unless feature?(data)

    if WorkplanLayout.approval_memo?(data)
      require_relative "workplan-memo"
      mapped_phase = phase == "apply" ? "apply" : "approval"
      begin
        return WorkplanMemo.validate(workplan, phase: mapped_phase, repository: repository || data["repository_root"])
      rescue WorkplanMemo::ValidationError => error
        raise ValidationError, error.message
      end
    end

    return validate_apply_delta(workplan, data) if phase == "apply"

    errors = readiness_errors(data)
    traversal_errors = detail_path_traversal_errors(workplan, data)
    unless traversal_errors.empty?
      errors.concat(traversal_errors)
      raise ValidationError, errors.join("\n")
    end
    layout_errors = WorkplanLayout.detail_document_errors(workplan, data)
    unless layout_errors.empty?
      errors.concat(layout_errors.map { |error| "Workplan detail 경로/구조 불일치: #{error}" })
      raise ValidationError, errors.join("\n")
    end
    documents = WorkplanLayout.detail_documents(workplan, data)
    texts = documents.each_with_object({}) do |(role, path), result|
      result[role] = path.read(encoding: "UTF-8") if path.file?
    end
    code_text = texts.fetch("code_plan", texts.fetch("description", ""))
    requirements_text = texts.fetch("requirements", texts.fetch("description", ""))
    code_changing = data["plan_code_evidence"] == "required"
    schema = data["feature_plan_completeness_schema"].to_s
    profile = data["context_profile"].to_s
    # UI coverage is a requirement-source decision.  A planning profile is useful
    # for selecting investigation context, but does not by itself prove that an
    # approved requirement has a visual contract.
    ui_source = false

    unless PROFILES.include?(profile)
      errors << "context_profile은 logic, ui, mixed 중 하나여야 합니다"
    end

    unless code_changing
      raise ValidationError, errors.join("\n") unless errors.empty?
      return "Feature plan gate valid: no code changes"
    end

    if schema.empty?
      if code_changing || ui_source
        errors << "feature_plan_completeness_schema 누락"
      end
      raise ValidationError, errors.join("\n") unless errors.empty?
      return "Feature plan gate valid: no code changes"
    end

    errors << "feature plan completeness schema 불일치: #{schema.inspect}" unless schema == SCHEMA
    if code_changing && data["approval_revision_schema"] != "scope-v3"
      errors << "code-changing feature의 approval_revision_schema는 scope-v3여야 합니다"
    end

    requirements_packet = parse_yaml_mapping(
      requirements_text,
      "## 기능 요구사항 매핑 (`feature-plan-completeness-v1`)",
      "feature_requirements",
      errors
    )
    requirements = requirements_packet["requirements"]
    source_inventory = requirements_packet["source_inventory"]
    mapping = parse_yaml_mapping(
      code_text,
      "## 기능 구현 매핑 (`feature-plan-completeness-v1`)",
      "feature_plan",
      errors
    )
    mapping["requirements"] = requirements if requirements.is_a?(Hash)
    expected_inventory = if phase == "approval"
                           parse_expected_sources(expected_sources, errors)
                         else
                           nil
                         end
    validate_source_inventory(source_inventory, requirements, expected_inventory, errors)
    validate_inventory_digest(data, source_inventory, expected_inventory, errors)
    ui_source ||= source_inventory_ui?(source_inventory)
    validate_code_mapping(data, code_text, mapping, errors, repository: repository) if code_changing
    validate_ui_mapping(data, mapping, errors) if ui_source || mapping.key?("ui")

    if data["implementation_handoff_status"] == "ready" && mapping.empty?
      errors << "implementation_handoff_status ready에는 완전한 기능 구현 매핑이 필요합니다"
    end

    raise ValidationError, errors.join("\n") unless errors.empty?

    "Feature plan gate valid: #{profile} #{phase}"
  rescue KeyError, Psych::SyntaxError => error
    raise ValidationError, "기능 구현 매핑을 해석할 수 없습니다: #{error.message}"
  end

  def completed?(data)
    data["status"] == "completed" || data["authority_status"] == "historical_record"
  end

  def feature?(data)
    data["workplan_kind"] == "features" || data["id"].to_s.start_with?("FEATURE-")
  end

  # Approval validates the complete plan packet. Apply intentionally validates
  # only the recorded authority/scope delta and explicit implementation blockers.
  # The approved revision already binds every declared scope-v3 plan document;
  # re-running the evolving document schema here would retroactively revoke an
  # unchanged approval for formatting or later-added administrative fields.
  def validate_apply_delta(workplan, data)
    errors = detail_path_traversal_errors(workplan, data)
    status = data["status"].to_s
    errors << "apply 가능한 승인 상태가 아닙니다: #{status.inspect}" unless APPROVED_APPLY_STATUSES.include?(status)
    errors << "authority_status가 approved가 아닙니다" unless data["authority_status"] == "approved"
    errors << "approved_by가 비어 있습니다" unless text?(data["approved_by"])
    approved_at = data["approved_at"]
    unless valid_approval_time?(approved_at)
      errors << "approved_at은 초와 Z 또는 UTC offset을 포함한 승인 시각이어야 합니다"
    end

    recorded_revision = data["approval_revision"].to_s
    if !recorded_revision.match?(SHA256)
      errors << "기록된 approval_revision 누락 또는 형식 불일치"
    elsif (basis_error = approval_basis_error(workplan, data))
      errors << basis_error
    else
      current_revision, revision_error = approval_revision(workplan)
      if revision_error
        errors << revision_error
      elsif current_revision != recorded_revision
        errors << "승인 범위가 변경되었습니다: recorded=#{recorded_revision} current=#{current_revision}"
      end
    end

    errors << "readiness가 not_ready이므로 필수 구현 입력이 해결되지 않았습니다" if data["readiness"] == "not_ready"
    if %w[partial blocked].include?(data["implementation_handoff_status"])
      errors << "implementation_handoff_status가 #{data['implementation_handoff_status']}이므로 구현 계약이 준비되지 않았습니다"
    end
    if data["architecture_context_status"] == "partial"
      errors << "architecture_context_status가 partial이므로 원천 또는 아키텍처 상충이 해결되지 않았습니다"
    end

    raise ValidationError, errors.join("\n") unless errors.empty?

    deferred = []
    deferred << "legacy feature-plan schema" if data["feature_plan_completeness_schema"].to_s.empty?
    declared = data["detail_documents"]
    deferred << "undeclared knowledge record" unless declared.is_a?(Hash) && declared.key?("knowledge")
    suffix = deferred.empty? ? "" : "; deferred administrative records: #{deferred.join(', ')}"
    "Feature apply safety valid: approved revision unchanged#{suffix}"
  end

  def approval_revision(workplan)
    script = Pathname(__dir__).join("workplan-approval-revision.rb")
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, script.to_s, workplan.to_s)
    return [nil, "approval revision을 계산할 수 없습니다: #{stderr.strip}"] unless status.success?

    [stdout.strip, nil]
  end

  def approval_basis_error(workplan, data)
    relative = data["approval_basis"]
    return nil if relative.to_s.strip.empty?
    return "scope-v3 apply는 approval_basis redirect를 허용하지 않습니다" if data["approval_revision_schema"] == "scope-v3"

    bundle = workplan.dirname.cleanpath
    basis = bundle.join(relative.to_s).cleanpath
    begin
      inside = basis.relative_path_from(bundle).to_s
      return "approval_basis가 Workplan bundle 밖입니다: #{relative}" if inside == ".." || inside.start_with?("../")
      return "approval_basis가 없습니다: #{basis}" unless basis.file?

      real_inside = basis.realpath.relative_path_from(bundle.realpath).to_s
      return "approval_basis symlink realpath가 Workplan bundle 밖입니다: #{relative}" if real_inside == ".." || real_inside.start_with?("../")
    rescue ArgumentError, Errno::ENOENT
      return "approval_basis가 Workplan bundle 밖입니다: #{relative}"
    end
    nil
  end

  def valid_approval_time?(value)
    return false unless value.is_a?(String) && value.match?(APPROVAL_TIME)

    Time.iso8601(value)
    true
  rescue ArgumentError
    false
  end

  def readiness_errors(data)
    errors = []
    handoff = data["implementation_handoff_status"]
    readiness = data["readiness"]
    errors << "implementation_handoff_status 누락 또는 불일치" unless %w[ready partial blocked].include?(handoff)
    if readiness == "ready" && handoff != "ready"
      errors << "readiness ready에는 implementation_handoff_status ready가 필요합니다"
    end
    errors
  end

  def detail_path_traversal_errors(workplan, data)
    declared = data["detail_documents"]
    return [] unless declared.is_a?(Hash)

    bundle = workplan.dirname.cleanpath
    bundle_real = bundle.realpath
    declared.each_with_object([]) do |(role, relative), errors|
      path = bundle.join(relative.to_s).cleanpath
      begin
        inside = path.relative_path_from(bundle).to_s
        if inside == ".." || inside.start_with?("../")
          errors << "Workplan detail 경로가 bundle 밖입니다: #{role}=#{relative}"
        end
      rescue ArgumentError
        errors << "Workplan detail 경로가 bundle 밖입니다: #{role}=#{relative}"
      end
      next unless path.file?

      begin
        real_inside = path.realpath.relative_path_from(bundle_real).to_s
        if real_inside == ".." || real_inside.start_with?("../")
          errors << "Workplan detail symlink realpath가 bundle 밖입니다: #{role}=#{relative}"
        end
      rescue ArgumentError, Errno::ENOENT
        errors << "Workplan detail symlink realpath가 bundle 밖입니다: #{role}=#{relative}"
      end
    end
  end

  def parse_yaml_mapping(text, heading, root_key, errors)
    section = WorkplanLayout.markdown_section(text, heading)
    if section.empty?
      errors << "#{heading} 섹션 누락"
      return {}
    end

    fenced = section.match(/```ya?ml\s*\n(.*?)\n```/m)
    unless fenced
      errors << "#{heading} YAML fence 누락"
      return {}
    end

    parsed = YAML.safe_load(fenced[1], permitted_classes: [], aliases: false) || {}
    mapping = parsed[root_key]
    unless mapping.is_a?(Hash)
      errors << "#{heading}의 #{root_key} mapping 누락"
      return {}
    end
    mapping
  end

  def parse_expected_sources(path, errors)
    if path.to_s.strip.empty?
      errors << "approval gate에는 --expected-sources inventory가 필요합니다"
      return nil
    end

    inventory_path = Pathname(path).expand_path
    unless inventory_path.file?
      errors << "expected source inventory가 없습니다: #{inventory_path}"
      return nil
    end
    data = YAML.safe_load(inventory_path.read(encoding: "UTF-8"), permitted_classes: [], aliases: false) || {}
    unless data["schema_version"] == 1
      errors << "expected source inventory schema_version은 1이어야 합니다"
    end
    sources = data["sources"]
    unless sources.is_a?(Array) && !sources.empty?
      errors << "expected source inventory sources는 비어 있지 않은 배열이어야 합니다"
      return nil
    end

    result = {}
    sources.each_with_index do |source, index|
      unless source.is_a?(Hash)
        errors << "expected source[#{index}] mapping 불일치"
        next
      end
      %w[id kind locator].each do |field|
        errors << "expected source[#{index}].#{field}는 비어 있지 않은 문자열이어야 합니다" unless text?(source[field])
      end
      unless boolean?(source["requires_ui_context"])
        errors << "expected source[#{index}].requires_ui_context는 boolean이어야 합니다"
      end
      id = source["id"].to_s
      errors << "expected source ID 형식 불일치: #{id}" unless id.match?(/\ASOURCE-\d+\z/)
      errors << "expected source ID 중복: #{id}" if result.key?(id)
      result[id] = source if text?(source["id"])
    end
    result
  rescue Psych::SyntaxError => error
    errors << "expected source inventory YAML을 해석할 수 없습니다: #{error.message}"
    nil
  end

  def validate_source_inventory(inventory, requirements, expected, errors)
    unless nonempty_hash?(inventory)
      errors << "hashed requirements의 source_inventory 누락"
      return
    end
    requirements = {} unless requirements.is_a?(Hash)

    actual_ids = inventory.keys.map(&:to_s)
    if expected
      expected_ids = expected.keys
      (expected_ids - actual_ids).each { |id| errors << "expected source 누락: #{id}" }
      (actual_ids - expected_ids).each { |id| errors << "예상하지 않은 source ID: #{id}" }
    end

    inventory.each do |source_id, item|
      unless source_id.to_s.match?(/\ASOURCE-\d+\z/) && item.is_a?(Hash)
        errors << "source inventory ID 또는 mapping 불일치: #{source_id}"
        next
      end
      %w[kind locator].each do |field|
        errors << "#{source_id}.#{field}는 비어 있지 않은 문자열이어야 합니다" unless text?(item[field])
      end
      errors << "#{source_id}.requires_ui_context는 boolean이어야 합니다" unless boolean?(item["requires_ui_context"])
      if expected && expected[source_id]
        %w[kind locator requires_ui_context].each do |field|
          errors << "#{source_id}.#{field}가 expected inventory와 다릅니다" unless item[field] == expected[source_id][field]
        end
      end

      requirement_ids = item["requirement_ids"]
      not_applicable = item["not_applicable"]
      covered = string_list?(requirement_ids)
      excluded = text?(not_applicable)
      if covered == excluded
        errors << "#{source_id}는 requirement_ids 또는 explicit not_applicable 사유 중 하나만 가져야 합니다"
        next
      end
      if covered
        requirement_ids.each do |requirement_id|
          errors << "#{source_id}의 알 수 없는 REQ ID: #{requirement_id}" unless requirements.key?(requirement_id)
          next unless requirements[requirement_id].is_a?(Hash)
          unless Array(requirements[requirement_id]["source_ids"]).include?(source_id)
            errors << "#{source_id}↔#{requirement_id} 양방향 source 연결 누락"
          end
        end
      end
    end

    requirements.each do |requirement_id, item|
      next unless item.is_a?(Hash)
      source_ids = item["source_ids"]
      next unless source_ids.is_a?(Array)
      source_ids.each do |source_id|
        source = inventory[source_id]
        unless source.is_a?(Hash)
          errors << "#{requirement_id}의 알 수 없는 source ID: #{source_id}"
          next
        end
        unless Array(source["requirement_ids"]).include?(requirement_id)
          errors << "#{requirement_id}↔#{source_id} 양방향 source 연결 누락"
        end
      end
    end
  end

  def canonical_inventory(inventory)
    return [] unless inventory.is_a?(Hash)

    inventory.keys.map(&:to_s).sort.map do |id|
      item = inventory[id] || inventory[id.to_sym] || {}
      {
        "id" => id,
        "kind" => item["kind"],
        "locator" => item["locator"],
        "requires_ui_context" => item["requires_ui_context"]
      }
    end
  end

  def inventory_digest(inventory)
    "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical_inventory(inventory)))}"
  end

  def validate_inventory_digest(data, actual, expected, errors)
    stored = data["expected_source_inventory_digest"]
    unless stored.is_a?(String) && stored.match?(/\Asha256:[0-9a-f]{64}\z/)
      errors << "expected_source_inventory_digest 누락 또는 형식 불일치"
      return
    end
    unless nonempty_hash?(actual)
      errors << "actual source inventory digest를 계산할 수 없습니다"
      return
    end

    actual_digest = inventory_digest(actual)
    errors << "stored digest와 hashed source_inventory digest가 다릅니다" unless stored == actual_digest
    return unless expected

    expected_digest = inventory_digest(expected)
    errors << "stored digest와 temporary expected inventory digest가 다릅니다" unless stored == expected_digest
    errors << "temporary expected와 hashed source inventory digest가 다릅니다" unless expected_digest == actual_digest
  end

  def source_inventory_ui?(inventory)
    return false unless inventory.is_a?(Hash)

    inventory.any? do |_id, item|
      next false unless item.is_a?(Hash)
      item["requires_ui_context"] == true && string_list?(item["requirement_ids"])
    end
  end

  def validate_code_mapping(data, code_text, mapping, errors, repository: nil)
    WorkplanLayout.plan_code_evidence_errors(data, code_text).each do |error|
      errors << "계획 코드 근거 불일치: #{error}"
    end

    requirements = mapping["requirements"]
    code_changes = mapping["code_changes"]
    tests = mapping["tests"]
    unless nonempty_hash?(requirements)
      errors << "requirements→CODE mapping 누락"
      return
    end
    unless nonempty_hash?(code_changes)
      errors << "CODE 변경 mapping 누락"
      return
    end
    unless nonempty_hash?(tests)
      errors << "direct tests mapping 누락"
      tests = {}
    end

    evidence_ids = code_text.scan(/^\|\s*(CODE-\d+)\s*\|/).flatten.uniq
    mapped_ids = code_changes.keys.map(&:to_s)
    (evidence_ids - mapped_ids).each { |id| errors << "계획 코드 근거의 #{id} mapping 누락" }
    (mapped_ids - evidence_ids).each { |id| errors << "#{id} 계획 코드 근거 행 누락" }

    requirements.each do |requirement_id, item|
      unless requirement_id.to_s.match?(/\AREQ-\d+\z/) && item.is_a?(Hash)
        errors << "요구사항 ID 또는 mapping 불일치: #{requirement_id}"
        next
      end
      %w[current_problem expected_behavior].each do |field|
        errors << "#{requirement_id} #{field}는 비어 있지 않은 문자열이어야 합니다" unless text?(item[field])
      end
      %w[source_ids].each do |field|
        errors << "#{requirement_id} #{field}는 비어 있지 않은 문자열 배열이어야 합니다" unless string_list?(item[field])
      end
      %w[files_symbols tests].each do |field|
        errors << "#{requirement_id} #{field} 타입 또는 값 불일치" if item.key?(field) && !string_list?(item[field])
      end
      ids = Array(item["code_ids"]).map(&:to_s)
      errors << "#{requirement_id}→CODE IDs는 비어 있지 않은 문자열 배열이어야 합니다" unless string_list?(item["code_ids"])
      (ids - mapped_ids).each { |id| errors << "#{requirement_id}의 알 수 없는 CODE ID: #{id}" }
    end

    canonical_requirements_by_code = Hash.new { |hash, key| hash[key] = [] }
    requirements.each do |requirement_id, item|
      next unless item.is_a?(Hash)
      Array(item["code_ids"]).each { |code_id| canonical_requirements_by_code[code_id] << requirement_id }
    end

    code_changes.each do |code_id, item|
      unless code_id.to_s.match?(/\ACODE-\d+\z/) && item.is_a?(Hash)
        errors << "CODE ID 또는 mapping 불일치: #{code_id}"
        next
      end
      if canonical_requirements_by_code[code_id].empty?
        errors << "#{code_id}의 canonical REQ.code_ids 연결 누락"
      end
      %w[file symbol insertion_point current_code proposed_code].each do |field|
        errors << "#{code_id} #{field}는 비어 있지 않은 문자열이어야 합니다" unless text?(item[field])
      end
      errors << "#{code_id} design_concept는 구현 의도가 드러나는 구체적 문자열이어야 합니다" unless concrete_handoff_text?(item["design_concept"])
      shared_handoff_labels = ["현재 코드", "제안 코드", "Public API/type", "Core state/action", "Caller/assembly"]
      validate_handoff_section(code_text, code_id, "Public API/type", item["public_api_or_type"], errors, allow_na: true, allowed_labels: shared_handoff_labels)
      validate_handoff_section(code_text, code_id, "Core state/action", item["core_state_action_or_branch"], errors, allowed_labels: shared_handoff_labels)
      validate_handoff_section(code_text, code_id, "Caller/assembly", item["caller_assembly"], errors, allowed_labels: shared_handoff_labels)
      validate_private_implementation_scope(code_text, code_id, item["private_implementation_scope"], errors) if item.key?("private_implementation_scope")
      errors << "#{code_id} preserved_contracts 타입 또는 값 불일치" unless string_list?(item["preserved_contracts"])
      %w[requirements callers tests].each do |field|
        errors << "#{code_id} #{field} 타입 또는 값 불일치" if item.key?(field) && !string_list?(item[field])
      end
      if item.key?("imports_dependencies") && !text_or_string_list?(item["imports_dependencies"])
        errors << "#{code_id} imports_dependencies 타입 또는 값 불일치"
      end
      flow = item["flow"]
      unless flow.is_a?(Hash)
        errors << "#{code_id} State/Action/Effect/Delegate/Flow mapping 누락"
      else
        FLOW_KEYS.each do |field|
          errors << "#{code_id} flow.#{field} 타입 또는 값 불일치" unless text_or_string_list?(flow[field])
        end
      end

      %w[현재 제안].each do |side|
        reference_field = side == "현재" ? "current_code" : "proposed_code"
        validate_handoff_section(code_text, code_id, "#{side} 코드", item[reference_field], errors)
      end
      if UI_PROFILES.include?(data["context_profile"].to_s)
        validate_ui_literal_metrics(code_text, code_id, canonical_requirements_by_code[code_id], item, errors)
      end
    end

    code_changes.each do |code_id, item|
      next unless item.is_a?(Hash) && item.key?("requirements")
      unless Array(item["requirements"]).map(&:to_s).uniq.sort == canonical_requirements_by_code[code_id].map(&:to_s).uniq.sort
        errors << "#{code_id}.requirements가 canonical REQ.code_ids의 reverse edge 집합과 다릅니다"
      end
    end

    requirements.each do |requirement_id, item|
      next unless item.is_a?(Hash) && item.key?("files_symbols")
      expected_symbols = Array(item["code_ids"]).each_with_object([]) do |code_id, symbols|
        code = code_changes[code_id]
        next unless code.is_a?(Hash) && text?(code["file"]) && text?(code["symbol"])
        symbols << "#{code['file']}##{code['symbol']}"
      end.sort
      actual_symbols = Array(item["files_symbols"]).select { |value| value.is_a?(String) }.sort
      unless actual_symbols == expected_symbols
        errors << "#{requirement_id}.files_symbols가 연결 CODE의 canonical file#symbol 집합과 다릅니다"
      end
    end

    repository_path = existing_test_repository(tests, repository, errors)
    canonical_tests_by_requirement = Hash.new { |hash, key| hash[key] = [] }
    canonical_tests_by_code = Hash.new { |hash, key| hash[key] = [] }
    executable_tests_by_requirement = Hash.new { |hash, key| hash[key] = [] }
    executable_tests_by_code = Hash.new { |hash, key| hash[key] = [] }
    static_tests_by_requirement = Hash.new { |hash, key| hash[key] = [] }
    static_tests_by_code = Hash.new { |hash, key| hash[key] = [] }
    tests.each do |test_id, item|
      unless test_id.to_s.match?(/\ATEST-\d+\z/) && item.is_a?(Hash)
        errors << "direct test ID 또는 mapping 불일치: #{test_id}"
        next
      end
      verification_kind = item["verification_kind"].to_s
      executable = validate_verification_item(
        test_id,
        item,
        code_text,
        repository_path,
        errors
      )
      errors << "#{test_id} covers는 비어 있지 않은 문자열 배열이어야 합니다" unless string_list?(item["covers"])
      covers = Array(item["covers"]).map(&:to_s)
      errors << "#{test_id}는 REQ ID를 직접 연결해야 합니다" unless covers.any? { |id| requirements.key?(id) }
      errors << "#{test_id}는 CODE ID를 직접 연결해야 합니다" unless covers.any? { |id| code_changes.key?(id) }
      covers.each do |covered_id|
        unless requirements.key?(covered_id) || code_changes.key?(covered_id)
          errors << "#{test_id}.covers의 알 수 없는 ID: #{covered_id}"
        end
      end
      covers.each do |covered_id|
        canonical_tests_by_requirement[covered_id] << test_id if requirements.key?(covered_id)
        canonical_tests_by_code[covered_id] << test_id if code_changes.key?(covered_id)
        executable_tests_by_requirement[covered_id] << test_id if executable && requirements.key?(covered_id)
        executable_tests_by_code[covered_id] << test_id if executable && code_changes.key?(covered_id)
        static_tests_by_requirement[covered_id] << test_id if verification_kind == "static_review" && requirements.key?(covered_id)
        static_tests_by_code[covered_id] << test_id if verification_kind == "static_review" && code_changes.key?(covered_id)
      end
    end

    requirements.each do |requirement_id, item|
      next unless item.is_a?(Hash)
      canonical = canonical_tests_by_requirement[requirement_id].uniq.sort
      errors << "#{requirement_id}를 covers하는 direct test 누락" if canonical.empty?
      if item.key?("tests") && Array(item["tests"]).map(&:to_s).uniq.sort != canonical
        errors << "#{requirement_id}.tests가 canonical TEST.covers의 reverse edge 집합과 다릅니다"
      end
      if static_requires_executable?(static_tests_by_requirement[requirement_id], tests) && executable_tests_by_requirement[requirement_id].empty?
        errors << "#{requirement_id}의 static_review는 실행 가능한 행동 검증을 대체할 수 없습니다"
      end
    end
    code_changes.each do |code_id, item|
      next unless item.is_a?(Hash)
      canonical = canonical_tests_by_code[code_id].uniq.sort
      errors << "#{code_id}를 covers하는 direct test 누락" if canonical.empty?
      if item.key?("tests") && Array(item["tests"]).map(&:to_s).uniq.sort != canonical
        errors << "#{code_id}.tests가 canonical TEST.covers의 reverse edge 집합과 다릅니다"
      end
      if static_requires_executable?(static_tests_by_code[code_id], tests) && executable_tests_by_code[code_id].empty?
        errors << "#{code_id}의 static_review는 실행 가능한 행동 검증을 대체할 수 없습니다"
      end
    end
  end

  def static_requires_executable?(test_ids, tests)
    return false if test_ids.empty?

    test_ids.any? do |test_id|
      !not_applicable_reason?(tests.fetch(test_id)["executable_not_applicable"])
    end
  end

  def existing_test_repository(tests, repository, errors)
    needs_repository = tests.is_a?(Hash) && tests.any? do |_test_id, item|
      item.is_a?(Hash) && item["verification_kind"] == "existing_test"
    end
    return nil unless needs_repository
    if repository.to_s.strip.empty?
      errors << "existing_test 검증에는 --repository Git root가 필요합니다"
      return nil
    end

    path = Pathname(repository).expand_path
    output, error, status = Open3.capture3("git", "-C", path.to_s, "rev-parse", "--show-toplevel")
    unless status.success?
      errors << "--repository가 Git worktree가 아닙니다: #{error.strip}"
      return nil
    end
    root = Pathname(output.strip).realpath
    unless path.directory? && root == path.realpath
      errors << "--repository는 Git worktree root여야 합니다"
      return nil
    end
    root
  rescue Errno::ENOENT
    errors << "--repository를 읽을 수 없습니다: #{repository}"
    nil
  end

  def validate_verification_item(test_id, item, code_text, repository, errors)
    kind = item["verification_kind"].to_s
    if kind.empty?
      %w[file identifier command].each do |field|
        errors << "#{test_id} #{field}는 비어 있지 않은 문자열이어야 합니다" unless text?(item[field])
      end
      test_code = item["test_code"]
      test_not_applicable = item["test_not_applicable"]
      if concrete_handoff_text?(test_code) == not_applicable_reason?(test_not_applicable)
        errors << "#{test_id}는 직접 테스트 코드 또는 이유 있는 test_not_applicable 중 하나를 가져야 합니다"
      end
      validate_handoff_section(code_text, test_id, "Direct test", test_code, errors, direct_test: true) if concrete_handoff_text?(test_code)
      return concrete_handoff_text?(test_code)
    end

    unless VERIFICATION_KINDS.include?(kind)
      errors << "#{test_id}.verification_kind는 existing_test 또는 static_review여야 합니다"
      return false
    end
    %w[change failure_risk method pass_criterion].each do |field|
      errors << "#{test_id}.#{field}는 비어 있지 않은 문자열이어야 합니다" unless concrete_handoff_text?(item[field])
    end
    if concrete_handoff_text?(item["test_code"]) || item.key?("test_not_applicable")
      errors << "#{test_id}.#{kind}는 test_code/test_not_applicable을 사용하지 않습니다"
    end

    if kind == "existing_test"
      %w[file identifier command].each do |field|
        errors << "#{test_id} #{field}는 비어 있지 않은 문자열이어야 합니다" unless text?(item[field])
      end
      validate_existing_test_source(test_id, item, repository, errors) if repository
      true
    else
      unless STATIC_REVIEW_TYPES.include?(item["review_type"])
        errors << "#{test_id}.review_type은 source_review, visual_review, static_analysis 중 하나여야 합니다"
      end
      %w[independent_expectation scope applicability_reason].each do |field|
        errors << "#{test_id}.#{field}는 비어 있지 않은 구체적 문자열이어야 합니다" unless concrete_handoff_text?(item[field])
      end
      if item.key?("executable_not_applicable") && !not_applicable_reason?(item["executable_not_applicable"])
        errors << "#{test_id}.executable_not_applicable은 not_applicable: <구체적 이유> 형식이어야 합니다"
      end
      false
    end
  end

  def validate_existing_test_source(test_id, item, repository, errors)
    relative = item["file"].to_s
    path = repository.join(relative).cleanpath
    inside = path.relative_path_from(repository).to_s
    if inside == ".." || inside.start_with?("../")
      errors << "#{test_id}.file이 repository 밖입니다: #{relative}"
      return
    end
    unless relative.split(/[\\\/]/).any? { |part| part.match?(/tests?/i) }
      errors << "#{test_id}.file은 test source 경로여야 합니다: #{relative}"
      return
    end
    unless path.file?
      errors << "#{test_id}.file이 현재 repository에 없습니다: #{relative}"
      return
    end
    real_inside = path.realpath.relative_path_from(repository.realpath).to_s
    if real_inside == ".." || real_inside.start_with?("../")
      errors << "#{test_id}.file symlink realpath이 repository 밖입니다: #{relative}"
      return
    end
    source = path.read(encoding: "UTF-8")
    identifier = item["identifier"].to_s
    unless source.include?(identifier)
      errors << "#{test_id}.identifier가 현재 test source에 문자열 그대로 없습니다: #{identifier}"
    end
  rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    errors << "#{test_id}.file을 repository test source로 확인할 수 없습니다: #{relative}"
  end

  def validate_ui_mapping(data, mapping, errors)
    profile = data["context_profile"].to_s
    facets = Array(data["context_facets"]).map(&:to_s)
    ui = mapping["ui"]
    unless UI_PROFILES.include?(profile)
      errors << "UI context가 필요하면 context_profile은 ui 또는 mixed여야 합니다"
    end
    unless ui.is_a?(Hash)
      errors << "ui/mixed 기능의 UI source coverage 누락"
      return
    end

    source = ui["source"]
    unless source.is_a?(Hash)
      errors << "UI source mapping 누락"
    else
      %w[identity role reference].each do |field|
        errors << "UI source.#{field}는 비어 있지 않은 문자열이어야 합니다" unless text?(source[field])
      end
      role = source["role"].to_s
      errors << "지원하지 않는 UI source role: #{role}" unless UI_SOURCE_ROLES.include?(role)
    end
    errors << "UI render_root는 비어 있지 않은 문자열이어야 합니다" unless text?(ui["render_root"])

    coverage = ui["coverage"]
    unless coverage.is_a?(Array) && !coverage.empty?
      errors << "UI coverage 행 누락"
      return
    end
    omissions = ui["not_applicable"]
    omissions = {} unless omissions.is_a?(Hash)
    kinds = coverage.each_with_object([]) do |row, values|
      values << row["kind"].to_s if row.is_a?(Hash)
    end
    required_kinds = %w[region state interaction navigation]
    required_kinds += %w[geometry preview snapshot] if ui["visual"] == true
    required_kinds.each do |kind|
      next if kinds.include?(kind)
      next if text?(omissions[kind]) && !(%w[geometry preview snapshot].include?(kind) && ui["visual"] == true)
      errors << "UI #{kind} coverage 행 또는 not_applicable 사유 누락"
    end

    requirements = mapping["requirements"].is_a?(Hash) ? mapping["requirements"] : {}
    code_changes = mapping["code_changes"].is_a?(Hash) ? mapping["code_changes"] : {}
    tests = mapping["tests"].is_a?(Hash) ? mapping["tests"] : {}
    coverage.each_with_index do |row, index|
      unless row.is_a?(Hash)
        errors << "UI coverage[#{index}] mapping 불일치"
        next
      end
      %w[kind id requirement code_id source code].each do |field|
        errors << "UI coverage[#{index}].#{field}는 비어 있지 않은 문자열이어야 합니다" unless text?(row[field])
      end
      errors << "UI coverage[#{index}].tests는 비어 있지 않은 문자열 배열이어야 합니다" unless string_list?(row["tests"])
      errors << "UI coverage[#{index}] 알 수 없는 requirement" unless requirements.key?(row["requirement"])
      errors << "UI coverage[#{index}] 알 수 없는 code_id" unless code_changes.key?(row["code_id"])
      Array(row["tests"]).each do |test_id|
        errors << "UI coverage[#{index}] 알 수 없는 test: #{test_id}" unless tests.key?(test_id)
      end
    end

    conditional = coverage.any? do |row|
      row.is_a?(Hash) && row["kind"] == "state" && row["conditional"] == true
    end
    if conditional && !facets.include?("state-management")
      errors << "conditional state에는 state-management facet이 필요합니다"
    end

    destinations = coverage.select do |entry|
      entry.is_a?(Hash) && entry["kind"] == "navigation" && text?(entry["destination"])
    end
    unless destinations.empty?
      errors << "destination이 있으면 context_profile은 mixed여야 합니다" unless profile == "mixed"
      errors << "destination이 있으면 flow-navigation facet이 필요합니다" unless facets.include?("flow-navigation")
      destinations.each do |entry|
        %w[id trigger destination flow tests].each do |field|
          valid = field == "tests" ? string_list?(entry[field]) : text?(entry[field])
          errors << "navigation destination #{field} 타입 또는 값 불일치" unless valid
        end
      end
    end

    if ui["visual"] == true
      errors << "visual UI에는 ui-system facet이 필요합니다" unless facets.include?("ui-system")
      errors << "visual UI에는 testing facet이 필요합니다" unless facets.include?("testing")
    end
  end

  # This is intentionally a narrow literal review, not Swift parsing or a
  # semantic claim about every numeric value in a proposed UI implementation.
  def validate_ui_literal_metrics(code_text, code_id, requirement_ids, item, errors)
    candidates = fenced_section_codes(code_text, "### #{code_id} 제안 코드").flat_map { |proposed| proposed_metric_calls(proposed) }.uniq
    return if candidates.empty?

    exceptions = item["local_metric_exceptions"]
    exceptions = [] if exceptions.nil?
    unless exceptions.is_a?(Array)
      errors << "#{code_id} local_metric_exceptions는 배열이어야 합니다"
      return
    end
    candidates.each do |expression|
      matching = exceptions.select { |entry| entry.is_a?(Hash) && entry["expression"] == expression }
      if matching.empty?
        errors << "#{code_id} 제안 UI literal metric은 token 또는 local_metric_exceptions 근거가 필요합니다: #{expression}"
        next
      end
      matching.each { |entry| validate_local_metric_exception(code_id, requirement_ids, entry, errors) }
    end
  end

  def fenced_section_codes(markdown, heading)
    section = WorkplanLayout.markdown_section(markdown, heading)
    section.scan(/```(?:swift|swiftui)\s*\n(.*?)```/im).flatten
  end

  def proposed_metric_calls(code)
    code = code.gsub(%r{//[^\n]*}, "")
    calls = code.scan(/(?:\.(?:frame|padding|cornerRadius)\s*|(?:HStack|VStack|ZStack|LazyVStack|LazyHStack)\s*)\((?:[^()]|\([^()]*\))*?\)/m)
    calls.map(&:strip).select do |call|
      call.match?(/\.frame\s*\([^)]*\b(?:minWidth|maxWidth|width|minHeight|maxHeight|height)\s*:\s*-?\d+(?:\.\d+)?/m) ||
        call.match?(/\.padding\s*\(\s*(?:\.[A-Za-z]+\s*,\s*)?-?\d+(?:\.\d+)?/m) ||
        call.match?(/\.cornerRadius\s*\(\s*-?\d+(?:\.\d+)?/) ||
        call.match?(/\bspacing\s*:\s*-?\d+(?:\.\d+)?/)
    end.uniq
  end

  def validate_local_metric_exception(code_id, canonical_requirement_ids, entry, errors)
    %w[expression source missing_public_token_reason boundary].each do |field|
      errors << "#{code_id} local metric exception #{field}는 비어 있지 않은 문자열이어야 합니다" unless text?(entry[field])
    end
    requirement_ids = entry["requirement_ids"]
    canonical = Array(canonical_requirement_ids).map(&:to_s).uniq.sort
    errors << "#{code_id} local metric exception requirement_ids는 canonical REQ.code_ids와 같은 비어 있지 않은 문자열 배열이어야 합니다" unless string_list?(requirement_ids) && requirement_ids.uniq.sort == canonical
  end

  def nonempty_hash?(value)
    value.is_a?(Hash) && !value.empty?
  end

  def text?(value)
    value.is_a?(String) && !value.strip.empty? && value.strip != "not_applicable"
  end

  def boolean?(value)
    value == true || value == false
  end

  def string_list?(value)
    value.is_a?(Array) && !value.empty? && value.all? { |item| text?(item) }
  end

  def text_or_string_list?(value)
    text?(value) || string_list?(value)
  end

  def not_applicable_reason?(value)
    value.is_a?(String) && value.strip.match?(/\Anot_applicable\s*:\s*\S.+/)
  end

  def concrete_handoff_text?(value)
    text?(value) && !placeholder_or_vague?(value)
  end

  def placeholder_or_vague?(value)
    value.to_s.match?(/\.\.\.|\bTODO\b|\bTBD\b|\bexample\b|예시/i)
  end

  def validate_handoff_section(code_text, id, label, reference, errors, allow_na: false, direct_test: false, allowed_labels: nil)
    return if allow_na && not_applicable_reason?(reference)

    labels = allowed_labels || [label]
    references = labels.map { |allowed_label| "#{id} #{allowed_label}" }
    unless references.include?(reference)
      errors << "#{id} #{label}는 같은 CODE의 허용된 code heading을 가리켜야 합니다: #{references.join(', ')}"
      return
    end
    heading = "### #{reference}"
    block = WorkplanLayout.markdown_section(code_text, heading)
    if block.empty?
      errors << "#{heading} 누락"
      return
    end
    fence = block.match(/```([^\n]+)\n(.*?)```/m)
    unless fence
      errors << "#{heading} language tag이 있는 code fence 누락"
      return
    end
    code = fence[2].strip
    if code.empty?
      errors << "#{heading} code fence는 공백일 수 없습니다"
      return
    end
    errors << "#{heading}에는 .../TODO/TBD/모호한 example placeholder를 사용할 수 없습니다" if placeholder_or_vague?(code)
    errors << "#{heading}에는 균형 잡힌 실제 code shape가 필요합니다" unless code_like?(code) || (direct_test && assertion_like?(code))
    if direct_test && !assertion_like?(code)
      errors << "#{heading}에는 assertion signal이 필요합니다"
    end
  end

  def validate_private_implementation_scope(code_text, code_id, reference, errors)
    return if not_applicable_reason?(reference)

    label = "Private implementation scope"
    heading = "### #{code_id} #{label}"
    unless reference == "#{code_id} #{label}"
      errors << "#{code_id} #{label}는 #{heading.inspect}를 가리키거나 이유 있는 not_applicable이어야 합니다"
      return
    end
    scope = WorkplanLayout.markdown_section(code_text, heading)
    if scope.match?(/```/)
      errors << "#{heading}에는 private body code fence를 둘 수 없습니다"
      return
    end
    fields = scope.lines.map(&:strip).reject(&:empty?)
    unless fields.length == 2
      errors << "#{heading}는 delegated_private_details와 fixed_contract_boundaries 두 필드만 가져야 합니다"
      return
    end
    expected_fields = %w[delegated_private_details fixed_contract_boundaries]
    parsed = fields.each_with_object({}) do |line, result|
      key, value = line.split(":", 2)
      result[key] = value&.strip
    end
    unless parsed.keys.sort == expected_fields.sort && parsed.values.all? { |value| private_scope_prose?(value) }
      errors << "#{heading}는 구체적인 delegated_private_details와 fixed_contract_boundaries를 가져야 합니다"
    end
  end

  def code_like?(value)
    return false unless balanced_delimiters?(value)

    shapes = []
    value.each_line do |line|
      shapes << :declaration if line.match?(/^\s*(?:(?:public|private|internal|open|final|static)\s+)*(?:func|struct|class|enum|protocol|let|var|const|def|function)\b/)
      shapes << :branch if line.match?(/^\s*(?:case\s+[^:]+:|if\s*\(|switch\s+|guard\s+)/)
      shapes << :return if line.match?(/^\s*return\b/) || line.match?(/^\s*case\s+[^:]+:.*\breturn\b/)
      shapes << :assignment if line.match?(/^\s*(?:(?:let|var|const)\s+)?[A-Za-z_][A-Za-z0-9_]*\s*(?:=|:=)/)
      shapes << :call if line.match?(/^\s*(?:#expect|[A-Za-z_][A-Za-z0-9_.]*)\s*\(/)
    end
    shapes.include?(:declaration) || (shapes.uniq & %i[branch return assignment call]).length >= 2
  end

  def balanced_delimiters?(value)
    pairs = { ")" => "(", "}" => "{", "]" => "[" }
    stack = []
    value.each_char do |character|
      if pairs.value?(character)
        stack << character
      elsif pairs.key?(character)
        return false unless stack.pop == pairs[character]
      end
    end
    stack.empty?
  end

  def assertion_like?(value)
    value.match?(/#expect\s*\(|\bXCTAssert\w*\s*\(|\bassert\w*\s*\(|\bexpect\s*\(|\bshould\s*\(|\.should\s*\(/i)
  end

  def private_scope_prose?(value)
    return false unless concrete_handoff_text?(value)

    !code_like?(value) && !value.match?(/[{};]|\b(?:func|def|function|class|struct|enum)\b|\b[A-Za-z_][A-Za-z0-9_]*\s*\([^)]*\)/)
  end
end

options = { phase: "approval" }
command = ARGV.shift
if command == "digest"
  inventory_path = ARGV.shift
  abort "usage: feature-plan-gate digest <expected-sources.yml>" unless inventory_path && ARGV.empty?
  digest_errors = []
  inventory = FeaturePlanGate.parse_expected_sources(inventory_path, digest_errors)
  abort digest_errors.join("\n") unless digest_errors.empty? && inventory
  puts FeaturePlanGate.inventory_digest(inventory)
  exit
end

abort "usage: feature-plan-gate validate [--phase approval|apply] [--expected-sources PATH] [--repository PATH] <workplan>" unless command == "validate"
OptionParser.new do |parser|
  parser.on("--phase PHASE") { |value| options[:phase] = value }
  parser.on("--expected-sources PATH") { |value| options[:expected_sources] = value }
  parser.on("--repository PATH") { |value| options[:repository] = value }
end.parse!
abort "phase는 approval 또는 apply여야 합니다" unless %w[approval apply].include?(options[:phase])
path = ARGV.shift
abort "usage: feature-plan-gate validate [--phase approval|apply] [--expected-sources PATH] [--repository PATH] <workplan>" unless path && ARGV.empty?

begin
  puts FeaturePlanGate.validate(
    path,
    phase: options[:phase],
    expected_sources: options[:expected_sources],
    repository: options[:repository]
  )
rescue FeaturePlanGate::ValidationError => error
  warn error.message
  exit 1
end
