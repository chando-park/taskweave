#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "rexml/document"
require "securerandom"
require "tempfile"
require "yaml"
require_relative "workplan-layout"
require_relative "ui-image-compare"
require_relative "implementation-explanation-gate"
require_relative "verification-plan"

module UIVerificationGate
  class ValidationError < StandardError; end

  SCHEMA = "ui-conformance-evidence-v1"
  INVENTORY_SCHEMA = "canonical-visual-requirements-v1"
  PHASES = %w[plan source candidate pre-golden completion].freeze
  TIERS = %w[none regression conformance full].freeze
  SHA256 = /\Asha256:[0-9a-f]{64}\z/
  SOURCE_KINDS = %w[figma].freeze
  NODE_SCOPES = %w[full-render-boundary component-boundary].freeze

  module_function

  RECEIPT_ISSUER = "ui-verification-gate"
  RECEIPT_ISSUER_VERSION = 2
  STATE_SCHEMA = "ui-verification-runtime-state-v2"
  OPERATION_ID = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  def validate(workplan, phase:, issue_receipt: nil, repository: nil)
    workplan = Pathname(workplan).expand_path
    raise ValidationError, "Workplan이 없습니다: #{workplan}" unless workplan.file?
    raise ValidationError, "지원하지 않는 phase입니다: #{phase}" unless PHASES.include?(phase)
    _raw, data = WorkplanLayout.frontmatter(workplan.read(encoding: "UTF-8"))
    tier = data["ui_verification_tier"]
    if tier.nil?
      validate_implementation_completion_early(workplan, data, phase, repository)
      return "UI verification gate skipped: non-UI Workplan" unless ui_workplan?(workplan, data)
      raise ValidationError, "UI Workplan의 ui_verification_tier가 누락되었습니다"
    end
    raise ValidationError, "ui_verification_tier는 문자열이어야 합니다" unless tier.is_a?(String)
    raise ValidationError, "지원하지 않는 ui_verification_tier입니다: #{tier.inspect}" unless TIERS.include?(tier)
    if tier == "none"
      validate_implementation_completion_early(workplan, data, phase, repository)
      return validate_none(workplan, data, phase: phase)
    end

    inventory = read_packet(workplan, data, %w[requirements description], "## Canonical Visual Requirement Inventory (`#{INVENTORY_SCHEMA}`)", "canonical_visual_requirement_inventory")
    plan = read_packet(workplan, data, %w[test_plan description], "## UI 적합성 계획 (`#{SCHEMA}`)", "ui_conformance_plan")
    errors = []
    repository_identity = required_repository_identity(repository, tier, phase, errors)
    validate_implementation_before_render(workplan, data, phase, repository, errors)
    inventory_digest = validate_inventory(workplan, data, inventory, errors)
    validate_plan(plan, tier, inventory, inventory_digest, errors)

    if tier == "regression"
      raise ValidationError, "regression은 source/candidate/pre-golden phase를 실행하지 않습니다" if %w[source candidate pre-golden].include?(phase)
      scoped_head_reuse = false
      if phase == "completion"
        scoped_head_reuse = validate_regression_completion(workplan, data, evidence_packet(workplan, data), plan, inventory_digest,
                                                           repository_identity, errors)
      end
      validate_regression_identity(workplan, data, plan["golden_identity"], inventory, inventory_digest, repository_identity, errors,
                                   allow_head_change: scoped_head_reuse)
    elsif phase == "source"
      if issue_receipt.nil?
        errors << "source phase는 --issue-receipt PATH로 독립 source 등록 receipt를 발급해야 합니다"
      elsif errors.empty?
        issued_receipt = issue_source_registration(workplan, data, issue_receipt, inventory, inventory_digest, errors)
      end
    elsif phase != "plan"
      issued_receipt = validate_conformance_evidence(workplan, data, evidence_packet(workplan, data), plan, inventory, inventory_digest, tier, phase, errors,
                                                     repository_identity: repository_identity, issue_receipt: issue_receipt)
    end

    raise ValidationError, errors.join("\n") unless errors.empty?
    return { "status" => "valid", "tier" => tier, "phase" => phase, "issued_receipt" => issued_receipt } if issued_receipt
    "UI verification gate valid: #{tier} #{phase}"
  rescue Psych::SyntaxError, JSON::ParserError, REXML::ParseException, KeyError => error
    raise ValidationError, "UI verification packet을 해석할 수 없습니다: #{error.message}"
  end

  def validate_implementation_before_render(workplan, data, phase, repository, errors)
    return unless phase == "completion"
    return unless data["plan_code_evidence"] == "required"
    return unless %w[features bugs].include?(data["workplan_kind"])
    return if repository.to_s.strip.empty?

    ImplementationExplanationGate.validate(workplan, repository: repository)
  rescue ImplementationExplanationGate::ValidationError => error
    errors << "UI 검증 전에 구현 설명 gate가 통과해야 합니다: #{error.message}"
  end

  def validate_implementation_completion_early(workplan, data, phase, repository)
    errors = []
    validate_implementation_before_render(workplan, data, phase, repository, errors)
    raise ValidationError, errors.join("\n") unless errors.empty?
  end

  # Read-only provenance boundary for narrowly scoped feedback consumers.
  # Reuses the complete inventory, receipt, payload, and Runtime-state checks.
  def validate_source_registration_for_reuse(workplan, receipt_info, source_id:)
    workplan = Pathname(workplan).expand_path
    raise ValidationError, "Workplan이 없습니다: #{workplan}" unless workplan.file?
    _raw, data = WorkplanLayout.frontmatter(workplan.read(encoding: "UTF-8"))
    tier = data["ui_verification_tier"]
    unless %w[conformance full].include?(tier)
      raise ValidationError, "source registration reuse에는 conformance 또는 full UI 계획이 필요합니다"
    end
    inventory = read_packet(workplan, data, %w[requirements description], "## Canonical Visual Requirement Inventory (`#{INVENTORY_SCHEMA}`)", "canonical_visual_requirement_inventory")
    plan = read_packet(workplan, data, %w[test_plan description], "## UI 적합성 계획 (`#{SCHEMA}`)", "ui_conformance_plan")
    errors = []
    digest = validate_inventory(workplan, data, inventory, errors)
    validate_plan(plan, tier, inventory, digest, errors)
    source = inventory.fetch("sources", {})[source_id]
    errors << "source_id가 canonical inventory에 없습니다" unless source.is_a?(Hash)
    registered = source && validate_registration(workplan, data, receipt_info, role: "source", source: source, candidate: nil,
                                                 inventory: inventory, inventory_digest: digest, errors: errors)
    errors << "source registration을 검증하지 못했습니다" unless registered
    raise ValidationError, errors.join("\n") unless errors.empty?
    {
      "source_id" => source_id,
      "canonical_requirement_ids" => requirement_assertion_ids(inventory, source_id: source_id).keys.sort,
      "approved_snapshot_ids" => plan.fetch("approved_snapshot_ids").sort,
      "visible_region_ids" => Array(source["visible_region_ids"]).sort,
      "source_identity" => source.slice("file", "node", "revision", "state", "viewport", "boundary_id").merge("hash" => source["hash"]),
      "source_artifact_identity" => registered.dig("payload", "sources", source_id, "source_artifact_identity"),
      "operation_id" => registered["operation_id"]
    }
  rescue Psych::SyntaxError, JSON::ParserError, KeyError => error
    raise ValidationError, "source registration reuse packet을 해석할 수 없습니다: #{error.message}"
  end

  def validate_none(workplan, data, phase:)
    reason = data["ui_verification_reason"]
    raise ValidationError, "ui_verification_tier none에는 문자열 생략 사유가 필요합니다" unless text?(reason)
    return "UI verification gate valid: none #{phase}" unless phase == "completion"

    evidence = data["ui_none_evidence"]
    raise ValidationError, "ui_verification_tier none에는 compile/behavior 증거가 필요합니다" unless evidence.is_a?(Hash)
    errors = []
    errors << "ui_none_evidence.kind는 compile 또는 behavior여야 합니다" unless %w[compile behavior].include?(evidence["kind"])
    path = validate_artifact(workplan, data, evidence["artifact"], evidence["hash"], errors, "ui none evidence")
    if path
      result = JSON.parse(path.read(encoding: "UTF-8"))
      errors << "ui none evidence schema 불일치" unless result["schema"] == "ui-none-evidence-v1"
      errors << "ui none evidence kind 불일치" unless result["kind"] == evidence["kind"]
      errors << "ui none evidence exit_status는 0이어야 합니다" unless result["exit_status"] == 0
      errors << "ui none evidence executed_count는 1 이상이어야 합니다" unless integer_positive?(result["executed_count"])
    end
    raise ValidationError, errors.join("\n") unless errors.empty?
    "UI verification gate valid: none"
  end

  def validate_inventory(workplan, data, inventory, errors)
    errors << "canonical visual inventory schema 불일치" unless inventory["schema"] == INVENTORY_SCHEMA
    sources = inventory["sources"]
    requirements = inventory["requirements"]
    errors << "canonical visual inventory sources 누락" unless nonempty_hash?(sources)
    errors << "canonical visual inventory requirements 누락" unless nonempty_hash?(requirements)
    digest = digest_for(inventory_projection(inventory))
    stored = data["visual_requirement_inventory_digest"]
    errors << "visual_requirement_inventory_digest 형식 또는 값 불일치" unless stored.is_a?(String) && stored.match?(SHA256) && stored == digest
    if sources.is_a?(Hash)
      sources.each do |source_id, source|
        unless source_id.to_s.match?(/\ASOURCE-[A-Za-z0-9_-]+\z/) && source.is_a?(Hash)
          errors << "canonical source ID 또는 mapping 불일치: #{source_id}"
          next
        end
        %w[file node revision state viewport boundary_id artifact hash receipt_artifact receipt_hash].each { |field| errors << "#{source_id}.#{field} 누락" unless text?(source[field]) }
        errors << "#{source_id}.source_kind는 figma여야 합니다" unless SOURCE_KINDS.include?(source["source_kind"])
        errors << "#{source_id}.node_scope는 전체 render 경계 또는 component 경계여야 합니다" unless NODE_SCOPES.include?(source["node_scope"])
        errors << "#{source_id}.coverage_complete는 true여야 합니다" unless source["coverage_complete"] == true
        errors << "#{source_id}.visible_region_ids는 중복 없는 비어 있지 않은 배열이어야 합니다" unless unique_string_array?(source["visible_region_ids"])
        validate_source_receipt(workplan, data, source_id, source, inventory, digest, errors)
      end
    end
    if requirements.is_a?(Hash)
      requirements.each do |requirement_id, requirement|
        unless requirement_id.to_s.match?(/\AREQ-[A-Za-z0-9_-]+\z/) && requirement.is_a?(Hash)
          errors << "canonical visual requirement ID 또는 mapping 불일치: #{requirement_id}"
          next
        end
        errors << "#{requirement_id}.source_id가 canonical source에 없습니다" unless sources.is_a?(Hash) && sources.key?(requirement["source_id"])
        assertions = requirement["assertions"]
        unless nonempty_hash?(assertions)
          errors << "#{requirement_id}.assertions 누락"
          next
        end
        assertions.each do |assertion_id, assertion|
          unless assertion_id.to_s.match?(/\AASSERT-[A-Za-z0-9_-]+\z/) && assertion.is_a?(Hash)
            errors << "canonical assertion ID 또는 mapping 불일치: #{assertion_id}"
            next
          end
          %w[region property source_expected tolerance].each { |field| errors << "#{assertion_id}.#{field} 누락" unless text?(assertion[field]) }
          errors << "#{assertion_id}.critical은 boolean이어야 합니다" unless boolean?(assertion["critical"])
        end
      end
      validate_source_region_coverage(sources, requirements, errors)
    end
    validate_interaction_inventory(inventory["interactions"], sources, errors)
    digest
  end

  def validate_source_region_coverage(sources, requirements, errors)
    return unless sources.is_a?(Hash) && requirements.is_a?(Hash)

    sources.each do |source_id, source|
      next unless source.is_a?(Hash)
      declared = string_array(source["visible_region_ids"])
      asserted = requirements.values.select { |item| item.is_a?(Hash) && item["source_id"] == source_id }
                             .flat_map { |item| item.fetch("assertions", {}).values }
                             .select { |item| item.is_a?(Hash) && text?(item["region"]) }
                             .map { |item| item["region"] }.uniq.sort
      errors << "#{source_id} visible region과 assertion region이 완전히 일치해야 합니다" unless declared == asserted
    end
  end

  def validate_interaction_inventory(interactions, sources, errors)
    return if interactions.nil?
    unless interactions.is_a?(Hash)
      errors << "canonical interaction inventory는 mapping이어야 합니다"
      return
    end
    interactions.each do |id, interaction|
      unless id.to_s.match?(/\AINTERACTION-[A-Za-z0-9_-]+\z/) && interaction.is_a?(Hash)
        errors << "canonical interaction ID 또는 mapping 불일치: #{id}"
        next
      end
      errors << "#{id}.source_id가 canonical source에 없습니다" unless sources.is_a?(Hash) && sources.key?(interaction["source_id"])
      %w[trigger expected_effect test_id].each { |field| errors << "#{id}.#{field} 누락" unless text?(interaction[field]) }
    end
  end

  def validate_source_receipt(workplan, data, source_id, source, inventory, digest, errors)
    validate_artifact(workplan, data, source["artifact"], source["hash"], errors, "#{source_id} source export")
    receipt_path = validate_artifact(workplan, data, source["receipt_artifact"], source["receipt_hash"], errors, "#{source_id} source receipt")
    return unless receipt_path
    receipt = JSON.parse(receipt_path.read(encoding: "UTF-8"))
    errors << "#{source_id} source receipt schema 불일치" unless receipt["schema"] == "ui-source-export-receipt-v1"
    errors << "#{source_id} source receipt provider는 figma여야 합니다" unless receipt["provider"] == "figma"
    errors << "#{source_id} source receipt export_mode는 original-node여야 합니다" unless receipt["export_mode"] == "original-node"
    errors << "#{source_id} source receipt transform은 none이어야 합니다" unless receipt["transform"] == "none"
    errors << "#{source_id} source receipt source_id 불일치" unless receipt["source_id"] == source_id
    errors << "#{source_id} source receipt inventory_digest 불일치" unless receipt["inventory_digest"] == digest
    %w[file node revision state viewport boundary_id].each { |field| errors << "#{source_id} source receipt #{field} 불일치" unless receipt[field] == source[field] }
    %w[source_kind node_scope coverage_complete visible_region_ids].each { |field| errors << "#{source_id} source receipt #{field} 불일치" unless receipt[field] == source[field] }
    errors << "#{source_id} source receipt artifact_hash 불일치" unless receipt["artifact_hash"] == source["hash"]
    errors << "#{source_id} source receipt REQ/assertion inventory 불일치" unless receipt["requirement_assertion_ids"] == requirement_assertion_ids(inventory, source_id: source_id)
  end

  def validate_plan(plan, tier, inventory, inventory_digest, errors)
    errors << "UI 적합성 계획 schema 불일치" unless plan["schema"] == SCHEMA
    errors << "UI 적합성 계획 tier 불일치" unless plan["tier"] == tier
    errors << "UI 적합성 계획 inventory_digest 불일치" unless plan["inventory_digest"] == inventory_digest
    errors << "UI 적합성 계획 source_ids 불일치" unless string_array(plan["source_ids"]) == inventory.fetch("sources", {}).keys.sort
    errors << "UI 적합성 계획 REQ/assertion IDs가 canonical inventory와 다릅니다" unless plan["requirement_assertion_ids"] == requirement_assertion_ids(inventory)
    errors << "approved_snapshot_ids는 중복 없는 비어 있지 않은 문자열 배열이어야 합니다" unless unique_string_array?(plan["approved_snapshot_ids"])
    expected_interactions = interaction_test_ids(inventory)
    actual_interactions = plan["approved_interaction_test_ids"]
    errors << "approved_interaction_test_ids가 canonical interaction inventory와 다릅니다" unless actual_interactions.is_a?(Array) && actual_interactions.sort == expected_interactions
    errors << "regression 계획에는 source-traceable golden_identity가 필요합니다" if tier == "regression" && !plan["golden_identity"].is_a?(Hash)
  end

  def validate_regression_identity(workplan, data, identity, inventory, inventory_digest, repository_identity, errors, allow_head_change: false)
    return unless identity.is_a?(Hash)
    source = inventory.fetch("sources", {})[identity["source_id"]]
    unless source.is_a?(Hash)
      errors << "regression golden source_id가 canonical inventory에 없습니다"
      return
    end
    golden = identity["golden"]
    unless golden.is_a?(Hash)
      errors << "regression golden identity 누락"
      return
    end
    %w[render_root state viewport boundary_id artifact hash receipt_artifact receipt_hash].each { |field| errors << "regression golden.#{field} 누락" unless text?(golden[field]) }
    errors << "regression golden boundary/state/viewport 불일치" unless same_boundary?(source, golden)
    validate_artifact(workplan, data, golden["artifact"], golden["hash"], errors, "regression golden")
    receipt_path = validate_artifact(workplan, data, golden["receipt_artifact"], golden["receipt_hash"], errors, "regression golden receipt")
    return unless receipt_path
    receipt = JSON.parse(receipt_path.read(encoding: "UTF-8"))
    payload = validate_gate_receipt(workplan, data, { "artifact" => golden["receipt_artifact"], "hash" => golden["receipt_hash"] }, receipt,
                                    role: "golden", schema: "source-traceable-golden-gate-receipt-v2", errors: errors,
                                    bind_current_workplan: false)
    return unless payload
    errors << "regression golden receipt inventory_digest 불일치" unless payload["inventory_digest"] == inventory_digest
    errors << "regression golden receipt source_hash 불일치" unless payload["source_hash"] == source["hash"]
    errors << "regression golden receipt golden_hash 불일치" unless payload["golden_hash"] == golden["hash"]
    errors << "regression golden receipt는 승인 candidate와 Golden을 결속해야 합니다" unless payload["candidate_hash"] == golden["hash"]
    errors << "regression golden receipt boundary/state/viewport 불일치" unless payload["boundary"] == boundary(source)
    errors << "regression golden receipt REQ/assertion IDs 불일치" unless payload["requirement_assertion_ids"] == requirement_assertion_ids(inventory)
    if repository_identity
      golden_repository = payload["repository_identity"]
      same_checkout = golden_repository.is_a?(Hash) &&
        golden_repository.slice("worktree_root", "git_dir") == repository_identity.slice("worktree_root", "git_dir")
      same_head = golden_repository.is_a?(Hash) && golden_repository["head"] == repository_identity["head"]
      unless same_checkout && (same_head || allow_head_change)
        errors << "regression Golden이 현재 대상 Git worktree 또는 검증 가능한 입력 범위와 다릅니다"
      end
    end
  end

  def validate_regression_completion(workplan, data, evidence, plan, inventory_digest, repository_identity, errors)
    before = errors.length
    errors << "regression completion evidence schema 불일치" unless evidence["schema"] == SCHEMA
    errors << "regression completion evidence tier 불일치" unless evidence["tier"] == "regression"
    errors << "regression completion inventory_digest 불일치" unless evidence["inventory_digest"] == inventory_digest
    validate_snapshot(workplan, data, evidence["snapshot"], plan["approved_snapshot_ids"], completion: true,
                      repository_identity: repository_identity, errors: errors)
    evidence.dig("snapshot", "schema") == "snapshot-evidence-set-v2" && errors.length == before
  end

  def validate_conformance_evidence(workplan, data, evidence, plan, inventory, inventory_digest, tier, phase, errors,
                                    repository_identity:, issue_receipt: nil)
    errors << "UI 적합성 증거 schema 불일치" unless evidence["schema"] == SCHEMA
    errors << "UI 적합성 증거 tier 불일치" unless evidence["tier"] == tier
    errors << "UI 적합성 증거 inventory_digest 불일치" unless evidence["inventory_digest"] == inventory_digest
    source_id = evidence["source_id"]
    canonical_source = inventory.fetch("sources", {})[source_id]
    unless canonical_source.is_a?(Hash)
      errors << "evidence source_id가 canonical inventory에 없습니다"
      return
    end
    source = evidence["source"]
    candidate = evidence["candidate"]
    validate_source_evidence(workplan, data, source, canonical_source, source_id, inventory, inventory_digest, errors)
    source_registration = validate_registration(workplan, data, evidence["source_registration"], role: "source", source: source,
                                                candidate: nil, inventory: inventory, inventory_digest: inventory_digest, errors: errors)
    validate_candidate_evidence(workplan, data, candidate, canonical_source, inventory, inventory_digest, repository_identity, errors)
    errors << "source와 candidate boundary/state/viewport 불일치" unless source.is_a?(Hash) && candidate.is_a?(Hash) && same_boundary?(source, candidate)
    source_identity = artifact_identity(workplan, data, source["artifact"], errors, "독립 source identity") if source.is_a?(Hash)
    candidate_identity = artifact_identity(workplan, data, candidate["artifact"], errors, "app candidate identity") if candidate.is_a?(Hash)
    errors << "독립 source와 app candidate는 서로 다른 physical artifact identity/dev+inode여야 합니다" if same_physical_artifact?(source_identity, candidate_identity)
    if correction_requires_reproduction?(workplan, data)
      validate_pre_fix_reproduction(workplan, data, evidence["pre_fix"], source, candidate, repository_identity, errors)
    end

    if phase == "candidate"
      if issue_receipt.nil?
        errors << "candidate phase는 --issue-receipt PATH로 candidate 등록 receipt를 발급해야 합니다"
        return nil
      end
      return nil unless errors.empty? && source_registration
      validate_candidate_created_after_source(workplan, data, candidate, source_registration, errors)
      return nil unless errors.empty?
      return issue_candidate_registration(workplan, data, issue_receipt, source, candidate, inventory, inventory_digest, source_registration,
                                          source_identity, candidate_identity, repository_identity, errors)
    end

    candidate_registration = validate_registration(workplan, data, evidence["candidate_registration"], role: "candidate", source: source,
                                                   candidate: candidate, inventory: inventory, inventory_digest: inventory_digest,
                                                   source_registration: source_registration, repository_identity: repository_identity, errors: errors)
    if source_registration && candidate_registration && source_registration["operation_id"] == candidate_registration["operation_id"]
      errors << "source와 candidate는 서로 다른 gate operation provenance를 가져야 합니다"
    end
    validate_assertions(evidence["assertions"], inventory, errors)
    validate_comparison(workplan, data, evidence["comparison"], source, candidate, inventory, inventory_digest, errors)
    validate_review(workplan, data, evidence["independent_review"], source, candidate, evidence["comparison"], inventory, inventory_digest, tier, errors)
    validate_snapshot(workplan, data, evidence["snapshot"], plan["approved_snapshot_ids"], completion: phase == "completion",
                      repository_identity: repository_identity, errors: errors)
    validate_interaction_result(workplan, data, evidence["interaction"], plan["approved_interaction_test_ids"], errors) if %w[pre-golden completion].include?(phase)
    evidence_digest = conformance_digest(evidence)
    if phase == "pre-golden"
      validate_golden(workplan, data, evidence["golden"], candidate, nil, phase, errors)
      if issue_receipt.nil?
        errors << "pre-golden은 --issue-receipt PATH로 gate-issued receipt를 발급해야 합니다"
        return nil
      end
      return nil unless errors.empty?
      return issue_pre_golden_receipt(workplan, data, issue_receipt, source, candidate, evidence["comparison"], evidence["golden"], inventory, inventory_digest,
                                      evidence_digest, source_registration, candidate_registration, repository_identity, errors)
    end
    authorization = validate_pre_golden_receipt(workplan, data, evidence["pre_golden_receipt"], source, candidate, evidence["comparison"], evidence["golden"], inventory,
                                                inventory_digest, evidence_digest, source_registration, candidate_registration, repository_identity, errors)
    validate_golden(workplan, data, evidence["golden"], candidate, evidence["pre_golden_receipt"], phase, errors)
    if evidence.dig("golden", "provenance_receipt").is_a?(Hash)
      validate_golden_provenance(workplan, data, evidence["golden"], source, candidate, inventory, inventory_digest, authorization, repository_identity, errors)
    elsif issue_receipt.nil?
      errors << "completion은 --issue-receipt PATH로 gate-issued Golden provenance를 발급해야 합니다"
    elsif errors.empty? && authorization
      return issue_golden_provenance(workplan, data, issue_receipt, evidence["golden"], source, candidate, inventory, inventory_digest, authorization,
                                     repository_identity, errors)
    end
    nil
  end

  def correction_requires_reproduction?(workplan, data)
    data["workplan_kind"] == "bugs" || workplan.dirname.join("Artifacts/repository-feedback-baseline.json").file?
  end

  def validate_pre_fix_reproduction(workplan, data, pre_fix, source, candidate, repository_identity, errors)
    unless pre_fix.is_a?(Hash)
      errors << "UI 버그·피드백 수정에는 Figma와 수정 전 render의 실패 재현 증거가 필요합니다"
      return
    end
    %w[artifact hash receipt_artifact receipt_hash machine_report_artifact machine_report_hash].each do |field|
      errors << "pre_fix.#{field} 누락" unless text?(pre_fix[field])
    end
    artifact = validate_artifact(workplan, data, pre_fix["artifact"], pre_fix["hash"], errors, "pre-fix render")
    receipt_path = validate_artifact(workplan, data, pre_fix["receipt_artifact"], pre_fix["receipt_hash"], errors, "pre-fix receipt")
    report_path = validate_artifact(workplan, data, pre_fix["machine_report_artifact"], pre_fix["machine_report_hash"], errors, "pre-fix comparison")
    return unless artifact && receipt_path && report_path && source.is_a?(Hash) && candidate.is_a?(Hash)

    receipt = JSON.parse(receipt_path.read(encoding: "UTF-8"))
    schema = receipt["schema"]
    errors << "pre-fix receipt schema 불일치" unless %w[ui-pre-fix-render-receipt-v1 ui-pre-fix-render-receipt-v2].include?(schema)
    errors << "pre-fix source/render hash 불일치" unless receipt["source_hash"] == source["hash"] && receipt["artifact_hash"] == pre_fix["hash"]
    errors << "pre-fix boundary/state/viewport 불일치" unless receipt_boundary(receipt) == boundary(source)
    if schema == "ui-pre-fix-render-receipt-v2"
      validate_reused_pre_fix_context(workplan, data, receipt, candidate, repository_identity, errors)
    else
      errors << "legacy pre-fix render는 현재 대상 Git worktree/HEAD와 정확히 같아야 합니다" unless receipt["repository_identity"] == repository_identity
    end

    source_path = artifact_path(workplan, data, source["artifact"], errors, "pre-fix source")
    report = JSON.parse(report_path.read(encoding: "UTF-8"))
    if source_path
      thresholds = report["thresholds"] || {}
      recomputed = UIImageCompare.compare(source_path, artifact,
                                          pixel_tolerance: thresholds["pixel_tolerance"],
                                          max_changed_ratio: thresholds["max_changed_ratio"],
                                          max_mean_delta: thresholds["max_mean_delta"])
      errors << "pre-fix comparison report가 실제 PNG와 다릅니다" unless report == recomputed
      errors << "pre-fix는 Figma와 실제로 달라 실패해야 합니다" unless recomputed["result"] == "failed"
    end
    candidate_path = artifact_path(workplan, data, candidate["artifact"], errors, "post-fix candidate")
    errors << "pre-fix render는 post-fix candidate보다 먼저 생성되어야 합니다" if candidate_path && artifact.mtime >= candidate_path.mtime
  rescue UIImageCompare::Error, JSON::ParserError => error
    errors << "pre-fix 재현 증거를 검증할 수 없습니다: #{error.message}"
  end

  def validate_reused_pre_fix_context(workplan, data, receipt, candidate, repository_identity, errors)
    prior = receipt["repository_identity"]
    same_checkout = prior.is_a?(Hash) && repository_identity.is_a?(Hash) &&
      prior.slice("worktree_root", "git_dir") == repository_identity.slice("worktree_root", "git_dir")
    errors << "reused pre-fix render가 현재 대상 Git worktree와 다릅니다" unless same_checkout
    environment = receipt["render_environment"]
    errors << "reused pre-fix render_environment evidence가 필요합니다" unless nonempty_hash?(environment)
    candidate_receipt_path = candidate.is_a?(Hash) && validate_artifact(workplan, data, candidate["receipt_artifact"], candidate["receipt_hash"], errors,
                                                                         "reused pre-fix candidate receipt")
    if candidate_receipt_path
      candidate_receipt = JSON.parse(candidate_receipt_path.read(encoding: "UTF-8"))
      errors << "reused pre-fix와 post-fix candidate render environment가 다릅니다" unless candidate_receipt["render_environment"] == environment
    end
    inputs = receipt["stable_inputs"]
    unless inputs.is_a?(Array) && !inputs.empty?
      errors << "reused pre-fix에는 해시된 stable_inputs가 필요합니다"
      return
    end
    kinds = []
    paths = []
    inputs.each do |entry|
      unless entry.is_a?(Hash) && %w[tests resources dependency config environment].include?(entry["kind"]) &&
             text?(entry["path"]) && entry["sha256"].is_a?(String) && entry["sha256"].match?(SHA256)
        errors << "reused pre-fix stable input 형식이 잘못되었습니다"
        next
      end
      kinds << entry["kind"]
      paths << entry["path"]
      root = repository_identity && repository_identity["worktree_root"]
      path = root && safe_path(Pathname(root), entry["path"], errors, "reused pre-fix stable input", allow_missing: false)
      actual = path&.file? ? "sha256:#{Digest::SHA256.file(path).hexdigest}" : nil
      errors << "reused pre-fix stable input이 변경되었거나 없습니다: #{entry['path']}" unless actual == entry["sha256"]
    end
    errors << "reused pre-fix stable input 경로는 중복될 수 없습니다" unless paths.uniq.length == paths.length
    required = %w[tests config environment]
    errors << "reused pre-fix에는 tests/config/environment input evidence가 필요합니다" unless (required - kinds.uniq).empty?
  rescue JSON::ParserError => error
    errors << "reused pre-fix candidate receipt를 해석할 수 없습니다: #{error.message}"
  end

  def issue_source_registration(workplan, data, raw_path, inventory, inventory_digest, errors)
    sources = inventory.fetch("sources", {})
    unless nonempty_hash?(sources)
      errors << "등록할 독립 source가 없습니다"
      return nil
    end
    payload = {
      "inventory_digest" => inventory_digest,
      "sources" => sources.keys.sort.each_with_object({}) do |source_id, result|
        source = sources[source_id]
        result[source_id] = {
          "source_artifact" => source["artifact"], "source_hash" => source["hash"], "source_receipt_hash" => source["receipt_hash"],
          "source_artifact_identity" => artifact_identity(workplan, data, source["artifact"], errors, "#{source_id} source registration identity"),
          "source_identity" => source.slice("file", "node", "revision", "state", "viewport", "boundary_id")
        }
      end
    }
    return nil unless errors.empty?
    issue_gate_receipt(workplan, data, raw_path, role: "source", schema: "ui-source-registration-gate-receipt-v2", payload: payload, errors: errors)
  end

  def issue_candidate_registration(workplan, data, raw_path, source, candidate, inventory, inventory_digest, source_registration,
                                   source_identity, candidate_identity, repository_identity, errors)
    payload = {
      "inventory_digest" => inventory_digest,
      "source_operation_id" => source_registration["operation_id"],
      "source_hash" => source["hash"],
      "source_artifact_identity" => source_identity,
      "candidate_artifact" => candidate["artifact"],
      "candidate_artifact_identity" => candidate_identity,
      "candidate_hash" => candidate["hash"],
      "candidate_receipt_hash" => candidate["receipt_hash"],
      "repository_identity" => repository_identity,
      "boundary" => boundary(candidate),
      "requirement_assertion_ids" => requirement_assertion_ids(inventory)
    }
    return nil unless errors.empty?
    issue_gate_receipt(workplan, data, raw_path, role: "candidate", schema: "ui-candidate-registration-gate-receipt-v2", payload: payload, errors: errors)
  end

  def validate_source_evidence(workplan, data, source, canonical, source_id, inventory, inventory_digest, errors)
    unless source.is_a?(Hash)
      errors << "source evidence 누락"
      return
    end
    %w[file node revision state viewport boundary_id artifact hash receipt_artifact receipt_hash].each { |field| errors << "source.#{field}가 canonical inventory와 다릅니다" unless source[field] == canonical[field] }
    validate_source_receipt(workplan, data, source_id, source, inventory, inventory_digest, errors)
  end

  def validate_candidate_evidence(workplan, data, candidate, source, inventory, inventory_digest, repository_identity, errors)
    unless candidate.is_a?(Hash)
      errors << "candidate evidence 누락"
      return
    end
    %w[render_root author state viewport boundary_id artifact hash receipt_artifact receipt_hash].each { |field| errors << "candidate.#{field} 누락" unless text?(candidate[field]) }
    errors << "candidate boundary/state/viewport가 source와 다릅니다" unless same_boundary?(source, candidate)
    validate_artifact(workplan, data, candidate["artifact"], candidate["hash"], errors, "candidate render")
    receipt_path = validate_artifact(workplan, data, candidate["receipt_artifact"], candidate["receipt_hash"], errors, "candidate receipt")
    return unless receipt_path
    receipt = JSON.parse(receipt_path.read(encoding: "UTF-8"))
    errors << "candidate receipt schema 불일치" unless receipt["schema"] == "ui-candidate-render-receipt-v1"
    errors << "candidate receipt inventory_digest 불일치" unless receipt["inventory_digest"] == inventory_digest
    errors << "candidate receipt source_hash 불일치" unless receipt["source_hash"] == source["hash"]
    errors << "candidate receipt artifact_hash 불일치" unless receipt["artifact_hash"] == candidate["hash"]
    errors << "candidate receipt render_root/author 불일치" unless receipt["render_root"] == candidate["render_root"] && receipt["author"] == candidate["author"]
    errors << "candidate render receipt가 현재 대상 Git worktree와 다릅니다" unless receipt["repository_identity"] == repository_identity
    errors << "candidate receipt boundary/state/viewport 불일치" unless receipt_boundary(receipt) == boundary(candidate)
    errors << "candidate receipt REQ/assertion IDs 불일치" unless receipt["requirement_assertion_ids"] == requirement_assertion_ids(inventory)
  end

  def validate_assertions(actual, inventory, errors)
    expected = assertion_inventory(inventory)
    unless actual.is_a?(Hash)
      errors << "실행 visual assertions mapping 누락"
      return
    end
    errors << "실행 assertion IDs가 canonical inventory와 다릅니다" unless actual.keys.sort == expected.keys.sort
    expected.each do |id, item|
      assertion = actual[id]
      next unless assertion.is_a?(Hash)
      %w[requirement_id region property source_expected tolerance].each { |field| errors << "#{id}.#{field}가 canonical inventory와 다릅니다" unless assertion[field] == item[field] }
      errors << "#{id}.candidate_actual 누락" unless text?(assertion["candidate_actual"])
      errors << "#{id}.result는 passed여야 합니다" unless assertion["result"] == "passed"
    end
  end

  def validate_comparison(workplan, data, comparison, source, candidate, inventory, inventory_digest, errors)
    unless comparison.is_a?(Hash)
      errors << "comparison evidence 누락"
      return
    end
    %w[artifact hash receipt_artifact receipt_hash machine_report_artifact machine_report_hash].each { |field| errors << "comparison.#{field} 누락" unless text?(comparison[field]) }
    validate_artifact(workplan, data, comparison["artifact"], comparison["hash"], errors, "comparison artifact")
    receipt_path = validate_artifact(workplan, data, comparison["receipt_artifact"], comparison["receipt_hash"], errors, "comparison receipt")
    report_path = validate_artifact(workplan, data, comparison["machine_report_artifact"], comparison["machine_report_hash"], errors, "machine image comparison report")
    return unless receipt_path && source.is_a?(Hash) && candidate.is_a?(Hash)
    receipt = JSON.parse(receipt_path.read(encoding: "UTF-8"))
    errors << "comparison receipt schema 불일치" unless receipt["schema"] == "ui-comparison-receipt-v1"
    errors << "comparison receipt inventory_digest 불일치" unless receipt["inventory_digest"] == inventory_digest
    errors << "comparison receipt source/candidate/artifact hash 불일치" unless receipt["source_hash"] == source["hash"] && receipt["candidate_hash"] == candidate["hash"] && receipt["artifact_hash"] == comparison["hash"]
    errors << "comparison receipt boundary/state/viewport 불일치" unless receipt_boundary(receipt) == boundary(source)
    errors << "comparison receipt REQ/assertion IDs 불일치" unless receipt["requirement_assertion_ids"] == requirement_assertion_ids(inventory)
    errors << "comparison receipt result는 passed여야 합니다" unless receipt["result"] == "passed"
    validate_machine_comparison(workplan, data, report_path, source, candidate, errors) if report_path
  end

  def validate_machine_comparison(workplan, data, report_path, source, candidate, errors)
    report = JSON.parse(report_path.read(encoding: "UTF-8"))
    unless report["schema"] == UIImageCompare::SCHEMA && report["thresholds"].is_a?(Hash)
      errors << "machine image comparison report schema/thresholds 불일치"
      return
    end
    source_path = artifact_path(workplan, data, source["artifact"], errors, "machine comparison source")
    candidate_path = artifact_path(workplan, data, candidate["artifact"], errors, "machine comparison candidate")
    return unless source_path && candidate_path
    thresholds = report["thresholds"]
    recomputed = UIImageCompare.compare(
      source_path,
      candidate_path,
      pixel_tolerance: thresholds["pixel_tolerance"],
      max_changed_ratio: thresholds["max_changed_ratio"],
      max_mean_delta: thresholds["max_mean_delta"]
    )
    errors << "machine image comparison report가 실제 PNG 재계산 결과와 다릅니다" unless report == recomputed
    errors << "machine image comparison은 passed여야 합니다" unless recomputed["result"] == "passed"
  rescue UIImageCompare::Error, JSON::ParserError => error
    errors << "machine image comparison을 검증할 수 없습니다: #{error.message}"
  end

  def artifact_path(workplan, data, locator, errors, label)
    root, relative = artifact_root(workplan, data, locator, errors, label)
    return nil unless root
    path = safe_path(root, relative, errors, label, allow_missing: false)
    path&.file? ? path : nil
  end

  def validate_review(workplan, data, review, source, candidate, comparison, inventory, inventory_digest, tier, errors)
    required = %w[conformance full].include?(tier)
    return unless required
    unless review.is_a?(Hash)
      errors << "중요한 #{tier} 검증에는 독립 review evidence가 필요합니다"
      return
    end
    %w[reviewer artifact hash].each { |field| errors << "independent_review.#{field} 누락" unless text?(review[field]) }
    receipt_path = validate_artifact(workplan, data, review["artifact"], review["hash"], errors, "independent review receipt")
    return unless receipt_path && source.is_a?(Hash) && candidate.is_a?(Hash) && comparison.is_a?(Hash)
    receipt = JSON.parse(receipt_path.read(encoding: "UTF-8"))
    errors << "independent review receipt schema 불일치" unless receipt["schema"] == "ui-independent-review-receipt-v1"
    errors << "independent reviewer는 candidate author와 달라야 합니다" unless review["reviewer"] != candidate["author"] && receipt["reviewer"] == review["reviewer"]
    errors << "independent review inventory_digest 불일치" unless receipt["inventory_digest"] == inventory_digest
    errors << "independent review source/candidate/comparison hash 불일치" unless receipt["source_hash"] == source["hash"] && receipt["candidate_hash"] == candidate["hash"] && receipt["comparison_hash"] == comparison["hash"]
    errors << "independent review boundary/state/viewport 불일치" unless receipt_boundary(receipt) == boundary(source)
    errors << "independent review REQ/assertion IDs 불일치" unless receipt["requirement_assertion_ids"] == requirement_assertion_ids(inventory)
    errors << "independent review result는 passed여야 합니다" unless receipt["result"] == "passed"
  end

  def validate_snapshot(workplan, data, snapshot, approved_ids, completion:, errors:, repository_identity: nil)
    unless snapshot.is_a?(Hash)
      errors << "Snapshot 실제 result evidence 누락"
      return
    end
    if snapshot["schema"] == "snapshot-evidence-set-v2"
      validate_snapshot_evidence_set(workplan, data, snapshot, approved_ids, completion: completion,
                                     repository_identity: repository_identity, errors: errors)
      return
    end
    %w[command parser result_artifact result_hash].each { |field| errors << "snapshot.#{field} 누락" unless text?(snapshot[field]) }
    errors << "snapshot.approved_snapshot_ids가 승인 계획과 다릅니다" unless snapshot["approved_snapshot_ids"] == approved_ids
    result_path = validate_artifact(workplan, data, snapshot["result_artifact"], snapshot["result_hash"], errors, "Snapshot result")
    return unless result_path
    parsed = parse_snapshot_result(result_path, snapshot["parser"], errors)
    return unless parsed
    %w[executed_count failures exit_status].each { |field| errors << "snapshot packet #{field}가 실제 result와 다릅니다" unless snapshot[field] == parsed[field] }
    errors << "Snapshot result test IDs가 승인 snapshot IDs와 다릅니다" unless parsed["test_ids"].sort == approved_ids.sort
    errors << "Snapshot executed_count는 1 이상이어야 합니다" unless integer_positive?(parsed["executed_count"])
    if completion
      errors << "completion Snapshot failures는 0이어야 합니다" unless parsed["failures"] == 0
      errors << "completion Snapshot exit_status는 0이어야 합니다" unless parsed["exit_status"] == 0
    end
  end

  def validate_snapshot_evidence_set(workplan, data, snapshot, approved_ids, completion:, repository_identity:, errors:)
    errors << "snapshot aggregate approved_snapshot_ids가 승인 계획과 다릅니다" unless snapshot["approved_snapshot_ids"] == approved_ids
    fresh = snapshot["fresh_results"]
    reused = snapshot["reused_results"]
    unless fresh.is_a?(Array) && reused.is_a?(Array) && !(fresh.empty? && reused.empty?)
      errors << "snapshot aggregate에는 결과가 하나 이상인 fresh_results/reused_results 배열이 필요합니다"
      return
    end
    unless repository_identity.is_a?(Hash) && text?(repository_identity["worktree_root"])
      errors << "snapshot aggregate 재사용에는 현재 Git worktree identity가 필요합니다"
      return
    end

    seen = []
    fresh.each do |entry|
      seen.concat(validate_snapshot_result_entry(workplan, data, entry, completion: completion, reuse: false,
                                                 repository_identity: repository_identity, errors: errors))
    end
    reused.each do |entry|
      seen.concat(validate_snapshot_result_entry(workplan, data, entry, completion: completion, reuse: true,
                                                 repository_identity: repository_identity, errors: errors))
    end
    errors << "snapshot aggregate test IDs는 fresh/reused 사이에서 중복될 수 없습니다" unless seen.uniq.length == seen.length
    errors << "snapshot aggregate test IDs가 승인 snapshot IDs와 다릅니다" unless seen.sort == approved_ids.sort
  end

  def validate_snapshot_result_entry(workplan, data, entry, completion:, reuse:, repository_identity:, errors:)
    unless entry.is_a?(Hash)
      errors << "snapshot aggregate result는 mapping이어야 합니다"
      return []
    end
    %w[command parser result_artifact result_hash verification_evidence].each do |field|
      errors << "snapshot aggregate result.#{field} 누락" unless field == "verification_evidence" ? entry[field].is_a?(Hash) : text?(entry[field])
    end
    ids = entry["snapshot_ids"]
    unless unique_string_array?(ids)
      errors << "snapshot aggregate result.snapshot_ids는 중복 없는 비어 있지 않은 문자열 배열이어야 합니다"
      return []
    end
    result_path = validate_artifact(workplan, data, entry["result_artifact"], entry["result_hash"], errors, "Snapshot aggregate result")
    parsed = result_path && parse_snapshot_result(result_path, entry["parser"], errors)
    if parsed
      %w[executed_count failures exit_status].each { |field| errors << "snapshot aggregate #{field}가 실제 result와 다릅니다" unless entry[field] == parsed[field] }
      errors << "snapshot aggregate parsed test IDs가 선언 snapshot_ids와 다릅니다" unless parsed["test_ids"].sort == ids.sort
      if completion || reuse
        errors << "snapshot aggregate failures는 0이어야 합니다" unless parsed["failures"] == 0
        errors << "snapshot aggregate exit_status는 0이어야 합니다" unless parsed["exit_status"] == 0
      end
    end

    evidence_info = entry["verification_evidence"]
    evidence_path = evidence_info.is_a?(Hash) && validate_artifact(workplan, data, evidence_info["artifact"], evidence_info["hash"], errors,
                                                                   "Snapshot verification reuse evidence")
    if evidence_path && result_path
      begin
        evidence = VerificationPlan.reusable_payload(repository: repository_identity["worktree_root"], evidence: evidence_path,
                                                     command: entry["command"], expected_subject_ids: ids)
        record = evidence.fetch("result_artifact")
        errors << "snapshot result가 verification evidence의 실제 result artifact와 다릅니다" unless
          Pathname(record.fetch("path")).realpath == result_path.realpath && "sha256:#{record.fetch('sha256')}" == entry["result_hash"]
        if !reuse && evidence["head"] != repository_identity["head"]
          errors << "fresh Snapshot evidence는 현재 HEAD에서 실행되어야 합니다"
        end
      rescue VerificationPlan::EvidenceError, KeyError, SystemCallError => error
        errors << "Snapshot verification reuse evidence가 유효하지 않습니다: #{error.message}"
      end
    end
    ids
  end

  def validate_interaction_result(workplan, data, interaction, approved_ids, errors)
    return if approved_ids.is_a?(Array) && approved_ids.empty?
    unless interaction.is_a?(Hash)
      errors << "실제 interaction test evidence 누락"
      return
    end
    %w[result_artifact result_hash].each { |field| errors << "interaction.#{field} 누락" unless text?(interaction[field]) }
    path = validate_artifact(workplan, data, interaction["result_artifact"], interaction["result_hash"], errors, "interaction test result")
    return unless path
    result = JSON.parse(path.read(encoding: "UTF-8"))
    errors << "interaction result schema 불일치" unless result["schema"] == "ui-interaction-result-v1"
    errors << "interaction test IDs가 승인 계획과 다릅니다" unless result["test_ids"].is_a?(Array) && result["test_ids"].sort == approved_ids.sort
    errors << "interaction executed_count가 test ID 수와 다릅니다" unless result["executed_count"] == Array(result["test_ids"]).uniq.length
    errors << "interaction failures는 0이어야 합니다" unless result["failures"] == 0
    errors << "interaction exit_status는 0이어야 합니다" unless result["exit_status"] == 0
  rescue JSON::ParserError => error
    errors << "interaction test result를 해석할 수 없습니다: #{error.message}"
  end

  def parse_snapshot_result(path, parser, errors)
    case parser
    when "structured-json"
      result = JSON.parse(path.read(encoding: "UTF-8"))
      unless result["schema"] == "snapshot-result-v1" && unique_string_array?(result["test_ids"]) && result["executed_count"].is_a?(Integer) && result["failures"].is_a?(Integer) && result["exit_status"].is_a?(Integer)
        errors << "structured Snapshot result schema/field 불일치"
        return nil
      end
      unless result["executed_count"] == result["test_ids"].length && result["failures"].between?(0, result["executed_count"])
        errors << "structured Snapshot result count/failures가 unique test_ids와 다릅니다"
        return nil
      end
      { "test_ids" => result["test_ids"], "executed_count" => result["executed_count"], "failures" => result["failures"], "exit_status" => result["exit_status"] }
    when "junit-xml"
      document = REXML::Document.new(path.read(encoding: "UTF-8"))
      cases = []
      REXML::XPath.each(document, "//testcase") { |node| cases << node }
      all_ids = cases.map { |node| node.attributes["name"].to_s }
      skipped = cases.select { |node| junit_skipped?(node) }
      executed = cases - skipped
      ids = executed.map { |node| node.attributes["name"].to_s }
      failures = executed.count { |node| node.elements["failure"] || node.elements["error"] }
      property = REXML::XPath.first(document, "//property[@name='exit_status']")
      exit_status = property && Integer(property.attributes["value"], 10)
      if all_ids.any?(&:empty?) || all_ids.uniq.length != all_ids.length || exit_status.nil?
        errors << "JUnit Snapshot result의 testcase name 또는 exit_status property 누락"
        return nil
      end
      errors << "JUnit Snapshot result에 skipped/disabled test ID가 있습니다: #{skipped.map { |node| node.attributes['name'] }.join(', ')}" unless skipped.empty?
      unless ids.uniq.length == ids.length && failures.between?(0, ids.length)
        errors << "JUnit Snapshot result count/failures가 unique test IDs와 다릅니다"
        return nil
      end
      { "test_ids" => ids, "executed_count" => ids.length, "failures" => failures, "exit_status" => exit_status }
    else
      errors << "snapshot.parser는 structured-json 또는 junit-xml이어야 합니다"
      nil
    end
  rescue ArgumentError
    errors << "Snapshot result exit_status를 해석할 수 없습니다"
    nil
  end

  def junit_skipped?(node)
    status = node.attributes["status"].to_s.downcase
    node.elements["skipped"] || %w[disabled notrun skipped].include?(status) || node.attributes["disabled"].to_s.downcase == "true"
  end

  def issue_pre_golden_receipt(workplan, data, raw_path, source, candidate, comparison, golden, inventory, inventory_digest, evidence_digest,
                               source_registration, candidate_registration, repository_identity, errors)
    return nil unless source.is_a?(Hash) && candidate.is_a?(Hash) && comparison.is_a?(Hash) && golden.is_a?(Hash) && source_registration && candidate_registration
    payload = {
      "evidence_digest" => evidence_digest,
      "inventory_digest" => inventory_digest,
      "source_operation_id" => source_registration["operation_id"],
      "candidate_operation_id" => candidate_registration["operation_id"],
      "source_hash" => source["hash"],
      "candidate_hash" => candidate["hash"],
      "comparison_hash" => comparison["hash"],
      "golden_artifact_identity" => artifact_identity(workplan, data, golden["artifact"], errors, "pre-golden destination identity", allow_missing: true)&.fetch("resolved_path", nil),
      "repository_identity" => repository_identity,
      "requirement_assertion_ids" => requirement_assertion_ids(inventory)
    }
    return nil unless errors.empty?
    issue_gate_receipt(workplan, data, raw_path, role: "pre-golden", schema: "ui-pre-golden-gate-receipt-v2", payload: payload, errors: errors)
  end

  def issue_golden_provenance(workplan, data, raw_path, golden, source, candidate, inventory, inventory_digest, authorization, repository_identity, errors)
    payload = {
      "inventory_digest" => inventory_digest,
      "pre_golden_operation_id" => authorization["operation_id"],
      "source_hash" => source["hash"],
      "candidate_hash" => candidate["hash"],
      "golden_hash" => golden["hash"],
      "repository_identity" => repository_identity,
      "boundary" => boundary(source),
      "requirement_assertion_ids" => requirement_assertion_ids(inventory)
    }
    issue_gate_receipt(workplan, data, raw_path, role: "golden", schema: "source-traceable-golden-gate-receipt-v2", payload: payload, errors: errors)
  end

  def issue_gate_receipt(workplan, data, raw_path, role:, schema:, payload:, errors:)
    path = secure_issue_path(workplan, raw_path, errors)
    state_root = runtime_state_root(workplan, data, errors, create: true)
    return nil unless path && state_root
    operation_id = SecureRandom.uuid
    issued_at_ns = Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    receipt = {
      "schema" => schema,
      "issuer" => RECEIPT_ISSUER,
      "issuer_version" => RECEIPT_ISSUER_VERSION,
      "role" => role,
      "operation_id" => operation_id,
      "issued_at_ns" => issued_at_ns,
      "workplan_path" => workplan.realpath.to_s,
      "payload_digest" => digest_for(payload),
      "payload" => payload
    }
    bytes = JSON.generate(canonical(receipt)) + "\n"
    relative = path.relative_path_from(workplan.dirname.expand_path.cleanpath).to_s
    receipt_hash = "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    state = {
      "schema" => STATE_SCHEMA,
      "issuer" => RECEIPT_ISSUER,
      "issuer_version" => RECEIPT_ISSUER_VERSION,
      "role" => role,
      "operation_id" => operation_id,
      "issued_at_ns" => issued_at_ns,
      "workplan_path" => workplan.realpath.to_s,
      "receipt_hash" => receipt_hash,
      "payload_digest" => receipt["payload_digest"]
    }
    atomic_write(state_root.join("#{operation_id}.json"), JSON.generate(canonical(state)) + "\n", mode: 0o600)
    atomic_write(path, bytes, mode: 0o644)
    { "artifact" => relative, "hash" => receipt_hash, "payload_digest" => receipt["payload_digest"], "operation_id" => operation_id }
  rescue SystemCallError => error
    errors << "#{role} gate receipt를 원자적으로 발급할 수 없습니다: #{error.message}"
    nil
  end

  def runtime_state_root(workplan, data, errors, create:)
    configured = ENV["UI_VERIFICATION_GATE_STATE_ROOT"]
    base = if text?(configured)
             Pathname(configured).expand_path
           else
             codex_home = text?(ENV["CODEX_HOME"]) ? Pathname(ENV["CODEX_HOME"]).expand_path : Pathname(Dir.home).join(".codex")
             codex_home.join("state/ui-verification-gate")
           end
    if base.symlink?
      errors << "UI verification Runtime state root symlink는 허용하지 않습니다"
      return nil
    end
    if create
      FileUtils.mkdir_p(base, mode: 0o700)
      File.chmod(0o700, base)
    end
    unless base.directory?
      errors << "UI verification Runtime state root가 없습니다"
      return nil
    end
    root = base.realpath
    forbidden = [workplan.dirname.realpath]
    raw_repository = data["repository_root"]
    forbidden << Pathname(raw_repository).expand_path.realpath if text?(raw_repository) && Pathname(raw_repository).expand_path.exist?
    if forbidden.any? { |boundary| inside?(root, boundary) }
      errors << "UI verification Runtime state root는 Workplan/repository 밖이어야 합니다"
      return nil
    end
    root
  rescue SystemCallError => error
    errors << "UI verification Runtime state root를 준비할 수 없습니다: #{error.message}"
    nil
  end

  def secure_issue_path(workplan, raw_path, errors)
    unless text?(raw_path)
      errors << "--issue-receipt PATH가 비어 있습니다"
      return nil
    end
    root = workplan.dirname.expand_path.cleanpath
    candidate = Pathname(raw_path)
    path = (candidate.absolute? ? candidate.expand_path : root.join(candidate)).cleanpath
    unless inside?(path, root)
      errors << "gate receipt 발급 경로가 Workplan bundle 밖입니다"
      return nil
    end
    parent = path.dirname
    unless parent.directory? && !parent.symlink? && inside?(parent.realpath, root.realpath)
      errors << "gate receipt 발급 parent가 안전한 bundle 경로가 아닙니다"
      return nil
    end
    if path.symlink?
      errors << "gate receipt 발급 대상 symlink는 허용하지 않습니다"
      return nil
    end
    path
  rescue Errno::ENOENT
    errors << "gate receipt 발급 경로를 확인할 수 없습니다"
    nil
  end

  def atomic_write(path, bytes, mode:)
    temporary = Tempfile.new([".ui-pre-golden-", ".tmp"], path.dirname.to_s)
    temporary.binmode
    temporary.write(bytes)
    temporary.flush
    temporary.fsync
    temporary.chmod(mode)
    temporary.close
    File.rename(temporary.path, path.to_s)
  ensure
    temporary&.close!
  end

  def validate_registration(workplan, data, receipt_info, role:, source:, candidate:, inventory:, inventory_digest:, errors:, source_registration: nil,
                            repository_identity: nil)
    unless receipt_info.is_a?(Hash)
      errors << "gate-issued #{role} registration receipt가 없습니다"
      return nil
    end
    path = validate_artifact(workplan, data, receipt_info["artifact"], receipt_info["hash"], errors, "#{role} registration receipt")
    return nil unless path && source.is_a?(Hash)
    receipt = JSON.parse(path.read(encoding: "UTF-8"))
    schema = role == "source" ? "ui-source-registration-gate-receipt-v2" : "ui-candidate-registration-gate-receipt-v2"
    payload = validate_gate_receipt(workplan, data, receipt_info, receipt, role: role, schema: schema, errors: errors)
    return nil unless payload
    errors << "#{role} registration inventory_digest 불일치" unless payload["inventory_digest"] == inventory_digest
    if role == "source"
      expected_source_identity = artifact_identity(workplan, data, source["artifact"], errors, "source registration physical identity")
      registered = payload.fetch("sources", {}).values.find do |item|
        item.is_a?(Hash) && item["source_hash"] == source["hash"] && item["source_artifact_identity"] == expected_source_identity && item["source_receipt_hash"] == source["receipt_hash"]
      end
      errors << "source registration artifact/hash/receipt provenance 불일치" unless registered
    else
      errors << "candidate registration source_hash 불일치" unless payload["source_hash"] == source["hash"]
      return nil unless candidate.is_a?(Hash)
      expected_source_identity = artifact_identity(workplan, data, source["artifact"], errors, "candidate registration source identity")
      expected_candidate_identity = artifact_identity(workplan, data, candidate["artifact"], errors, "candidate registration physical identity")
      errors << "candidate registration이 선행 source operation에 연결되지 않았습니다" unless source_registration && payload["source_operation_id"] == source_registration["operation_id"]
      errors << "candidate registration source physical identity 불일치" unless payload["source_artifact_identity"] == expected_source_identity
      errors << "candidate registration artifact/hash/receipt provenance 불일치" unless payload["candidate_artifact_identity"] == expected_candidate_identity && payload["candidate_hash"] == candidate["hash"] && payload["candidate_receipt_hash"] == candidate["receipt_hash"]
      errors << "candidate registration이 현재 대상 Git worktree와 다릅니다" unless payload["repository_identity"] == repository_identity
      errors << "candidate registration은 source와 같은 physical artifact/dev+inode를 사용할 수 없습니다" if same_physical_artifact?(expected_source_identity, expected_candidate_identity)
      validate_candidate_created_after_source(workplan, data, candidate, source_registration, errors) if source_registration
      errors << "candidate registration boundary 불일치" unless payload["boundary"] == boundary(candidate)
      errors << "candidate registration REQ/assertion IDs 불일치" unless payload["requirement_assertion_ids"] == requirement_assertion_ids(inventory)
    end
    receipt.merge("payload" => payload)
  end

  def validate_candidate_created_after_source(workplan, data, candidate, source_registration, errors)
    issued_at_ns = source_registration["issued_at_ns"]
    unless issued_at_ns.is_a?(Integer) && issued_at_ns.positive?
      errors << "source registration issued_at_ns가 없습니다"
      return
    end
    {
      "candidate artifact" => candidate["artifact"],
      "candidate render receipt" => candidate["receipt_artifact"]
    }.each do |label, locator|
      mtime_ns = artifact_mtime_ns(workplan, data, locator, errors, label)
      errors << "#{label}는 source registration 발급 뒤 생성되어야 합니다" if mtime_ns && mtime_ns <= issued_at_ns
    end
  end

  def artifact_mtime_ns(workplan, data, locator, errors, label)
    root, relative = artifact_root(workplan, data, locator, errors, label)
    return nil unless root
    path = safe_path(root, relative, errors, label, allow_missing: false)
    return nil unless path&.file?
    stat = path.stat
    stat.mtime.to_i * 1_000_000_000 + stat.mtime.nsec
  rescue SystemCallError => error
    errors << "#{label} mtime을 확인할 수 없습니다: #{error.message}"
    nil
  end

  def validate_pre_golden_receipt(workplan, data, receipt_info, source, candidate, comparison, golden, inventory, inventory_digest, evidence_digest,
                                  source_registration, candidate_registration, repository_identity, errors)
    unless receipt_info.is_a?(Hash)
      errors << "pre-golden 성공 receipt가 없습니다; completion 직행은 허용하지 않습니다"
      return nil
    end
    path = validate_artifact(workplan, data, receipt_info["artifact"], receipt_info["hash"], errors, "pre-golden receipt")
    return nil unless path && source.is_a?(Hash) && candidate.is_a?(Hash) && comparison.is_a?(Hash) && golden.is_a?(Hash)
    receipt = JSON.parse(path.read(encoding: "UTF-8"))
    payload = validate_gate_receipt(workplan, data, receipt_info, receipt, role: "pre-golden", schema: "ui-pre-golden-gate-receipt-v2", errors: errors)
    return nil unless payload
    errors << "pre-golden receipt evidence_digest 불일치" unless payload["evidence_digest"] == evidence_digest
    errors << "pre-golden receipt inventory_digest 불일치" unless payload["inventory_digest"] == inventory_digest
    errors << "pre-golden receipt source operation 불일치" unless source_registration && payload["source_operation_id"] == source_registration["operation_id"]
    errors << "pre-golden receipt candidate operation 불일치" unless candidate_registration && payload["candidate_operation_id"] == candidate_registration["operation_id"]
    errors << "pre-golden receipt source/candidate/comparison hash 불일치" unless payload["source_hash"] == source["hash"] && payload["candidate_hash"] == candidate["hash"] && payload["comparison_hash"] == comparison["hash"]
    current_golden_identity = artifact_identity(workplan, data, golden["artifact"], errors, "completion Golden destination identity", allow_missing: true)&.fetch("resolved_path", nil)
    errors << "pre-golden authorization의 Golden destination identity가 completion과 다릅니다" unless payload["golden_artifact_identity"] == current_golden_identity
    errors << "pre-golden receipt REQ/assertion IDs 불일치" unless payload["requirement_assertion_ids"] == requirement_assertion_ids(inventory)
    errors << "pre-golden receipt가 현재 대상 Git worktree와 다릅니다" unless payload["repository_identity"] == repository_identity
    receipt.merge("payload" => payload)
  end

  def validate_gate_receipt(workplan, data, receipt_info, receipt, role:, schema:, errors:, bind_current_workplan: true)
    errors << "#{role} gate receipt schema 불일치" unless receipt["schema"] == schema
    errors << "#{role} gate receipt issuer/version 불일치" unless receipt["issuer"] == RECEIPT_ISSUER && receipt["issuer_version"] == RECEIPT_ISSUER_VERSION
    errors << "#{role} gate receipt role 불일치" unless receipt["role"] == role
    errors << "#{role} gate receipt issued_at_ns 불일치" unless receipt["issued_at_ns"].is_a?(Integer) && receipt["issued_at_ns"].positive?
    operation_id = receipt["operation_id"]
    unless operation_id.is_a?(String) && operation_id.match?(OPERATION_ID)
      errors << "#{role} gate receipt operation_id 형식 불일치"
      return nil
    end
    payload = receipt["payload"]
    unless payload.is_a?(Hash)
      errors << "#{role} gate receipt payload 누락"
      return nil
    end
    errors << "#{role} gate receipt payload_digest 불일치" unless receipt["payload_digest"] == digest_for(payload)
    errors << "#{role} gate receipt가 현재 Workplan operation과 다릅니다" if bind_current_workplan && receipt["workplan_path"] != workplan.realpath.to_s
    root = runtime_state_root(workplan, data, errors, create: false)
    return nil unless root
    path = root.join("#{operation_id}.json")
    unless path.file? && !path.symlink? && inside?(path.realpath, root)
      errors << "#{role} gate receipt에 등록된 Runtime state record가 없습니다"
      return nil
    end
    state = JSON.parse(path.read(encoding: "UTF-8"))
    expected = {
      "schema" => STATE_SCHEMA,
      "issuer" => RECEIPT_ISSUER,
      "issuer_version" => RECEIPT_ISSUER_VERSION,
      "role" => role,
      "operation_id" => operation_id,
      "issued_at_ns" => receipt["issued_at_ns"],
      "workplan_path" => receipt["workplan_path"],
      "receipt_hash" => receipt_info["hash"],
      "payload_digest" => receipt["payload_digest"]
    }
    errors << "#{role} Runtime state record가 receipt/payload와 다릅니다" unless state == expected
    payload
  rescue SystemCallError, JSON::ParserError
    errors << "#{role} Runtime state record를 검증할 수 없습니다"
    nil
  end

  def validate_golden(workplan, data, golden, candidate, pre_receipt, phase, errors)
    unless golden.is_a?(Hash)
      errors << "candidate→golden provenance 누락"
      return
    end
    expected_status = phase == "pre-golden" ? "pending" : "promoted"
    errors << "golden status는 #{expected_status}여야 합니다" unless golden["status"] == expected_status
    required_fields = %w[artifact hash candidate_hash]
    required_fields << "pre_golden_receipt_hash" if phase == "completion"
    required_fields.each { |field| errors << "golden.#{field} 누락" unless text?(golden[field]) }
    errors << "golden hash/candidate_hash가 검증 candidate와 다릅니다" if candidate.is_a?(Hash) && !(golden["hash"] == candidate["hash"] && golden["candidate_hash"] == candidate["hash"])
    errors << "golden pre_golden_receipt_hash 불일치" if pre_receipt.is_a?(Hash) && golden["pre_golden_receipt_hash"] != pre_receipt["hash"]
    path = validate_artifact(workplan, data, golden["artifact"], golden["hash"], errors, "golden", required: phase == "completion")
    errors << "pre-golden authorization 전에 Golden artifact를 쓰거나 복사할 수 없습니다" if phase == "pre-golden" && path&.file?
  end

  def validate_golden_provenance(workplan, data, golden, source, candidate, inventory, inventory_digest, authorization, repository_identity, errors)
    info = golden["provenance_receipt"]
    path = validate_artifact(workplan, data, info["artifact"], info["hash"], errors, "Golden provenance receipt")
    return nil unless path && source.is_a?(Hash) && candidate.is_a?(Hash)
    receipt = JSON.parse(path.read(encoding: "UTF-8"))
    payload = validate_gate_receipt(workplan, data, info, receipt, role: "golden", schema: "source-traceable-golden-gate-receipt-v2", errors: errors)
    return nil unless payload
    errors << "Golden provenance inventory_digest 불일치" unless payload["inventory_digest"] == inventory_digest
    errors << "Golden provenance authorization operation 불일치" unless authorization && payload["pre_golden_operation_id"] == authorization["operation_id"]
    errors << "Golden provenance source/candidate/Golden hash 불일치" unless payload["source_hash"] == source["hash"] && payload["candidate_hash"] == candidate["hash"] && payload["golden_hash"] == golden["hash"]
    errors << "Golden provenance는 승인 candidate와 승격 Golden을 결속해야 합니다" unless golden["hash"] == candidate["hash"]
    errors << "Golden provenance boundary 불일치" unless payload["boundary"] == boundary(source)
    errors << "Golden provenance REQ/assertion IDs 불일치" unless payload["requirement_assertion_ids"] == requirement_assertion_ids(inventory)
    errors << "Golden provenance가 현재 대상 Git worktree와 다릅니다" unless payload["repository_identity"] == repository_identity
    receipt.merge("payload" => payload)
  end

  def required_repository_identity(repository, tier, phase, errors)
    return nil unless (tier == "regression" && phase == "completion") || (%w[conformance full].include?(tier) && %w[candidate pre-golden completion].include?(phase))
    unless text?(repository)
      errors << "#{tier} #{phase}에는 candidate를 만든 정확한 Git worktree를 --repository로 지정해야 합니다"
      return nil
    end
    root = Pathname(repository).expand_path
    unless root.directory?
      errors << "UI 검증 repository가 디렉터리가 아닙니다: #{root}"
      return nil
    end
    top, top_error, top_status = Open3.capture3("git", "-C", root.to_s, "rev-parse", "--show-toplevel")
    git_dir, git_error, git_status = Open3.capture3("git", "-C", root.to_s, "rev-parse", "--absolute-git-dir")
    head, head_error, head_status = Open3.capture3("git", "-C", root.to_s, "rev-parse", "HEAD")
    unless top_status.success? && git_status.success? && head_status.success?
      errors << "UI 검증 repository의 Git identity를 확인할 수 없습니다: #{[top_error, git_error, head_error].join(' ').strip}"
      return nil
    end
    top_path = Pathname(top.strip).realpath
    supplied = root.realpath
    unless supplied == top_path
      errors << "--repository는 하위 폴더가 아니라 정확한 Git worktree root여야 합니다: #{top_path}"
      return nil
    end
    {
      "worktree_root" => top_path.to_s,
      "git_dir" => Pathname(git_dir.strip).realpath.to_s,
      "head" => head.strip
    }
  rescue SystemCallError => error
    errors << "UI 검증 repository identity를 확인할 수 없습니다: #{error.message}"
    nil
  end

  def evidence_packet(workplan, data)
    read_packet(workplan, data, ["verification"], "## UI 적합성 증거 (`#{SCHEMA}`)", "ui_conformance_evidence")
  end

  def read_packet(workplan, data, roles, heading, root_key)
    errors = []
    paths = roles.map { |role| safe_detail(workplan, data, role, errors) }.compact
    raise ValidationError, errors.join("\n") unless errors.empty?
    paths.each do |path|
      next unless path.file?
      section = WorkplanLayout.markdown_section(path.read(encoding: "UTF-8"), heading)
      next if section.empty?
      fence = section.match(/```ya?ml\s*\n(.*?)\n```/m)
      raise ValidationError, "#{heading} YAML fence 누락" unless fence
      parsed = YAML.safe_load(fence[1], permitted_classes: [], aliases: false) || {}
      packet = parsed[root_key]
      raise ValidationError, "#{heading}의 #{root_key} mapping 누락" unless packet.is_a?(Hash)
      return packet
    end
    raise ValidationError, "#{heading} 섹션 누락"
  end

  def safe_detail(workplan, data, role, errors)
    declared = data["detail_documents"]
    relative = declared.is_a?(Hash) ? declared[role] : nil
    relative ||= "Details/#{role.tr('_', '-')}.md"
    safe_path(workplan.dirname, relative, errors, "Workplan detail #{role}", allow_missing: true)
  end

  def validate_artifact(workplan, data, locator, expected_hash, errors, label, required: true)
    unless text?(locator) && expected_hash.is_a?(String) && expected_hash.match?(SHA256)
      errors << "#{label} artifact/hash 누락 또는 형식 불일치"
      return nil
    end
    root, relative = artifact_root(workplan, data, locator, errors, label)
    return nil unless root
    path = safe_path(root, relative, errors, label, allow_missing: !required)
    return nil unless path
    unless path.file?
      errors << "#{label} artifact가 없습니다: #{locator}" if required
      return nil
    end
    actual = "sha256:#{Digest::SHA256.file(path).hexdigest}"
    errors << "#{label} artifact hash가 실제 파일과 다릅니다" unless actual == expected_hash
    path
  end

  def artifact_identity(workplan, data, locator, errors, label, allow_missing: false)
    unless text?(locator)
      errors << "#{label} locator 누락"
      return nil
    end
    root, relative = artifact_root(workplan, data, locator, errors, label)
    return nil unless root
    path = safe_path(root, relative, errors, label, allow_missing: allow_missing)
    return nil unless path
    unless path.exist? || allow_missing
      errors << "#{label} artifact가 없습니다: #{locator}"
      return nil
    end

    root_real = Pathname(root).expand_path.realpath
    root_clean = Pathname(root).expand_path.cleanpath
    ancestor = path.parent
    loop do
      break if ancestor == root_clean
      if ancestor.symlink?
        errors << "#{label} symlink ancestor는 허용하지 않습니다"
        return nil
      end
      break if ancestor.root?
      ancestor = ancestor.parent
    end

    cursor = path
    suffix = []
    until cursor.exist?
      suffix.unshift(cursor.basename.to_s)
      cursor = cursor.dirname
    end
    resolved_ancestor = cursor.realpath
    unless inside?(resolved_ancestor, root_real)
      errors << "#{label} nearest existing ancestor가 허용 root 밖입니다"
      return nil
    end
    resolved_path = suffix.reduce(resolved_ancestor) { |resolved, segment| resolved.join(segment) }.cleanpath
    identity = { "resolved_path" => resolved_path.to_s }
    if path.exist?
      stat = path.stat
      identity["device"] = stat.dev
      identity["inode"] = stat.ino
    end
    identity
  rescue SystemCallError => error
    errors << "#{label} physical identity를 확인할 수 없습니다: #{error.message}"
    nil
  end

  def same_physical_artifact?(left, right)
    return false unless left.is_a?(Hash) && right.is_a?(Hash)
    return true if left["resolved_path"] == right["resolved_path"]
    left["device"].is_a?(Integer) && left["inode"].is_a?(Integer) &&
      left["device"] == right["device"] && left["inode"] == right["inode"]
  end

  def artifact_root(workplan, data, locator, errors, label)
    if locator.start_with?("repo:")
      raw_root = data["repository_root"]
      unless text?(raw_root) && Pathname(raw_root).absolute?
        errors << "#{label} repo artifact에는 절대 repository_root가 필요합니다"
        return [nil, nil]
      end
      [Pathname(raw_root).expand_path, locator.delete_prefix("repo:")]
    else
      [workplan.dirname, locator]
    end
  end

  def safe_path(root, relative, errors, label, allow_missing:)
    unless text?(relative) && !Pathname(relative).absolute? && !Pathname(relative).each_filename.include?("..")
      errors << "#{label} 경로 traversal/absolute 불일치"
      return nil
    end
    root = Pathname(root).expand_path.cleanpath
    path = root.join(relative).cleanpath
    unless inside?(path, root)
      errors << "#{label} 경로가 허용 root 밖입니다"
      return nil
    end
    if path.symlink?
      errors << "#{label} symlink는 허용하지 않습니다"
      return nil
    end
    if path.exist? && (!root.exist? || !inside?(path.realpath, root.realpath))
      errors << "#{label} symlink realpath가 허용 root 밖입니다"
      return nil
    end
    if allow_missing && !path.exist?
      ancestor = path.parent
      until ancestor.exist? || ancestor == root
        if ancestor.symlink?
          errors << "#{label} symlink ancestor는 허용하지 않습니다"
          return nil
        end
        ancestor = ancestor.parent
      end
      if ancestor.symlink?
        errors << "#{label} symlink ancestor는 허용하지 않습니다"
        return nil
      end
      unless ancestor.exist? && root.exist? && inside?(ancestor.realpath, root.realpath)
        errors << "#{label} nearest existing ancestor가 허용 root 밖입니다"
        return nil
      end
    end
    errors << "#{label} 경로가 없습니다" if !allow_missing && !path.exist?
    path
  rescue Errno::ENOENT
    errors << "#{label} 경로를 확인할 수 없습니다"
    nil
  end

  def requirement_assertion_ids(inventory, source_id: nil)
    inventory.fetch("requirements", {}).keys.sort.each_with_object({}) do |requirement_id, result|
      item = inventory["requirements"][requirement_id]
      next if source_id && item["source_id"] != source_id
      result[requirement_id] = item.fetch("assertions", {}).keys.sort
    end
  end

  def interaction_test_ids(inventory)
    inventory.fetch("interactions", {}).values.select { |item| item.is_a?(Hash) }.map { |item| item["test_id"] }.select { |id| text?(id) }.uniq.sort
  end

  def assertion_inventory(inventory)
    inventory.fetch("requirements", {}).each_with_object({}) do |(requirement_id, requirement), result|
      requirement.fetch("assertions", {}).each { |assertion_id, assertion| result[assertion_id] = assertion.merge("requirement_id" => requirement_id) }
    end
  end

  def conformance_digest(evidence)
    digest_for(evidence.reject { |key, _value| %w[golden pre_golden_receipt snapshot].include?(key) })
  end

  def inventory_projection(inventory)
    copy = Marshal.load(Marshal.dump(inventory))
    copy.fetch("sources", {}).each_value do |source|
      source.delete("receipt_artifact")
      source.delete("receipt_hash")
    end
    copy
  end

  def digest_for(value)
    "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
  end

  def canonical(value)
    case value
    when Hash
      value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
        result[key] = canonical(value.key?(key) ? value[key] : value[key.to_sym])
      end
    when Array
      value.map { |item| canonical(item) }
    else
      value
    end
  end

  def boundary(item)
    { "boundary_id" => item["boundary_id"], "state" => item["state"], "viewport" => item["viewport"] }
  end

  def receipt_boundary(receipt)
    { "boundary_id" => receipt["boundary_id"], "state" => receipt["state"], "viewport" => receipt["viewport"] }
  end

  def same_boundary?(left, right)
    boundary(left) == boundary(right) && boundary(left).values.all? { |value| text?(value) }
  end

  def ui_workplan?(workplan, data)
    data["requires_ui_verification"] == true || !data["visual_change_intent"].to_s.empty? || source_requires_ui_context?(workplan, data)
  end

  def source_requires_ui_context?(workplan, data)
    documents = WorkplanLayout.detail_documents(workplan, data)
    %w[requirements description].any? do |role|
      path = documents[role]
      next false unless path&.file?

      section = WorkplanLayout.markdown_section(path.read(encoding: "UTF-8"), "## 기능 요구사항 매핑 (`feature-plan-completeness-v1`)")
      fenced = section.match(/```ya?ml\s*\n(.*?)\n```/m)
      next false unless fenced

      packet = YAML.safe_load(fenced[1], permitted_classes: [], aliases: false) || {}
      inventory = packet.dig("feature_requirements", "source_inventory")
      inventory.is_a?(Hash) && inventory.values.any? do |source|
        source.is_a?(Hash) && source["requires_ui_context"] == true && source["requirement_ids"].is_a?(Array) && !source["requirement_ids"].empty?
      end
    rescue Psych::SyntaxError
      false
    end
  end

  def inside?(path, root)
    relative = path.cleanpath.relative_path_from(root.cleanpath).to_s
    relative != ".." && !relative.start_with?("../")
  rescue ArgumentError
    false
  end

  def string_array(value)
    value.is_a?(Array) ? value.select { |item| text?(item) }.sort : []
  end

  def unique_string_array?(value)
    value.is_a?(Array) && !value.empty? && value.all? { |item| text?(item) } && value.uniq.length == value.length
  end

  def integer_positive?(value)
    value.is_a?(Integer) && value.positive?
  end

  def boolean?(value)
    value == true || value == false
  end

  def text?(value)
    value.is_a?(String) && !value.strip.empty?
  end

  def nonempty_hash?(value)
    value.is_a?(Hash) && !value.empty?
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  unless %w[validate repository-identity].include?(command)
    abort "usage: ui-verification-gate.rb validate --phase plan|source|candidate|pre-golden|completion [--repository GIT_ROOT] [--issue-receipt PATH] <Workplan> | repository-identity --repository GIT_ROOT"
  end
  options = {}
  OptionParser.new do |parser|
    parser.on("--phase PHASE") { |value| options[:phase] = value }
    parser.on("--repository GIT_ROOT") { |value| options[:repository] = value }
    parser.on("--issue-receipt PATH") { |value| options[:issue_receipt] = value }
  end.parse!(ARGV)
  if command == "repository-identity"
    errors = []
    identity = UIVerificationGate.required_repository_identity(options[:repository], "conformance", "candidate", errors)
    abort errors.join("\n") unless errors.empty?
    puts JSON.generate(identity)
    exit 0
  end
  abort "Workplan 경로가 필요합니다" unless ARGV.length == 1
  abort "--phase가 필요합니다" unless options[:phase]
  begin
    result = UIVerificationGate.validate(ARGV.first, phase: options[:phase], issue_receipt: options[:issue_receipt], repository: options[:repository])
    puts(result.is_a?(Hash) ? JSON.generate(result) : result)
  rescue UIVerificationGate::ValidationError => error
    warn error.message
    exit 1
  end
end
