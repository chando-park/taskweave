#!/usr/bin/env ruby

require "digest"
require "optparse"
require "pathname"
require "yaml"
require_relative "workplan-layout"
require_relative "workplan-memo"

def validate_approval_memo(main, repository_root, errors)
  workplan, data, body = WorkplanMemo.load_memo(main)
  repository = WorkplanMemo.matching_repository!(data, repository_root)
  WorkplanMemo.validate_memo_content!(data, body, repository, verify_before: false)
  preparation = WorkplanMemo.load_preparation(workplan, data)
  WorkplanMemo.validate_repository_identity!(preparation.fetch("repository_identity"), repository)
  WorkplanMemo.validate_approval!(workplan, data) unless data["approval_revision"].to_s.empty?

  if %w[verifying verification_blocked awaiting_completion completed].include?(data["status"])
    completion = workplan.dirname.join(data["completion_result"] || WorkplanMemo::COMPLETION_RELATIVE)
    raise WorkplanMemo::ValidationError, "Completion.md가 없습니다" unless completion.file?
    WorkplanMemo.result_packet(completion)
  end
rescue WorkplanMemo::ValidationError, KeyError, JSON::ParserError => error
  errors << "approval memo 불일치: #{main}: #{error.message}"
end

def legacy_compact_record?(main, data)
  data["workplan_schema"].to_s.empty? &&
    data["workplan_layout"].to_s.empty? &&
    %w[awaiting_completion completed].include?(data["status"]) &&
    main.dirname.join("Completion.md").file?
end

def completed_historical_bundle?(data)
  data["workplan_layout"] == WorkplanLayout::LAYOUT &&
    data["status"] == "completed" &&
    data["authority_status"] == "historical_record"
end

options = {}
OptionParser.new do |parser|
  parser.on("--root PATH") { |value| options[:root] = value }
  parser.on("--repository-root PATH") { |value| options[:repository_root] = value }
  parser.on("--project-id ID") { |value| options[:project_id] = value }
end.parse!

begin
  root = Pathname(options.fetch(:root)).expand_path
  repository_root = Pathname(options.fetch(:repository_root) { Pathname(__dir__).join("../../..").realpath }).expand_path
  errors = []
  runtime_root = repository_root.join("20_AI/Codex/Runtime")
  expected_project_id = options.fetch(:project_id, root.basename.to_s)
  marker_file = runtime_root.join("references/personal-runtime-domain-markers.yml")
  marker_data = marker_file.file? ? YAML.safe_load(marker_file.read(encoding: "UTF-8"), permitted_classes: [], aliases: false) : {}
  markers = Array(marker_data.is_a?(Hash) ? marker_data["markers"] : []).map(&:to_s).reject(&:empty?)
  markers.each do |marker|
    runtime_root.glob("**/*").select { |path| path.file? && %w[.md .rb .yaml .yml].include?(path.extname) }.each do |path|
      next if path == marker_file
      errors << "개인 Runtime domain marker 누출: #{path}: #{marker}" if path.read(encoding: "UTF-8").include?(marker)
    end
  end
  legacy = root.children.select { |path| path.file? && path.extname == ".md" && path.basename.to_s != "README.md" }
  errors.concat(legacy.map { |path| "legacy flat Workplan: #{path}" })
  %w[Active Waiting Completed].each do |state|
    root.glob("#{state}/**/*.md").each { |path| errors << "구형 상태 경로 Workplan: #{path}" if path.basename(".md").to_s == path.dirname.basename.to_s }
  end
  mains = root.glob("*/*.md").select do |path|
    !path.each_filename.include?("Evidence") && path.basename(".md").to_s == path.dirname.basename.to_s
  end
  ids = Hash.new { |hash, key| hash[key] = [] }

  mains.each do |main|
    text = main.read(encoding: "UTF-8")
    _raw, data = WorkplanLayout.frontmatter(text)
    id = data.fetch("id")
    ids[id] << main
    errors << "project_id와 project root 불일치: #{main}: #{data['project_id'].inspect} != #{expected_project_id}" unless data["project_id"] == expected_project_id
    expected = WorkplanLayout.bundle_directory(root, data).join("#{id}.md")
    errors << "고정 bundle 경로 불일치: #{main} != #{expected}" unless main == expected
    if data["workplan_schema"] == WorkplanLayout::APPROVAL_MEMO_SCHEMA
      validate_approval_memo(main, repository_root, errors)
      next
    end
    if legacy_compact_record?(main, data)
      next
    end
    if completed_historical_bundle?(data)
      Array(data["runtime_targets"]).each do |target|
        errors << "존재하지 않는 Runtime target: #{main}: #{target}" unless repository_root.join(target).file?
      end
      next
    end
    errors << "workplan_layout 누락: #{main}" unless data["workplan_layout"] == WorkplanLayout::LAYOUT
    details = main.dirname.join("Details")
    evidence = main.dirname.join("Evidence")
    legacy_bundle = evidence.directory?
    authority = data["authority_status"]
    runtime_targets = Array(data["runtime_targets"])
    status = data.fetch("status")
    WorkplanLayout.detail_document_errors(main, data).each do |error|
      errors << "상세 문서 계약 불일치: #{main}: #{error}"
    end
    detail_documents = WorkplanLayout.detail_documents(main, data)
    WorkplanLayout.lifecycle_timestamp_errors(data).each do |error|
      errors << "수명주기 시각 불일치: #{main}: #{error}"
    end
    WorkplanLayout.architecture_context_errors(data).each do |error|
      errors << "아키텍처 게이트 위반: #{main}: #{error}"
    end
    WorkplanLayout.principle_context_errors(data).each do |error|
      errors << "원칙 context 위반: #{main}: #{error}"
    end
    expected_authority = WorkplanLayout::COMPLETED.include?(status) ? "historical_record" : "proposal"
    errors << "authority_status 불일치: #{main}: #{authority.inspect} != #{expected_authority}" unless authority == expected_authority
    if status == "completed" && data["project_id"] == "personal-ai-system" && runtime_targets.empty?
      errors << "완료된 개인 Runtime Workplan의 runtime_targets 누락: #{main}"
    end
    runtime_targets.each do |target|
      next unless authority == "historical_record"
      errors << "존재하지 않는 Runtime target: #{main}: #{target}" unless repository_root.join(target).file?
    end
    if details.directory?
      if WorkplanLayout.description_required?(data) && !details.join("description.md").file?
        errors << "작업 설명 누락: #{details.join('description.md')}"
      end
      errors << "구형 Evidence와 Details가 공존함: #{main}" if legacy_bundle
      text.scan(/\]\((Details\/[^)]+)\)/).flatten.each do |relative|
        errors << "존재하지 않는 상세 링크: #{main}: #{relative}" unless main.dirname.join(relative).file?
      end
      change = details.join("change.md").file? ? details.join("change.md").read(encoding: "UTF-8") : ""
      if id.start_with?("FEATURE-") && details.join("change.md").file?
        errors << "핵심 추가 코드 근거 누락: #{main}" unless change.include?("핵심 추가 코드")
      elsif id.start_with?("BUG-") && details.join("change.md").file?
        errors << "변경 전 코드 근거 누락: #{main}" unless change.include?("## 변경 전")
        errors << "변경 후 코드 근거 누락: #{main}" unless change.include?("## 변경 후")
      end
      if data["legacy_original_sha256"]
        description = details.join("description.md").read(encoding: "UTF-8")
        start_marker = "<!-- legacy-original:start -->\n"
        end_marker = "<!-- legacy-original:end -->"
        begin
          original = description.split(start_marker, 2).fetch(1).split(end_marker, 2).fetch(0)
          actual = Digest::SHA256.hexdigest(original)
          errors << "보존된 legacy 원문 hash 불일치: #{main}" unless actual == data["legacy_original_sha256"]
        rescue IndexError
          errors << "보존된 legacy 원문 marker 누락: #{main}"
        end
      end
      if WorkplanLayout.plan_code_contract_required?(data) && (id.start_with?("BUG-") || id.start_with?("FEATURE-"))
        plan_evidence = data["plan_code_evidence"]
        errors << "계획 코드 근거 판정 누락: #{main}" unless %w[required not_applicable].include?(plan_evidence)
        description = details.join("description.md").file? ? details.join("description.md").read(encoding: "UTF-8") : ""
        unless WorkplanLayout.plan_code_before_after_required?(data) || data["plan_code_evidence_schema"]
          errors << "계획 코드 근거 섹션 누락: #{main}" unless description.include?("## 계획 코드 근거")
        end
      end
      if id.start_with?("BUG-") || id.start_with?("FEATURE-")
        code_plan = detail_documents.fetch("code_plan", detail_documents["description"])
        code_plan_text = code_plan&.file? ? code_plan.read(encoding: "UTF-8") : ""
        WorkplanLayout.plan_code_evidence_errors(data, code_plan_text).each do |error|
          errors << "계획 코드 근거 불일치: #{main}: #{error}"
        end
      end
    elsif legacy_bundle
      errors << "구형 Evidence bundle: #{main}"
    else
      errors << "Details 누락: #{main}"
    end
    nonblank_body = text.sub(/\A---\s*\n.*?\n---\s*\n/m, "").lines.reject { |line| line.strip.empty? }.size
    errors << "기본 Workplan 60줄 초과: #{main} (#{nonblank_body})" if nonblank_body > 60
    body = text.sub(/\A---\s*\n.*?\n---\s*\n/m, "")
    errors << "기본 Workplan 코드 근거 배치 오류: #{main}" if body.include?("```")
    basis = data["approval_basis"]
    errors << "approval basis 누락: #{main}" if basis && !main.dirname.join(basis).file?
  rescue KeyError, RuntimeError => error
    errors << "#{main}: #{error.message}"
  end

  ids.each { |id, paths| errors << "ID 중복: #{id}: #{paths.join(', ')}" if paths.size > 1 }
  repository_root.join("20_AI").glob("**/*.md").reject { |path| path.to_s.start_with?(root.to_s + File::SEPARATOR) }.each do |path|
    path.read(encoding: "UTF-8").scan(%r{Workplans/(?:Active|Waiting|Completed)/[^\s\])]+}).each do |legacy_path|
      errors << "구형 Workplan inbound 경로: #{path}: #{legacy_path}"
    end
  end
  if errors.empty?
    puts "OK: #{mains.size} Workplan bundles"
  else
    warn errors.join("\n")
    exit 1
  end
rescue KeyError, Errno::ENOENT => error
  warn error.message
  exit 1
end
