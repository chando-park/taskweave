#!/usr/bin/env ruby

require "json"
require "pathname"
require_relative "artifact-placement-gate"
require_relative "ui-verification-gate"
require_relative "workplan-layout"

module MicroUIFeedbackGate
  SCHEMA = "micro-ui-feedback-delta-v2"
  CAPS = { "requirements" => 8, "files" => 8, "snapshots" => 8, "regions" => 8 }.freeze
  KINDS = %w[spacing color icon text-decoration].freeze
  ACTIONS = %w[
    read_workplan_summary
    read_affected_requirement
    read_affected_code
    reuse_source_registration
    render_affected_snapshots
    compare_affected_snapshots
    update_change_record
    update_verification_record
    transition_implementing
    transition_verifying
    transition_awaiting_completion
  ].freeze
  FALSE_FIELDS = %w[
    state_changed
    navigation_changed
    public_api_changed
    design_system_ownership_changed
    multi_repo_boundary_changed
    canonical_source_changed
    render_boundary_changed
    cross_region_relationship_changed
    overlay_or_background_changed
    safe_area_changed
    new_source_provided
    completion_requested
    auto_complete
  ].freeze
  KEYS = (%w[
    schema
    workplan_id
    workplan_path
    feedback_origin
    source_id
    source_registration
    affected_requirement_ids
    affected_files
    affected_snapshot_ids
    requested_snapshot_ids
    affected_region_ids
    affected_render_root
    change_kinds
    planned_actions
  ] + FALSE_FIELDS).freeze
  SHA256 = /\Asha256:[0-9a-f]{64}\z/
  SIMPLE_ID = /\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/

  module_function

  def classify(manifest)
    return result(["manifest_must_be_object"]) unless manifest.is_a?(Hash)

    errors = []
    provenance_errors = []
    unknown = manifest.keys - KEYS
    errors << "unknown_keys:#{unknown.sort.join(',')}" unless unknown.empty?
    errors << "schema_must_be_#{SCHEMA}" unless manifest["schema"] == SCHEMA
    errors << "workplan_id_must_be_nonempty_string" unless text?(manifest["workplan_id"])
    errors << "feedback_origin_must_be_implementation_or_final_review" unless %w[implementation_review final_review].include?(manifest["feedback_origin"])
    errors << "source_id_must_be_nonempty_string" unless text?(manifest["source_id"])
    FALSE_FIELDS.each do |field|
      errors << "#{field}_must_be_literal_false" unless manifest[field] == false
    end

    affected_requirements = ids(manifest, "affected_requirement_ids", errors, pattern: /\AREQ-[A-Za-z0-9_-]+\z/)
    affected_files = files(manifest, "affected_files", errors)
    affected_snapshots = ids(manifest, "affected_snapshot_ids", errors, pattern: SIMPLE_ID)
    requested_snapshots = ids(manifest, "requested_snapshot_ids", errors, pattern: SIMPLE_ID)
    affected_regions = ids(manifest, "affected_region_ids", errors, pattern: SIMPLE_ID)
    errors << "affected_render_root_must_be_nonempty_string" unless text?(manifest["affected_render_root"])
    errors << "requested_snapshot_ids_must_exactly_equal_affected_snapshot_ids" unless requested_snapshots == affected_snapshots

    {
      "requirements" => affected_requirements,
      "files" => affected_files,
      "snapshots" => affected_snapshots,
      "regions" => affected_regions
    }.each do |name, values|
      errors << "#{name}_must_be_nonempty" if values.empty?
      errors << "#{name}_exceeds_cap" if values.length > CAPS.fetch(name)
    end

    kinds = ids(manifest, "change_kinds", errors)
    errors << "change_kinds_must_be_visual_only" unless !kinds.empty? && (kinds - KINDS).empty?
    actions = ids(manifest, "planned_actions", errors)
    errors << "planned_actions_must_exactly_match_narrow_lane" unless actions == ACTIONS

    workplan, = validate_workplan(manifest, errors)
    receipt_info = validate_source_registration_shape(manifest["source_registration"], errors, provenance_errors)
    source_context = validate_source_context(workplan, manifest["source_id"], receipt_info, errors, provenance_errors) if workplan && receipt_info
    approved_files = validate_approved_files(workplan, errors) if workplan

    if source_context
      subset(errors, "requirements", affected_requirements, source_context["canonical_requirement_ids"])
      subset(errors, "snapshots", affected_snapshots, source_context["approved_snapshot_ids"])
      subset(errors, "regions", affected_regions, source_context["visible_region_ids"])
      unless manifest["affected_render_root"] == source_context.dig("source_identity", "boundary_id")
        errors << "affected_render_root_must_match_canonical_source_boundary"
      end
    end
    subset(errors, "files", affected_files, approved_files) if approved_files

    coverage_error = errors.any? do |error|
      error.match?(/(?:canonical_source_changed|render_boundary_changed|cross_region_relationship_changed|overlay_or_background_changed|safe_area_changed|new_source_provided)_must_be_literal_false/) ||
        error.match?(/affected_(?:region|render_root)/) || error.start_with?("regions_")
    end
    result(
      errors,
      snapshots: affected_snapshots,
      source_context: source_context,
      required_next_gate: coverage_error ? "ui-verification-gate validate --phase plan" :
        (!errors.empty? && errors.all? { |error| provenance_errors.include?(error) } ? "ui-verification-gate validate --phase source" : nil)
    )
  rescue StandardError => error
    result(["unexpected_validation_failure:#{error.class}:#{error.message.lines.first.to_s.strip}"])
  end

  def validate_workplan(manifest, errors)
    raw = manifest["workplan_path"]
    unless raw.is_a?(String) && !raw.empty? && Pathname(raw).absolute?
      errors << "workplan_path_must_be_absolute_existing_regular_file"
      return [nil, nil]
    end
    path = Pathname(raw)
    unless path.cleanpath.to_s == raw && path.file? && !path.symlink?
      errors << "workplan_path_must_be_absolute_existing_regular_file"
      return [nil, nil]
    end
    _frontmatter, data = WorkplanLayout.frontmatter(path.read(encoding: "UTF-8"))
    unless data.is_a?(Hash)
      errors << "workplan_frontmatter_must_be_mapping"
      return [nil, nil]
    end
    WorkplanLayout.state_group(data["status"])
    errors << "workplan_id_mismatch_actual" unless data["id"] == manifest["workplan_id"]
    allowed_statuses = %w[implementing verifying verification_blocked awaiting_completion]
    errors << "workplan_status_must_be_active_feedback_state_actual" unless allowed_statuses.include?(data["status"])
    errors << "workplan_authority_must_be_approved_actual" unless data["authority_status"] == "approved"
    [path, data]
  rescue Psych::SyntaxError, ArgumentError, RuntimeError => error
    errors << "workplan_structure_invalid:#{error.message.lines.first.to_s.strip}"
    [nil, nil]
  end

  def validate_source_registration_shape(value, errors, provenance_errors)
    valid = value.is_a?(Hash) && value.keys.sort == %w[artifact hash] &&
      safe_relative_path?(value["artifact"]) && value["hash"].is_a?(String) && value["hash"].match?(SHA256)
    return value if valid

    error = "source_registration_must_be_exact_gate_receipt_reference"
    errors << error
    provenance_errors << error
    nil
  end

  def validate_source_context(workplan, source_id, receipt_info, errors, provenance_errors)
    return unless text?(source_id)
    UIVerificationGate.validate_source_registration_for_reuse(workplan, receipt_info, source_id: source_id)
  rescue UIVerificationGate::ValidationError => error
    reason = "source_context_invalid:#{error.message.lines.first.to_s.strip}"
    errors << reason
    provenance_errors << reason if provenance_failure?(error.message)
    nil
  end

  def validate_approved_files(workplan, errors)
    ArtifactPlacementGate.approved_product_code_and_test_files(workplan)
  rescue ArtifactPlacementGate::ValidationError => error
    errors << "approved_file_scope_invalid:#{error.message.lines.first.to_s.strip}"
    nil
  end

  def subset(errors, name, affected, approved)
    errors << "#{name}_not_approved_by_workplan" unless approved.is_a?(Array) && (affected - approved).empty?
  end

  def ids(manifest, key, errors, pattern: nil)
    value = manifest[key]
    unless value.is_a?(Array)
      errors << "#{key}_must_be_array"
      return []
    end
    unless value.all? { |item| text?(item) && (!pattern || item.match?(pattern)) }
      errors << "#{key}_contains_invalid_value"
    end
    errors << "#{key}_contains_duplicate" unless value.uniq.length == value.length
    value.select { |item| item.is_a?(String) }
  end

  def files(manifest, key, errors)
    value = ids(manifest, key, errors)
    errors << "#{key}_contains_unsafe_path" unless value.all? { |path| safe_relative_path?(path) }
    value
  end

  def safe_relative_path?(value)
    return false unless text?(value)
    return false if value.include?("\\") || value.include?("\0") || value.match?(/[\r\n]/)
    return false if value.start_with?("/") || value.match?(%r{\A[A-Za-z]:/})
    path = Pathname(value)
    !path.absolute? && path.each_filename.none? { |part| %w[. ..].include?(part) } && path.cleanpath.to_s == value
  end

  def provenance_failure?(message)
    message.lines.map(&:strip).reject(&:empty?).all? do |line|
      line.match?(/source (?:registration|gate receipt|Runtime state|export|receipt)/i) ||
        line.match?(/source 등록|source_registration|source artifact\/hash\/receipt provenance/i)
    end
  end

  def text?(value)
    value.is_a?(String) && !value.strip.empty?
  end

  def result(errors, snapshots: [], source_context: nil, required_next_gate: nil)
    eligible = errors.empty?
    output = {
      "schema" => SCHEMA,
      "classification" => eligible ? "micro" : "escalate",
      "eligible" => eligible,
      "reasons" => errors,
      "snapshot_ids_to_run" => eligible ? snapshots : [],
      "completion_allowed" => false,
      "required_next_gate" => eligible ? nil : required_next_gate
    }
    if eligible
      output["source_operation_id"] = source_context["operation_id"]
      output["canonical_source_identity"] = source_context["source_identity"]
      output["snapshot_evidence_schema"] = "snapshot-evidence-set-v2"
      output["fresh_snapshot_ids"] = snapshots
      output["reusable_snapshot_ids"] = source_context["approved_snapshot_ids"] - snapshots
    end
    JSON.generate(output)
  end
end

abort("Usage: micro-ui-feedback-gate.rb <manifest.json>") unless ARGV.length == 1

begin
  puts MicroUIFeedbackGate.classify(JSON.parse(File.read(ARGV.fetch(0), encoding: "UTF-8")))
rescue JSON::ParserError => error
  warn "invalid manifest JSON: #{error.message}"
  exit 2
rescue Errno::ENOENT => error
  warn error.message
  exit 2
end
