#!/usr/bin/env ruby

require "json"
require "optparse"
require "pathname"
require "digest"
require "yaml"

options = { facets: [], evidence: [], impacts: [], excluded_impacts: {} }
OptionParser.new do |parser|
  parser.on("--profile NAME") { |value| options[:profile] = value }
  parser.on("--facet NAME") { |value| options[:facets] << value }
  parser.on("--manifest PATH") { |value| options[:manifest] = value }
  parser.on("--contract NAME") { |value| options[:contract] = value }
  parser.on("--evidence PATH") { |value| options[:evidence] << value }
  parser.on("--repository PATH") { |value| options[:repository] = value }
  parser.on("--impact NAME") { |value| options[:impacts] << value }
  parser.on("--exclude-impact NAME=REASON") do |value|
    name, reason = value.split("=", 2)
    raise OptionParser::InvalidArgument, "--exclude-impact는 NAME=REASON 형식이어야 합니다" if name.to_s.empty? || reason.to_s.strip.empty?
    options[:excluded_impacts][name] = reason.strip
  end
end.parse!

EVIDENCE_SCHEMA = "context-evidence-v2"
APPLICABILITIES = %w[required optional excluded].freeze
DISCOVERY_STATES = %w[confirmed not_investigated access_blocked not_found].freeze
IMPACT_EVIDENCE = {
  "logic" => ["direct_behavior_test"],
  "visual" => ["affected_snapshot_or_render", "source_conformance_when_required"],
  "interaction" => ["interaction_or_ui_automation_test"],
  "async" => ["lifecycle_cancellation_resubscription_test"],
  "external" => ["contract_and_compatibility_test"]
}.freeze

def ordered_union(*values)
  values.flatten.compact.each_with_object([]) { |value, result| result << value unless result.include?(value) }
end

def text?(value)
  value.is_a?(String) && !value.strip.empty?
end

def proof_artifact(proof, evidence_path, repository, context)
  artifact = proof["artifact"]
  raise "#{context} remote confirmed는 local proof.artifact가 필요합니다" unless artifact.is_a?(Hash) && text?(artifact["path"])
  base = repository ? Pathname(repository).expand_path : evidence_path.dirname
  artifact_path = Pathname(artifact["path"])
  artifact_path = base.join(artifact_path) unless artifact_path.absolute?
  raise "#{context} remote proof artifact가 일반 파일이 아닙니다: #{artifact_path}" unless artifact_path.file?
  actual_hash = "sha256:#{Digest::SHA256.file(artifact_path).hexdigest}"
  raise "#{context} remote proof artifact sha256가 실제 파일과 다릅니다" unless artifact["sha256"] == actual_hash
  artifact.merge("resolved_path" => artifact_path.realpath.to_s, "evidence_artifact_hash_match" => true)
end

def load_context_evidence(paths, required, repository)
  documents = paths.map do |path|
    evidence_path = Pathname(path).expand_path
    raise "Context evidence가 없습니다: #{evidence_path}" unless evidence_path.file?
    data = YAML.safe_load(evidence_path.read(encoding: "UTF-8"), permitted_classes: [], aliases: false) || {}
    canonical = data["schema"] == EVIDENCE_SCHEMA
    company = data["evidence_schema"] == EVIDENCE_SCHEMA && data["schema_version"] == 2
    raise "Context evidence schema는 #{EVIDENCE_SCHEMA}여야 합니다" unless canonical || company
    inputs = data["required_inputs"]
    raise "required_inputs는 비어 있지 않은 문자열 배열이어야 합니다" unless inputs.is_a?(Array) && !inputs.empty? && inputs.all? { |item| text?(item) }
    items = canonical ? data["items"] : data["evidence"]
    raise "Context evidence items는 배열이어야 합니다" unless items.is_a?(Array)
    { path: evidence_path, required_inputs: inputs, items: items }
  end
  required_inputs = documents.flat_map { |document| document[:required_inputs] }.uniq
  missing_declared = required - required_inputs
  unexpected_declared = required_inputs - required
  raise "required_inputs가 선택 Context와 다릅니다 (missing=#{missing_declared.join(',')}; unexpected=#{unexpected_declared.join(',')})" unless missing_declared.empty? && unexpected_declared.empty?

  items = documents.flat_map { |document| document[:items].map { |item| [item, document[:path]] } }
  raise "Context evidence items는 비어 있지 않은 배열이어야 합니다" unless items.is_a?(Array) && !items.empty?
  indexed = {}
  normalized = items.map.with_index do |(item, evidence_path), index|
    raise "Context evidence item[#{index}] mapping 불일치" unless item.is_a?(Hash)
    context = item["context_id"]
    covers_inputs = item["covers_inputs"]
    applicability = item["applicability"]
    discovery = item["discovery"]
    authority = item["authority"]
    raise "Context evidence item[#{index}].context_id 누락" unless text?(context)
    raise "Context evidence context_id 중복: #{context}" if indexed.key?(context)
    raise "#{context}.covers_inputs는 문자열 배열이어야 합니다" unless covers_inputs.is_a?(Array) && covers_inputs.all? { |value| text?(value) }
    unknown_inputs = covers_inputs - required_inputs
    raise "#{context}.covers_inputs에 선택되지 않은 input이 있습니다: #{unknown_inputs.join(', ')}" unless unknown_inputs.empty?
    raise "#{context}.applicability 불일치" unless APPLICABILITIES.include?(applicability)
    raise "#{context}.discovery 불일치" unless DISCOVERY_STATES.include?(discovery)
    raise "#{context}.authority는 비어 있지 않은 문자열이어야 합니다" unless text?(authority)
    raise "#{context}.reason은 미확인·제외 상태에 필요합니다" if (discovery != "confirmed" || applicability == "excluded") && !text?(item["reason"])

    locator = item["locator"]
    proof = item["proof"]
    if discovery == "confirmed"
      checked_scopes = item["checked_scopes"]
      raise "#{context}.checked_scopes는 비어 있지 않은 문자열 배열이어야 합니다" unless checked_scopes.is_a?(Array) && !checked_scopes.empty? && checked_scopes.all? { |value| text?(value) }
      raise "#{context}.locator mapping 누락" unless locator.is_a?(Hash) && %w[local remote].include?(locator["kind"]) && text?(locator["value"])
      raise "#{context}.proof mapping 누락" unless proof.is_a?(Hash)
      if locator["kind"] == "local"
        base = repository ? Pathname(repository).expand_path : evidence_path.dirname
        local_path = Pathname(locator["value"])
        local_path = base.join(local_path) unless local_path.absolute?
        raise "#{context} local locator가 일반 파일이 아닙니다: #{local_path}" unless local_path.file?
        actual_hash = "sha256:#{Digest::SHA256.file(local_path).hexdigest}"
        raise "#{context} local proof sha256가 실제 파일과 다릅니다" unless proof["sha256"] == actual_hash
        item = item.merge("locator" => locator.merge("resolved_path" => local_path.realpath.to_s), "proof" => proof.merge("file_hash_match" => true))
      else
        raise "#{context} remote confirmed는 proof.reference가 필요합니다" unless text?(proof["reference"])
        item = item.merge("proof" => proof.merge("artifact" => proof_artifact(proof, evidence_path, repository, context)))
      end
    end
    indexed[context] = item
    item
  end

  covered_required = normalized.select { |item| item["applicability"] == "required" }.flat_map { |item| item["covers_inputs"] }.uniq
  missing_items = required - covered_required
  raise "선택된 required Context evidence binding 누락: #{missing_items.join(', ')}" unless missing_items.empty?

  blocking = normalized.select { |item| item["applicability"] == "required" && item["discovery"] != "confirmed" }
  non_blocking = normalized.select { |item| item["applicability"] == "optional" && item["discovery"] != "confirmed" }
  {
    "status" => blocking.empty? ? "ready" : "blocked",
    "scoped_to" => required,
    "blocking_gaps" => blocking.map { |item| { "context_id" => item["context_id"], "covers_inputs" => item["covers_inputs"], "discovery" => item["discovery"], "reason" => item["reason"] } },
    "non_blocking_gaps" => non_blocking.map { |item| { "context_id" => item["context_id"], "covers_inputs" => item["covers_inputs"], "discovery" => item["discovery"], "reason" => item["reason"] } },
    "evidence" => normalized,
    "limitations" => [
      "profile, facets, applicability는 caller가 선택하며 resolver가 요청 의미에서 자동 추론하지 않음",
      "file/artifact hash 일치는 존재·무결성만 확인하며 caller가 적은 authority·checked_scopes와 내용의 진위·의미 적합성을 검증하지 않음"
    ]
  }
end

def verification_selection(impacts, exclusions, profile, facets, contract: nil)
  return nil if impacts.empty? && exclusions.empty?

  impacts = impacts.uniq
  unknown = (impacts + exclusions.keys).uniq - IMPACT_EVIDENCE.keys
  raise "알 수 없는 변경 impact입니다: #{unknown.join(', ')}" unless unknown.empty?
  overlap = impacts & exclusions.keys
  raise "impact를 선택하면서 제외할 수 없습니다: #{overlap.join(', ')}" unless overlap.empty?
  missing = IMPACT_EVIDENCE.keys - impacts - exclusions.keys
  if contract == "direct-v1"
    raise "direct-v1은 --exclude-impact를 받지 않습니다" unless exclusions.empty?
  else
    raise "모든 impact를 선택하거나 구체적 사유로 제외해야 합니다: #{missing.join(', ')}" unless missing.empty?
  end
  raise "적어도 하나의 impact를 선택해야 합니다" if impacts.empty?
  if impacts.include?("visual") && (!%w[ui mixed].include?(profile) || !(%w[ui-system visual-testing] - facets).empty?)
    raise "visual impact는 ui|mixed profile과 ui-system, visual-testing facet이 필요합니다"
  end
  if impacts.include?("interaction") && (!%w[ui mixed].include?(profile) || !facets.include?("ui-automation"))
    raise "interaction impact는 ui|mixed profile과 ui-automation facet이 필요합니다"
  end
  raise "async impact는 async-lifecycle facet이 필요합니다" if impacts.include?("async") && !facets.include?("async-lifecycle")
  raise "external impact는 external-contract facet이 필요합니다" if impacts.include?("external") && !facets.include?("external-contract")

  {
    "selected" => impacts.map { |impact| { "impact" => impact, "minimum_evidence" => IMPACT_EVIDENCE.fetch(impact) } },
    "excluded" => IMPACT_EVIDENCE.keys.each_with_object([]) do |impact, result|
      if exclusions.key?(impact)
        result << { "impact" => impact, "reason" => exclusions[impact] }
      elsif contract == "direct-v1" && !impacts.include?(impact)
        result << { "impact" => impact, "reason" => "omitted_by_direct_route" }
      end
    end,
    "reuse_policy" => "기존 evidence는 검증 입력·환경·대상이 동일하고 기존 reuse gate가 통과할 때만 재사용",
    "non_substitution" => "interaction impact는 Snapshot·render 결과로 대체하지 않음"
  }
end

begin
  unless options[:contract].nil? || %w[scoped-v2 direct-v1].include?(options[:contract])
    raise "알 수 없는 Context contract입니다: #{options[:contract]}"
  end
  if options[:contract] == "scoped-v2"
    raise "scoped-v2는 --evidence가 필요합니다" if options[:evidence].empty?
    raise "scoped-v2는 --impact와 모든 비선택 impact의 --exclude-impact가 필요합니다" if options[:impacts].empty? && options[:excluded_impacts].empty?
  end
  if options[:contract] == "direct-v1"
    raise "direct-v1은 --impact가 하나 이상 필요합니다" if options[:impacts].empty?
    raise "direct-v1은 --evidence를 사용하지 않습니다" unless options[:evidence].empty?
  end
  manifest_path = Pathname(options[:manifest] || Pathname(__dir__).join("../references/context-profiles.yaml")).expand_path
  manifest = YAML.safe_load(manifest_path.read, permitted_classes: [], aliases: false)
  profiles = manifest.fetch("profiles")
  facets = manifest.fetch("facets")
  profile_name = options.fetch(:profile)
  raise "알 수 없는 Context profile입니다: #{profile_name}" unless profiles.key?(profile_name)

  resolve_profile = nil
  resolving = []
  resolve_profile = lambda do |name|
    raise "알 수 없는 Context profile입니다: #{name}" unless profiles.key?(name)
    raise "Context profile 순환 참조입니다: #{(resolving + [name]).join(' -> ')}" if resolving.include?(name)

    resolving << name
    config = profiles.fetch(name)
    parents = Array(config["extends"]).map { |parent| resolve_profile.call(parent) }
    resolving.pop
    {
      "include" => ordered_union(parents.map { |item| item.fetch("include") }, config["include"]),
      "exclude" => ordered_union(parents.map { |item| item.fetch("exclude") }, config["exclude"])
    }
  end

  selected_profile = resolve_profile.call(profile_name)
  unknown_facets = options[:facets].reject { |name| facets.key?(name) }
  raise "알 수 없는 Context facet입니다: #{unknown_facets.join(', ')}" unless unknown_facets.empty?

  facet_context = options[:facets].flat_map { |name| Array(facets.fetch(name)["include"]) }
  required = ordered_union(manifest.dig("base", "include"), selected_profile.fetch("include"), facet_context)
  excluded = selected_profile.fetch("exclude").reject { |item| required.include?(item) }
  result = {
    "schema_version" => manifest.fetch("schema_version"),
    "profile" => profile_name,
    "facets" => options[:facets].uniq,
    "required_context" => required,
    "excluded_context" => excluded,
    "facet_notes" => options[:facets].to_h { |name| [name, facets.fetch(name)["note"]] }
  }
  result["selection_contract"] = options[:contract] if options[:contract]
  result["context_decision"] = load_context_evidence(options[:evidence], required, options[:repository]) unless options[:evidence].empty?
  selection = verification_selection(options[:impacts], options[:excluded_impacts], profile_name, options[:facets].uniq, contract: options[:contract])
  result["verification_selection"] = selection if selection
  puts JSON.pretty_generate(result)
  exit 3 if result.dig("context_decision", "status") == "blocked"
rescue KeyError, Psych::Exception, Errno::ENOENT, RuntimeError => error
  warn "ERROR: #{error.message}"
  exit 1
end
