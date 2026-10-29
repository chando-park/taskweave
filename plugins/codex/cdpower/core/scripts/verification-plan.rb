#!/usr/bin/env ruby

require "digest"
require "json"
require "open3"
require "optparse"
require "pathname"
require "yaml"

module VerificationPlan
  class EvidenceError < StandardError; end

  EVIDENCE_SCHEMA = "verification-reuse-evidence-v1"
  PREPARED_SCHEMA = "verification-reuse-prepared-v1"
  SCOPED_EVIDENCE_SCHEMA = "verification-reuse-evidence-v2"
  SCOPED_PREPARED_SCHEMA = "verification-reuse-prepared-v2"
  RESULT_SCHEMA = "verification-result-v1"
  INPUT_KINDS = %w[source tests resources dependency config environment].freeze
  SCOPED_REQUIRED_INPUT_KINDS = %w[source tests config environment].freeze

  module_function

  def validate(workplan)
    workplan = Pathname(workplan).expand_path
    raise EvidenceError, "missing Workplan: #{workplan}" unless workplan.file?

    text = workplan.read
    frontmatter = text.match(/\A---\n(.*?)\n---\n/m)
    raise EvidenceError, "missing Workplan frontmatter: #{workplan}" unless frontmatter
    data = YAML.safe_load(frontmatter[1], permitted_classes: [], aliases: false) || {}
    profile = data["verification_execution_profile"]
    status = data["verification_preflight_status"]
    raise EvidenceError, "verification_execution_profile must be normal or long_running" unless %w[normal long_running].include?(profile)

    if profile == "normal"
      raise EvidenceError, "normal verification requires preflight not_required or ready" unless %w[not_required ready].include?(status)
      return "Verification plan valid: normal"
    end

    raise EvidenceError, "long_running verification preflight is not ready" unless status == "ready"
    relative = data.dig("detail_documents", "test_plan")
    raise EvidenceError, "long_running verification requires detail_documents.test_plan" if relative.to_s.empty?
    test_plan = workplan.dirname.join(relative).cleanpath
    raise EvidenceError, "test plan escapes Workplan bundle" unless test_plan.to_s.start_with?(workplan.dirname.to_s + File::SEPARATOR)
    raise EvidenceError, "missing long-running test plan: #{test_plan}" unless test_plan.file?

    required = ["## Direct Tests", "## Setup and Cache", "## Resources and Ordering", "## Retry and Stop"]
    missing = required.reject { |heading| test_plan.read.include?(heading) }
    raise EvidenceError, "incomplete long-running test plan: #{missing.join(', ')}" unless missing.empty?
    "Verification plan valid: long_running"
  end

  def prepare(repository:, prepared:, command:, kind:, inputs:, subject_ids: [])
    context = repository_context(repository)
    raise EvidenceError, "--command is required" if command.to_s.strip.empty?
    raise EvidenceError, "--kind must be test or compile" unless %w[test compile].include?(kind)
    raise EvidenceError, "at least one --input KIND:PATH is required" if inputs.empty?
    input_records = inputs.map { |value| input_record(context.fetch("repository"), value) }.sort_by { |entry| [entry.fetch("kind"), entry.fetch("path")] }
    raise EvidenceError, "duplicate --input path" unless input_records.map { |entry| entry.fetch("path") }.uniq.length == input_records.length
    validate_subject_ids(subject_ids) unless subject_ids.empty?
    validate_scoped_inputs(input_records) unless subject_ids.empty?
    config_records = input_records.select { |entry| entry.fetch("kind") == "config" }
    payload = {
      "schema" => subject_ids.empty? ? PREPARED_SCHEMA : SCOPED_PREPARED_SCHEMA,
      "repository" => context,
      "head" => git(context.fetch("repository"), "rev-parse", "HEAD").strip,
      "prepared_at_epoch" => Time.now.to_f,
      "command" => command,
      "kind" => kind,
      "command_fingerprint" => digest(command),
      "config_fingerprint" => digest(config_records),
      "inputs" => input_records
    }
    payload["subject_ids"] = subject_ids.sort unless subject_ids.empty?
    target = safe_evidence_target(prepared, context.fetch("repository"), input_records)
    target.write(JSON.pretty_generate(payload) + "\n", encoding: "UTF-8")
    JSON.generate("status" => "prepared", "prepared" => target.to_s, "head" => payload.fetch("head"), "input_count" => input_records.length)
  end

  def capture(repository:, prepared:, evidence:, command:, artifact:)
    context = repository_context(repository)
    snapshot = read_json(prepared, "prepared evidence")
    unless [PREPARED_SCHEMA, SCOPED_PREPARED_SCHEMA].include?(snapshot["schema"])
      raise EvidenceError, "unsupported prepared evidence schema"
    end
    verify_snapshot(snapshot, context, command, require_current_head: true)
    artifact_record = external_file_record(artifact, label: "result artifact", repository: context.fetch("repository"))
    raise EvidenceError, "result artifact predates prepared verification run" unless artifact_record.fetch("mtime_epoch") >= snapshot.fetch("prepared_at_epoch", Float::INFINITY)
    validate_success_result(artifact_record, expected_kind: snapshot["kind"], expected_subject_ids: snapshot["subject_ids"])
    target = safe_evidence_target(evidence, context.fetch("repository"), snapshot.fetch("inputs"), artifact_record)
    evidence_schema = snapshot["schema"] == SCOPED_PREPARED_SCHEMA ? SCOPED_EVIDENCE_SCHEMA : EVIDENCE_SCHEMA
    payload = snapshot.merge("schema" => evidence_schema, "prepared_evidence" => Pathname(prepared).expand_path.to_s, "result_artifact" => artifact_record)
    target.write(JSON.pretty_generate(payload) + "\n", encoding: "UTF-8")
    JSON.generate("status" => "captured", "evidence" => target.to_s, "head" => payload.fetch("head"), "input_count" => snapshot.fetch("inputs").length)
  end

  def reusable(repository:, evidence:, command:)
    data = reusable_payload(repository: repository, evidence: evidence, command: command)
    JSON.generate("status" => "reusable", "evidence" => Pathname(evidence).expand_path.to_s, "head" => data.fetch("head"),
                  "current_head" => data.fetch("current_head"), "head_changed" => data.fetch("head_changed"),
                  "command_fingerprint" => data.fetch("command_fingerprint"))
  rescue JSON::ParserError => error
    raise EvidenceError, "invalid evidence JSON: #{error.message}"
  end

  def reusable_payload(repository:, evidence:, command:, expected_subject_ids: nil)
    context = repository_context(repository)
    evidence_path = Pathname(evidence).expand_path
    raise EvidenceError, "missing evidence: #{evidence_path}" unless evidence_path.file?
    data = read_json(evidence_path, "evidence")
    unless [EVIDENCE_SCHEMA, SCOPED_EVIDENCE_SCHEMA].include?(data["schema"])
      raise EvidenceError, "unsupported evidence schema"
    end
    if expected_subject_ids
      raise EvidenceError, "scoped reuse evidence is required" unless data["schema"] == SCOPED_EVIDENCE_SCHEMA
      validate_subject_ids(expected_subject_ids)
      raise EvidenceError, "verification subject IDs changed" unless data["subject_ids"] == expected_subject_ids.sort
    end
    verify_snapshot(data, context, command, require_current_head: data["schema"] == EVIDENCE_SCHEMA)
    current_artifact = external_file_record(data.dig("result_artifact", "path"), label: "result artifact")
    raise EvidenceError, "result artifact changed or missing" unless current_artifact == data["result_artifact"]
    validate_success_result(current_artifact, expected_kind: data["kind"], expected_subject_ids: data["subject_ids"])
    current_head = git(context.fetch("repository"), "rev-parse", "HEAD").strip
    data.merge("current_head" => current_head, "head_changed" => data["head"] != current_head)
  end

  def repository_context(repository)
    root = Pathname(repository).expand_path
    raise EvidenceError, "Git repository is missing: #{root}" unless root.directory?
    actual = Pathname(git(root, "rev-parse", "--show-toplevel").strip).realpath
    raise EvidenceError, "repository must be its Git worktree root: #{actual}" unless root.realpath == actual
    git_dir = Pathname(git(actual, "rev-parse", "--git-dir").strip)
    git_dir = actual.join(git_dir) unless git_dir.absolute?
    { "repository" => actual.to_s, "git_dir" => git_dir.realpath.to_s }
  end

  def input_record(repository, value)
    kind, path = value.to_s.split(":", 2)
    raise EvidenceError, "--input must be KIND:PATH (KIND: #{INPUT_KINDS.join(', ')})" unless INPUT_KINDS.include?(kind) && path && !path.empty?
    file_record(repository, path, label: "#{kind} input").merge("kind" => kind)
  end

  def file_record(repository, value, label:)
    path = Pathname(value.to_s)
    candidate = path.absolute? ? path.cleanpath : Pathname(repository).join(path).cleanpath
    root = Pathname(repository).realpath
    raise EvidenceError, "#{label} escapes repository: #{value}" unless candidate.to_s.start_with?(root.to_s + File::SEPARATOR)
    raise EvidenceError, "missing #{label}: #{value}" unless candidate.file?
    resolved = candidate.realpath
    raise EvidenceError, "#{label} escapes repository: #{value}" unless resolved.to_s.start_with?(root.to_s + File::SEPARATOR)
    relative = resolved.relative_path_from(root).to_s
    { "path" => relative, "sha256" => Digest::SHA256.file(resolved).hexdigest, "bytes" => resolved.size }
  end

  def external_file_record(value, label:, repository: nil)
    raw = Pathname(value.to_s)
    path = raw.absolute? ? raw : (repository ? Pathname(repository).join(raw) : raw)
    path = path.expand_path
    raise EvidenceError, "missing #{label}: #{value}" unless path.file?
    resolved = path.realpath
    raise EvidenceError, "#{label} is empty: #{value}" if resolved.size.zero?
    { "path" => resolved.to_s, "sha256" => Digest::SHA256.file(resolved).hexdigest, "bytes" => resolved.size, "mtime_epoch" => resolved.mtime.to_f }
  end

  def verify_snapshot(data, context, command, require_current_head:)
    raise EvidenceError, "command changed" unless data["command"] == command && data["command_fingerprint"] == digest(command)
    raise EvidenceError, "repository context changed" unless data["repository"].is_a?(Hash) && data["repository"] == context
    inputs = data["inputs"]
    raise EvidenceError, "missing verification inputs" unless inputs.is_a?(Array) && !inputs.empty?
    inputs.each do |entry|
      current = input_record(context.fetch("repository"), "#{entry['kind']}:#{entry['path']}")
      raise EvidenceError, "verification input changed or missing: #{entry['path']}" unless current == entry
    end
    configs = inputs.select { |entry| entry["kind"] == "config" }
    raise EvidenceError, "verification config changed" unless data["config_fingerprint"] == digest(configs)
    current_head = git(context.fetch("repository"), "rev-parse", "HEAD").strip
    raise EvidenceError, "HEAD changed" if require_current_head && data["head"] != current_head
    if data["schema"] == SCOPED_PREPARED_SCHEMA || data["schema"] == SCOPED_EVIDENCE_SCHEMA
      validate_subject_ids(data["subject_ids"])
      validate_scoped_inputs(inputs)
    end
  end

  def validate_subject_ids(subject_ids)
    valid = subject_ids.is_a?(Array) && subject_ids.uniq.length == subject_ids.length &&
      subject_ids.all? { |item| item.is_a?(String) && !item.strip.empty? }
    raise EvidenceError, "subject IDs must be a unique non-empty string array" unless valid
  end

  def validate_scoped_inputs(inputs)
    kinds = inputs.map { |entry| entry["kind"] }.compact.uniq
    missing = SCOPED_REQUIRED_INPUT_KINDS - kinds
    raise EvidenceError, "scoped reuse requires hashed source/tests/config/environment inputs: #{missing.join(', ')}" unless missing.empty?
  end

  def validate_success_result(record, expected_kind:, expected_subject_ids: nil)
    result = read_json(record.fetch("path"), "result artifact")
    if expected_subject_ids && result["schema"] == "snapshot-result-v1"
      valid_ids = result["test_ids"].is_a?(Array) && result["test_ids"].uniq.length == result["test_ids"].length
      raise EvidenceError, "snapshot result test IDs do not match scoped subjects" unless valid_ids && result["test_ids"].sort == expected_subject_ids.sort
      raise EvidenceError, "snapshot result must record a complete pass" unless result["executed_count"] == result["test_ids"].length &&
        result["failures"] == 0 && result["exit_status"] == 0
      return
    end
    raise EvidenceError, "result artifact schema must be #{RESULT_SCHEMA}" unless result["schema"] == RESULT_SCHEMA
    raise EvidenceError, "result artifact must record passed exit_status 0" unless result["status"] == "passed" && result["exit_status"].is_a?(Integer) && result["exit_status"].zero?
    raise EvidenceError, "result artifact kind does not match prepared verification kind" unless result["kind"] == expected_kind
    if expected_kind == "test"
      raise EvidenceError, "test result must record test_count greater than 0" unless result["test_count"].is_a?(Integer) && result["test_count"].positive?
    elsif result["kind"] != "compile"
      raise EvidenceError, "result artifact kind must be test or compile"
    end
  end

  def safe_evidence_target(value, repository, inputs, artifact = nil)
    target = Pathname(value).expand_path
    raise EvidenceError, "evidence parent is missing: #{target.dirname}" unless target.dirname.directory?
    resolved = target.exist? ? target.realpath : target.dirname.realpath.join(target.basename)
    input_paths = inputs.map { |entry| Pathname(repository).join(entry.fetch("path")).realpath.to_s }
    raise EvidenceError, "evidence path aliases an input or result artifact" if artifact && resolved.to_s == artifact.fetch("path")
    raise EvidenceError, "evidence path aliases an input" if input_paths.include?(resolved.to_s)
    target
  end

  def read_json(path, label)
    JSON.parse(Pathname(path).read(encoding: "UTF-8"))
  rescue JSON::ParserError => error
    raise EvidenceError, "invalid #{label} JSON: #{error.message}"
  end

  def digest(value)
    Digest::SHA256.hexdigest(JSON.generate(value))
  end

  def git(repository, *arguments)
    output, error, status = Open3.capture3("git", "-C", repository.to_s, *arguments)
    raise EvidenceError, "Git context lookup failed: #{error.strip}" unless status.success?
    output
  end
end

if $PROGRAM_NAME == __FILE__
command = ARGV.shift
begin
  case command
  when "validate"
    abort "usage: verification-plan validate <workplan>" unless ARGV.length == 1
    puts VerificationPlan.validate(ARGV.fetch(0))
  when "prepare"
    options = { inputs: [], subject_ids: [] }
    OptionParser.new do |parser|
      parser.on("--repository ROOT") { |value| options[:repository] = value }
      parser.on("--prepared PATH") { |value| options[:prepared] = value }
      parser.on("--command COMMAND") { |value| options[:command] = value }
      parser.on("--kind KIND") { |value| options[:kind] = value }
      parser.on("--input KIND:PATH") { |value| options[:inputs] << value }
      parser.on("--subject-id ID") { |value| options[:subject_ids] << value }
    end.parse!
    abort "usage: verification-plan prepare --repository ROOT --prepared PATH --command COMMAND --kind test|compile --input KIND:PATH" unless ARGV.empty? && %i[repository prepared command kind].all? { |key| options[key] }
    puts VerificationPlan.prepare(**options)
  when "capture"
    options = {}
    OptionParser.new do |parser|
      parser.on("--repository ROOT") { |value| options[:repository] = value }
      parser.on("--prepared PATH") { |value| options[:prepared] = value }
      parser.on("--evidence PATH") { |value| options[:evidence] = value }
      parser.on("--command COMMAND") { |value| options[:command] = value }
      parser.on("--result-artifact PATH") { |value| options[:artifact] = value }
    end.parse!
    abort "usage: verification-plan capture --repository ROOT --prepared PATH --evidence PATH --command COMMAND --result-artifact PATH" unless ARGV.empty? && %i[repository prepared evidence command artifact].all? { |key| options[key] }
    puts VerificationPlan.capture(**options)
  when "reusable"
    options = {}
    OptionParser.new do |parser|
      parser.on("--repository ROOT") { |value| options[:repository] = value }
      parser.on("--evidence PATH") { |value| options[:evidence] = value }
      parser.on("--command COMMAND") { |value| options[:command] = value }
    end.parse!
    abort "usage: verification-plan reusable --repository ROOT --evidence PATH --command COMMAND" unless ARGV.empty? && %i[repository evidence command].all? { |key| options[key] }
    puts VerificationPlan.reusable(**options)
  else
    abort "usage: verification-plan validate|prepare|capture|reusable ..."
  end
rescue VerificationPlan::EvidenceError => error
  warn error.message
  exit 1
end
end
