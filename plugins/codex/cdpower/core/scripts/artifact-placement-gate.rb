#!/usr/bin/env ruby

require "digest"
require "json"
require "open3"
require "optparse"
require "pathname"
require "yaml"
require_relative "workplan-layout"

module ArtifactPlacementGate
  class ValidationError < StandardError; end

  SCHEMA = "repository-artifact-placement-v1"
  POLICY_SCHEMA = "repository-official-document-policy-v1"
  PHASES = %w[plan apply feedback completion].freeze
  FEEDBACK_RECEIPT_SCHEMA = "repository-feedback-baseline-v1"
  FEEDBACK_RECEIPT_RELATIVE = "Artifacts/repository-feedback-baseline.json"
  DESTINATIONS = %w[product-repository central-workplan product-memory project-agent personal-runtime].freeze
  REPOSITORY_KINDS = %w[code test resource configuration official-document].freeze
  CENTRAL_KINDS = %w[workplan investigation plan architecture-analysis implementation-explanation verification-report figma-comparison product-memory-copy project-agent-copy ai-work-document].freeze
  AI_DOCUMENT_KINDS = CENTRAL_KINDS.freeze
  ACTIONS = %w[create update delete].freeze
  SHA256 = /\Asha256:[0-9a-f]{64}\z/
  FINGERPRINT_STATUSES = %w[modified added deleted type_changed unmerged untracked clean].freeze

  module_function

  def validate(workplan, phase:, repository: nil)
    workplan = Pathname(workplan).expand_path
    raise ValidationError, "Workplan이 없습니다: #{workplan}" unless workplan.file?
    raise ValidationError, "지원하지 않는 phase입니다: #{phase}" unless PHASES.include?(phase)
    _raw, data = WorkplanLayout.frontmatter(workplan.read(encoding: "UTF-8"))
    if WorkplanLayout.approval_memo?(data)
      require_relative "workplan-memo"
      begin
        return WorkplanMemo.validate_artifact_placement(workplan, phase: phase, repository: repository || data["repository_root"])
      rescue WorkplanMemo::ValidationError => error
        raise ValidationError, error.message
      end
    end
    packet = read_plan(workplan, data)
    errors = []
    validate_feedback_authority(data, errors) if phase == "feedback"
    errors << "artifact placement schema 불일치" unless packet["schema"] == SCHEMA
    root = resolve_repository(repository || data["repository_root"], errors)
    artifacts, central_artifacts = validate_artifacts(workplan, packet, root, errors)
    baseline = validate_baseline(packet["repository_diff_baseline"], root, phase, errors)
    feedback_entries = if root && phase == "feedback"
                         issue_feedback_receipt(workplan, artifacts, baseline, root, errors)
                       elsif root && phase == "completion"
                         read_feedback_receipt(workplan, baseline, errors)
                       else
                         {}
                       end
    if root && phase == "completion"
      validate_completion(artifacts, baseline, root, errors, feedback_entries: feedback_entries)
      validate_central_completion(central_artifacts, errors)
    end
    raise ValidationError, errors.join("\n") unless errors.empty?
    "Artifact placement gate valid: #{phase}"
  rescue Psych::SyntaxError, JSON::ParserError, KeyError => error
    raise ValidationError, "artifact placement packet을 해석할 수 없습니다: #{error.message}"
  end

  def validate_feedback_authority(data, errors)
    allowed = %w[implementing verifying verification_blocked awaiting_completion]
    errors << "feedback은 활성 승인 Workplan에서만 시작할 수 있습니다" unless allowed.include?(data["status"])
    errors << "feedback은 authority_status: approved를 유지해야 합니다" unless data["authority_status"] == "approved"
    %w[approved_at approved_by approval_revision].each do |field|
      errors << "feedback 승인 메타데이터 누락: #{field}" unless text?(data[field])
    end
  end

  # Read-only scope boundary for consumers that must compare a proposed file
  # delta with the files approved by the structured artifact placement plan.
  def approved_product_code_and_test_files(workplan)
    workplan = Pathname(workplan).expand_path
    raise ValidationError, "Workplan이 없습니다: #{workplan}" unless workplan.file?
    _raw, data = WorkplanLayout.frontmatter(workplan.read(encoding: "UTF-8"))
    if WorkplanLayout.approval_memo?(data)
      require_relative "workplan-memo"
      begin
        return WorkplanMemo.approved_scope_paths(workplan).select do |path|
          WorkplanMemo::SOURCE_EXTENSIONS.include?(File.extname(path).downcase) || path.match?(/(?:test|spec)/i)
        end
      rescue WorkplanMemo::ValidationError => error
        raise ValidationError, error.message
      end
    end
    packet = read_plan(workplan, data)
    errors = []
    errors << "artifact placement schema 불일치" unless packet["schema"] == SCHEMA
    repository = resolve_repository(data["repository_root"], errors)
    product, = validate_artifacts(workplan, packet, repository, errors)
    files = product.each_with_object([]) do |(path, artifact), approved|
      approved << path if %w[code test].include?(artifact["kind"])
    end.sort
    errors << "승인된 product-repository code/test artifact가 없습니다" if files.empty?
    raise ValidationError, errors.join("\n") unless errors.empty?
    files
  rescue Psych::SyntaxError, JSON::ParserError, KeyError => error
    raise ValidationError, "artifact placement 승인 파일을 해석할 수 없습니다: #{error.message}"
  end

  def validate_artifacts(workplan, packet, repository, errors)
    mapping = packet["artifacts"]
    unless nonempty_hash?(mapping)
      errors << "artifact placement 계획 mapping이 비어 있습니다"
      return {}
    end
    roots = packet["destination_roots"]
    roots = {} unless roots.is_a?(Hash)
    seen = {}
    product = {}
    central = {}
    mapping.each do |id, artifact|
      unless id.to_s.match?(/\AART-[A-Za-z0-9_-]+\z/) && artifact.is_a?(Hash)
        errors << "artifact ID 또는 mapping 불일치: #{id}"
        next
      end
      destination = artifact["destination"]
      path = artifact["path"]
      errors << "#{id}.destination 불일치" unless DESTINATIONS.include?(destination)
      unless safe_relative?(path) && !git_admin_path?(path)
        errors << "#{id}.path traversal/absolute/Git-admin 불일치: #{path.inspect}"
        next
      end
      key = [destination, path]
      errors << "동일 destination/path를 여러 ART ID가 소유합니다: #{destination}:#{path}" if seen[key]
      seen[key] = id
      if destination == "product-repository"
        validate_product_artifact(id, artifact, repository, errors)
        product[path] = artifact.merge("id" => id)
      else
        resolved = validate_central_artifact(workplan, id, artifact, destination, roots, repository, errors)
        central[[destination, path]] = artifact.merge("id" => id, "resolved_path" => resolved.to_s) if resolved
      end
    end
    [product, central]
  end

  def validate_central_artifact(workplan, id, artifact, destination, roots, repository, errors)
    errors << "#{id}.kind는 중앙 산출물 종류여야 합니다" unless CENTRAL_KINDS.include?(artifact["kind"])
    errors << "#{id}.action 불일치" unless ACTIONS.include?(artifact["action"])
    errors << "#{id}.required는 boolean이어야 합니다" unless boolean?(artifact["required"])
    root = if destination == "central-workplan"
             workplan.dirname.realpath
           else
             raw = roots[destination]
             unless text?(raw) && Pathname(raw).absolute?
               errors << "#{id} #{destination}에는 resolver가 제공한 절대 destination_root가 필요합니다"
               return
             end
             Pathname(raw).expand_path
           end
    if repository && same_realpath?(root, repository)
      errors << "#{id} 중앙 destination root는 제품 저장소일 수 없습니다"
      return
    end
    safe_destination_path(root, artifact["path"], errors, id)
  end

  def safe_destination_path(root, relative, errors, id)
    root = root.realpath if root.exist?
    unless root.directory?
      errors << "#{id} destination root가 없습니다: #{root}"
      return
    end
    path = root.join(relative).cleanpath
    unless inside?(path, root)
      errors << "#{id} destination path가 root 밖입니다"
      return
    end
    current = root
    Pathname(relative).each_filename do |segment|
      current = current.join(segment)
      if current.symlink?
        errors << "#{id} destination symlink는 허용하지 않습니다: #{relative}"
        return
      end
      break unless current.exist?
      unless inside?(current.realpath, root.realpath)
        errors << "#{id} destination realpath가 root 밖입니다: #{relative}"
        return
      end
    end
    path
  rescue Errno::ENOENT
    errors << "#{id} destination 경로를 확인할 수 없습니다"
    nil
  end

  def validate_central_completion(artifacts, errors)
    artifacts.each_value do |artifact|
      path = Pathname(artifact["resolved_path"])
      action = artifact["action"]
      required = artifact["required"] == true
      if action == "delete"
        errors << "#{artifact['id']} 중앙 delete artifact가 completion에도 존재합니다" if path.exist? || path.symlink?
        next
      end
      unless path.exist?
        errors << "#{artifact['id']} completion에 필수 중앙 artifact가 없습니다" if required
        next
      end
      if path.symlink? || !path.file?
        errors << "#{artifact['id']} 중앙 artifact는 symlink가 아닌 일반 파일이어야 합니다"
        next
      end
      expected_hash = artifact["hash"]
      unless expected_hash.is_a?(String) && expected_hash.match?(SHA256)
        errors << "#{artifact['id']} 중앙 create/update completion에는 file hash가 필요합니다"
        next
      end
      actual_hash = "sha256:#{Digest::SHA256.file(path).hexdigest}"
      errors << "#{artifact['id']} 중앙 artifact hash가 실제 파일과 다릅니다" unless actual_hash == expected_hash
    rescue Errno::ENOENT
      errors << "#{artifact['id']} 중앙 artifact realpath를 확인할 수 없습니다"
    end
  end

  def validate_product_artifact(id, artifact, repository, errors)
    errors << "#{id}.kind 불일치" unless REPOSITORY_KINDS.include?(artifact["kind"])
    errors << "#{id}.action 불일치" unless ACTIONS.include?(artifact["action"])
    errors << "#{id}.required는 boolean이어야 합니다" unless boolean?(artifact["required"])
    path = artifact["path"]
    validate_repository_realpath(repository, path, errors, id) if repository
    if AI_DOCUMENT_KINDS.include?(artifact["kind"])
      errors << "#{id} AI 작업 문서는 제품 저장소에 둘 수 없습니다"
      return
    end
    return unless document_path?(path) || artifact["kind"] == "official-document"
    unless artifact["kind"] == "official-document"
      errors << "#{id} 문서 경로는 official-document 예외 조건이 필요합니다"
      return
    end
    validate_official_document(id, artifact, repository, errors)
  end

  def validate_official_document(id, artifact, repository, errors)
    errors << "#{id} 공식 문서는 update-existing만 허용합니다" unless artifact["action"] == "update"
    errors << "#{id}.product_owned는 boolean true여야 합니다" unless artifact["product_owned"] == true
    errors << "#{id}.update_existing는 boolean true여야 합니다" unless artifact["update_existing"] == true
    requirement = artifact["requirement"]
    errors << "#{id} 공식 문서에는 명시적 user/ticket 요구 근거가 필요합니다" unless requirement.is_a?(Hash) && %w[user ticket].include?(requirement["kind"]) && text?(requirement["reference"])
    policy = artifact["repository_policy"]
    unless policy.is_a?(Hash) && text?(policy["artifact"]) && policy["hash"].is_a?(String) && policy["hash"].match?(SHA256)
      errors << "#{id} 공식 문서에는 구조화 repository policy artifact/hash가 필요합니다"
      return
    end
    return unless repository
    errors << "#{id} 신규 문서 위치는 허용하지 않습니다: #{artifact['path']}" unless tracked_at_head?(repository, artifact["path"])
    validate_policy_allow(id, artifact, repository, policy, errors)
  end

  def validate_policy_allow(id, artifact, repository, policy, errors)
    unless safe_relative?(policy["artifact"]) && !git_admin_path?(policy["artifact"])
      errors << "#{id} repository policy 경로 불일치"
      return
    end
    path = repository.join(policy["artifact"]).cleanpath
    unless path.file? && !path.symlink? && inside?(path.realpath, repository.realpath) && tracked_at_head?(repository, policy["artifact"])
      errors << "#{id} repository policy artifact는 repository 안의 HEAD tracked 일반 파일이어야 합니다"
      return
    end
    actual_hash = "sha256:#{Digest::SHA256.file(path).hexdigest}"
    errors << "#{id} repository policy hash가 실제 파일과 다릅니다" unless actual_hash == policy["hash"]
    parsed = structured_policy(path)
    unless parsed.is_a?(Hash) && parsed["schema"] == POLICY_SCHEMA && parsed["allow"].is_a?(Array)
      errors << "#{id} repository policy의 구조화 allow packet이 없습니다"
      return
    end
    allowed = parsed["allow"].any? do |entry|
      entry.is_a?(Hash) && entry["path"] == artifact["path"] && entry["actions"].is_a?(Array) && entry["actions"].include?(artifact["action"])
    end
    errors << "#{id} repository policy가 target path/action을 긍정 허용하지 않습니다" unless allowed
  end

  def structured_policy(path)
    text = path.read(encoding: "UTF-8")
    documents = text.scan(/```ya?ml\s*\n(.*?)\n```/m).flatten
    documents << text if documents.empty?
    documents.each do |yaml|
      parsed = YAML.safe_load(yaml, permitted_classes: [], aliases: false) || {}
      value = parsed["repository_artifact_policy"]
      return value if value.is_a?(Hash)
    rescue Psych::SyntaxError
      next
    end
    nil
  end

  def validate_baseline(packet, repository, phase, errors)
    unless packet.is_a?(Hash)
      errors << "repository_diff_baseline mapping 누락"
      return { "head_oid" => nil, "entries" => {} }
    end
    head_oid = packet["head_oid"]
    entries = packet["entries"]
    unless head_oid.is_a?(String) && head_oid.match?(/\A[0-9a-f]{40,64}\z/)
      errors << "repository_diff_baseline.head_oid 형식 불일치"
    end
    unless entries.is_a?(Hash) && entries.all? { |path, fingerprint| safe_relative?(path) && !git_admin_path?(path) && valid_fingerprint?(fingerprint) }
      errors << "repository_diff_baseline.entries 경로/fingerprint 불일치"
      entries = {}
    end
    expected_digest = baseline_digest(head_oid, entries)
    errors << "repository_diff_baseline.digest 형식 또는 값 불일치" unless packet["digest"].is_a?(String) && packet["digest"].match?(SHA256) && packet["digest"] == expected_digest
    if repository
      actual_head = git_head(repository, errors)
      errors << "현재 HEAD OID가 승인 baseline과 다릅니다" unless actual_head == head_oid
      if %w[plan apply].include?(phase)
        current = changed_entries(repository, errors)
        errors << "현재 dirty fingerprint가 승인 baseline과 다릅니다" unless current == entries
      end
    end
    { "head_oid" => head_oid, "entries" => entries, "digest" => packet["digest"] }
  end

  def validate_completion(artifacts, baseline, repository, errors, feedback_entries: {})
    current = changed_entries(repository, errors)
    baseline_entries = baseline["entries"]
    preservation_entries = baseline_entries.merge(feedback_entries)
    preservation_entries.each do |path, before|
      artifact = artifacts[path]
      if artifact && baseline_entries.key?(path)
        ownership = artifact["baseline_ownership"]
        unless ownership.is_a?(Hash) && ownership["before"] == before && valid_fingerprint?(ownership["after"])
          errors << "#{artifact['id']} baseline 소유 경로에는 정확한 before→after fingerprint가 필요합니다: #{path}"
          next
        end
        after = current[path] || clean_fingerprint(repository, path, errors)
        errors << "#{artifact['id']} baseline after fingerprint가 실제 결과와 다릅니다: #{path}" unless after == ownership["after"]
        errors << "#{artifact['id']} baseline 소유 경로가 실제로 변경되지 않았습니다: #{path}" if artifact["required"] == true && after == before
      else
        errors << "기존 사용자 dirty fingerprint가 변경되었습니다: #{path}" unless current[path] == before
      end
    end
    (current.keys - preservation_entries.keys).each do |path|
      next if artifacts.key?(path)
      label = document_path?(path) ? "문서" : "artifact"
      errors << "계획에 없는 제품 저장소 #{label} diff: #{path.inspect}"
    end
    artifacts.each do |path, artifact|
      if artifact["required"] == true && !baseline_entries.key?(path) && !current.key?(path)
        errors << "completion에 필수 계획 artifact가 실제 diff에 없습니다: #{path.inspect}"
      end
      validate_action(path, artifact, baseline_entries[path], current[path], repository, errors)
    end
  end

  def issue_feedback_receipt(workplan, artifacts, baseline, repository, errors)
    current = changed_entries(repository, errors)
    ambient = current.reject { |path, _fingerprint| artifacts.key?(path) }
    receipt = {
      "schema" => FEEDBACK_RECEIPT_SCHEMA,
      "workplan" => workplan.basename.to_s,
      "head_oid" => baseline["head_oid"],
      "approval_baseline_digest" => baseline["digest"],
      "entries" => ambient
    }
    receipt["digest"] = feedback_receipt_digest(receipt)
    return {} unless errors.empty?
    path = feedback_receipt_path(workplan, errors)
    return {} unless path
    path.dirname.mkpath
    path.write(JSON.pretty_generate(receipt) + "\n", encoding: "UTF-8")
    ambient
  rescue SystemCallError => error
    errors << "feedback baseline receipt를 기록할 수 없습니다: #{error.message}"
    {}
  end

  def read_feedback_receipt(workplan, baseline, errors)
    path = feedback_receipt_path(workplan, errors)
    return {} unless path&.file?
    receipt = JSON.parse(path.read(encoding: "UTF-8"))
    errors << "feedback baseline receipt schema 불일치" unless receipt["schema"] == FEEDBACK_RECEIPT_SCHEMA
    errors << "feedback baseline receipt Workplan 불일치" unless receipt["workplan"] == workplan.basename.to_s
    errors << "feedback baseline receipt HEAD 불일치" unless receipt["head_oid"] == baseline["head_oid"]
    errors << "feedback baseline receipt 승인 baseline 불일치" unless receipt["approval_baseline_digest"] == baseline["digest"]
    entries = receipt["entries"]
    unless entries.is_a?(Hash) && entries.all? { |path_key, fingerprint| safe_relative?(path_key) && !git_admin_path?(path_key) && valid_fingerprint?(fingerprint) }
      errors << "feedback baseline receipt entries 불일치"
      return {}
    end
    errors << "feedback baseline receipt digest 불일치" unless receipt["digest"] == feedback_receipt_digest(receipt)
    entries
  rescue JSON::ParserError, SystemCallError => error
    errors << "feedback baseline receipt를 읽을 수 없습니다: #{error.message}"
    {}
  end

  def feedback_receipt_path(workplan, errors)
    root = workplan.dirname.realpath
    path = root.join(FEEDBACK_RECEIPT_RELATIVE).cleanpath
    unless inside?(path, root) && !path.symlink?
      errors << "feedback baseline receipt 경로가 Workplan 밖이거나 symlink입니다"
      return nil
    end
    path
  rescue Errno::ENOENT
    errors << "feedback baseline receipt 경로를 확인할 수 없습니다"
    nil
  end

  def feedback_receipt_digest(receipt)
    payload = {
      "head_oid" => receipt["head_oid"],
      "approval_baseline_digest" => receipt["approval_baseline_digest"],
      "entries" => receipt["entries"]
    }
    sha256(JSON.generate(canonical(payload)))
  end

  def validate_action(path, artifact, baseline_before, current, repository, errors)
    if baseline_before
      return unless artifact["baseline_ownership"].is_a?(Hash)
      after = current || clean_fingerprint(repository, path, errors)
      case artifact["action"]
      when "update"
        errors << "baseline update 결과가 존재하지 않습니다: #{path.inspect}" if after["status"] == "deleted"
      when "delete"
        errors << "baseline delete 결과가 deleted/clean이 아닙니다: #{path.inspect}" unless %w[deleted clean].include?(after["status"])
      when "create"
        errors << "이미 dirty baseline에 있던 경로를 create로 소유할 수 없습니다: #{path.inspect}"
      end
      return
    end
    return unless current
    allowed = case artifact["action"]
              when "create" then %w[added untracked]
              when "update" then %w[modified type_changed]
              when "delete" then %w[deleted]
              else []
              end
    errors << "#{artifact['action']} action과 실제 status가 다릅니다: #{path.inspect}=#{current['status']}" unless allowed.include?(current["status"])
  end

  def changed_entries(repository, errors)
    statuses = diff_statuses(repository, errors)
    untracked, error, status = Open3.capture3("git", "-C", repository.to_s, "ls-files", "--others", "--exclude-standard", "-z", "--")
    unless status.success?
      errors << "untracked 경로를 읽을 수 없습니다: #{error.strip}"
      return {}
    end
    untracked.split("\0", -1).reject(&:empty?).each { |path| statuses[path] = "untracked" }
    statuses.keys.sort.each_with_object({}) do |path, result|
      result[path] = fingerprint(repository, path, statuses[path], errors)
    end
  end

  def diff_statuses(repository, errors)
    output, error, status = Open3.capture3("git", "-C", repository.to_s, "diff", "--no-renames", "--name-status", "-z", "HEAD", "--")
    unless status.success?
      errors << "tracked diff를 읽을 수 없습니다: #{error.strip}"
      return {}
    end
    fields = output.split("\0", -1).reject(&:empty?)
    result = {}
    index = 0
    while index < fields.length
      status_code = fields[index]
      path = fields[index + 1]
      unless path
        errors << "tracked name-status -z 결과가 불완전합니다"
        break
      end
      result[path] = status_name(status_code, errors)
      index += 2
    end
    result
  end

  def status_name(code, errors)
    case code.to_s[0]
    when "M" then "modified"
    when "A" then "added"
    when "D" then "deleted"
    when "T" then "type_changed"
    when "U" then "unmerged"
    else
      errors << "지원하지 않는 git diff status: #{code.inspect}"
      "unmerged"
    end
  end

  def fingerprint(repository, relative, status, errors)
    if status == "deleted"
      bytes = git_bytes(repository, ["show", "HEAD:#{relative}"], errors, "deleted content")
      mode = head_mode(repository, relative, errors)
      return { "status" => status, "mode" => mode, "hash" => sha256(bytes) }
    end
    path = repository.join(relative)
    bytes = path.symlink? ? path.readlink.to_s.b : path.binread
    { "status" => status, "mode" => filesystem_mode(path), "hash" => sha256(bytes) }
  rescue Errno::ENOENT, Errno::EISDIR
    errors << "dirty path fingerprint를 읽을 수 없습니다: #{relative.inspect}"
    { "status" => status, "mode" => "missing", "hash" => sha256("") }
  end

  def clean_fingerprint(repository, relative, errors)
    unless tracked_at_head?(repository, relative)
      return { "status" => "clean", "mode" => "absent", "hash" => sha256("") }
    end
    bytes = git_bytes(repository, ["show", "HEAD:#{relative}"], errors, "clean content")
    { "status" => "clean", "mode" => head_mode(repository, relative, errors), "hash" => sha256(bytes) }
  end

  def filesystem_mode(path)
    return "120000" if path.symlink?
    path.stat.executable? ? "100755" : "100644"
  end

  def head_mode(repository, relative, errors)
    output = git_bytes(repository, ["ls-tree", "HEAD", "--", relative], errors, "HEAD mode").to_s
    match = output.match(/\A(\d{6})\s/)
    match ? match[1] : "missing"
  end

  def git_head(repository, errors)
    git_bytes(repository, ["rev-parse", "HEAD"], errors, "HEAD OID").to_s.strip
  end

  def git_bytes(repository, arguments, errors, label)
    output, error, status = Open3.capture3("git", "-C", repository.to_s, *arguments)
    errors << "#{label}을 읽을 수 없습니다: #{error.strip}" unless status.success?
    output.b
  end

  def valid_fingerprint?(value)
    value.is_a?(Hash) && FINGERPRINT_STATUSES.include?(value["status"]) && text?(value["mode"]) && value["hash"].is_a?(String) && value["hash"].match?(SHA256)
  end

  def baseline_digest(head_oid, entries)
    "sha256:#{Digest::SHA256.hexdigest(JSON.generate("head_oid" => head_oid, "entries" => canonical(entries)))}"
  end

  def canonical(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |key, result| result[key] = canonical(value[key]) }
    when Array
      value.map { |item| canonical(item) }
    else
      value
    end
  end

  def read_plan(workplan, data)
    errors = []
    paths = %w[code_plan description].map do |role|
      relative = data["detail_documents"].is_a?(Hash) ? data["detail_documents"][role] : nil
      relative ||= "Details/description.md" if role == "description"
      next unless relative
      safe_workplan_detail(workplan, relative, role, errors)
    end.compact
    raise ValidationError, errors.join("\n") unless errors.empty?
    heading = "## 산출물 배치 계획 (`#{SCHEMA}`)"
    paths.each do |path|
      next unless path.file?
      section = WorkplanLayout.markdown_section(path.read(encoding: "UTF-8"), heading)
      next if section.empty?
      fence = section.match(/```ya?ml\s*\n(.*?)\n```/m)
      raise ValidationError, "#{heading} YAML fence 누락" unless fence
      parsed = YAML.safe_load(fence[1], permitted_classes: [], aliases: false) || {}
      packet = parsed["artifact_placement_plan"]
      raise ValidationError, "artifact_placement_plan mapping 누락" unless packet.is_a?(Hash)
      return packet
    end
    raise ValidationError, "산출물 배치 계획 (`#{SCHEMA}`) 섹션 누락"
  end

  def safe_workplan_detail(workplan, relative, role, errors)
    unless safe_relative?(relative) && !git_admin_path?(relative)
      errors << "Workplan detail 경로가 bundle 밖입니다: #{role}=#{relative}"
      return nil
    end
    root = workplan.dirname.realpath
    path = root.join(relative).cleanpath
    if path.symlink? || (path.exist? && !inside?(path.realpath, root))
      errors << "Workplan detail symlink realpath가 bundle 밖입니다: #{role}=#{relative}"
      return nil
    end
    path
  end

  def resolve_repository(raw, errors)
    unless text?(raw)
      errors << "--repository 또는 절대 repository_root가 필요합니다"
      return nil
    end
    root = Pathname(raw).expand_path
    unless root.directory?
      errors << "repository root가 없습니다: #{root}"
      return nil
    end
    root = root.realpath
    output, error, status = Open3.capture3("git", "-C", root.to_s, "rev-parse", "--show-toplevel")
    unless status.success?
      errors << "repository root를 Git 저장소로 확인할 수 없습니다: #{error.strip}"
      return nil
    end
    canonical_root = Pathname(output.strip).realpath
    errors << "지정 repository가 Git root가 아닙니다: #{root}" unless root == canonical_root
    canonical_root
  end

  def validate_repository_realpath(repository, relative, errors, id)
    path = repository.join(relative).cleanpath
    unless inside?(path, repository)
      errors << "#{id}.path가 repository 밖입니다"
      return
    end
    if path.symlink? || (path.exist? && !inside?(path.realpath, repository.realpath))
      errors << "#{id}.path symlink/realpath는 허용하지 않습니다"
    end
  rescue Errno::ENOENT
    errors << "#{id}.path를 확인할 수 없습니다"
  end

  def tracked_at_head?(repository, relative)
    _output, _error, status = Open3.capture3("git", "-C", repository.to_s, "cat-file", "-e", "HEAD:#{relative}")
    status.success?
  end

  def same_realpath?(left, right)
    left.realpath == right.realpath
  rescue Errno::ENOENT
    false
  end

  def document_path?(value)
    segments = value.tr("\\", "/").split("/").map(&:downcase)
    basename = segments.last.to_s
    segments.any? { |segment| %w[docs .codex].include?(segment) } || basename.match?(/\Areadme(?:\..+)?\z/) || segments.any? { |segment| segment.end_with?(".docc") } || basename.match?(/\.(md|mdx|rst|adoc|txt)\z/)
  end

  def git_admin_path?(value)
    segments = value.tr("\\", "/").split("/").map(&:downcase)
    segments.any? { |segment| %w[.git .gitmodules].include?(segment) }
  end

  def safe_relative?(value)
    text?(value) && !Pathname(value).absolute? && !Pathname(value).each_filename.include?("..") && value != "."
  end

  def inside?(path, root)
    relative = path.cleanpath.relative_path_from(root.cleanpath).to_s
    relative != ".." && !relative.start_with?("../")
  rescue ArgumentError
    false
  end

  def sha256(bytes)
    "sha256:#{Digest::SHA256.hexdigest(bytes)}"
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
  abort "usage: artifact-placement-gate.rb validate --phase plan|apply|feedback|completion <Workplan> [--repository ROOT]" unless command == "validate"
  options = {}
  OptionParser.new do |parser|
    parser.on("--phase PHASE") { |value| options[:phase] = value }
    parser.on("--repository ROOT") { |value| options[:repository] = value }
  end.parse!(ARGV)
  abort "Workplan 경로가 필요합니다" unless ARGV.length == 1
  abort "--phase가 필요합니다" unless options[:phase]
  begin
    puts ArtifactPlacementGate.validate(ARGV.first, phase: options[:phase], repository: options[:repository])
  rescue ArtifactPlacementGate::ValidationError => error
    warn error.message
    exit 1
  end
end
