#!/usr/bin/env ruby

require "optparse"
require "open3"
require "pathname"
require "yaml"
require_relative "workplan-layout"

module WorkplanApprovalProjection
  class ProjectionError < StandardError; end

  CURRENT_STATUSES = %w[present new_file deletion].freeze

  module_function

  def project(workplan_path, kind:, repository: nil, verify_current: false)
    workplan = Pathname(workplan_path).expand_path
    raise ProjectionError, "Workplan이 없습니다: #{workplan}" unless workplan.file?
    raise ProjectionError, "--verify-current에는 --repository가 필요합니다" if verify_current && repository.to_s.strip.empty?

    _raw, frontmatter = WorkplanLayout.frontmatter(workplan.read(encoding: "UTF-8"))
    documents = WorkplanLayout.detail_documents(workplan, frontmatter)
    code_path = documents["code_plan"] || documents["description"]
    raise ProjectionError, "code plan 문서가 없습니다" unless code_path&.file?
    code_text = code_path.read(encoding: "UTF-8")

    entries = case kind
              when "feature" then feature_entries(code_text)
              when "bug" then bug_entries(code_text)
              else raise ProjectionError, "--kind는 feature 또는 bug여야 합니다"
              end
    raise ProjectionError, "투영할 CODE mapping이 없습니다" if entries.empty?

    repository_path = Pathname(repository).expand_path if repository
    repository_path = verified_git_root(repository_path) if verify_current
    entries.each { |entry| verify_entry(entry, repository_path) } if verify_current
    render(
      frontmatter["id"] || workplan.basename(".md").to_s,
      kind,
      entries,
      repository_path,
      verify_current: verify_current
    )
  rescue KeyError, Psych::SyntaxError => error
    raise ProjectionError, "승인 투영 mapping을 해석할 수 없습니다: #{error.message}"
  end

  def feature_entries(text)
    packet = yaml_packet(text, "## 기능 구현 매핑 (`feature-plan-completeness-v1`)", "feature_plan")
    changes = packet.fetch("code_changes")
    tests = packet.fetch("tests")
    raise ProjectionError, "feature code_changes가 비어 있습니다" unless changes.is_a?(Hash) && !changes.empty?
    raise ProjectionError, "feature tests mapping 불일치" unless tests.is_a?(Hash)

    sorted_code_ids(changes.keys).map do |code_id|
      item = changes.fetch(code_id)
      raise ProjectionError, "#{code_id} mapping 불일치" unless item.is_a?(Hash)
      status = item.fetch("current_code_status", "present")
      ensure_status(code_id, status)
      covered_test_ids = tests.each_with_object([]) do |(test_id, test), ids|
        ids << test_id if test.is_a?(Hash) && Array(test["covers"]).map(&:to_s).include?(code_id.to_s)
      end
      legacy_test_ids = required_text_list(item["tests"], "#{code_id}.tests") if item.key?("tests")
      has_canonical_covers = tests.any? { |_test_id, test| test.is_a?(Hash) && test.key?("covers") }
      test_ids = has_canonical_covers ? required_text_list(covered_test_ids, "TEST.covers for #{code_id}") : legacy_test_ids
      test_ids = required_text_list(test_ids, "TEST.covers for #{code_id}")
      if has_canonical_covers && legacy_test_ids && legacy_test_ids.uniq.sort != test_ids.uniq.sort
        raise ProjectionError, "#{code_id}.tests가 canonical TEST.covers의 reverse edge 집합과 다릅니다"
      end
      test_lines = test_ids.map do |test_id|
        test = tests[test_id]
        raise ProjectionError, "#{code_id}의 알 수 없는 test: #{test_id}" unless test.is_a?(Hash)
        verification_description(test_id, test)
      end
      if test_ids.all? { |test_id| tests.fetch(test_id)["verification_kind"] == "static_review" } &&
         test_ids.any? { |test_id| !not_applicable_reason?(tests.fetch(test_id)["executable_not_applicable"]) }
        raise ProjectionError, "#{code_id}의 static_review는 실행 가능한 행동 검증을 대체할 수 없습니다"
      end
      {
        id: code_id,
        concept: require_text(item["design_concept"], "#{code_id}.design_concept"),
        file: require_text(item["file"], "#{code_id}.file"),
        symbol: require_text(item["symbol"], "#{code_id}.symbol"),
        current_file: item["current_code_file"] || item["file"],
        current_file_explicit: item.key?("current_code_file"),
        current_status: status,
        current: code_section(text, item["current_code"], "#{code_id}.current_code"),
        proposed: code_section(text, item["proposed_code"], "#{code_id}.proposed_code"),
        caller: require_text(content_section(text, item["caller_assembly"], "#{code_id}.caller_assembly"), "#{code_id}.caller_assembly"),
        preserved: required_text_list(item["preserved_contracts"], "#{code_id}.preserved_contracts"),
        verification: test_lines,
        existing_tests: test_ids.each_with_object([]) do |test_id, result|
          test = tests.fetch(test_id)
          result << [test_id, test] if test["verification_kind"] == "existing_test"
        end
      }
    end
  end

  def bug_entries(text)
    code_ids = text.scan(/^### (CODE-\d+) 설계 개념\s*$/).flatten.uniq
    sorted_code_ids(code_ids).map do |code_id|
      target = yaml_section(text, "#{code_id} Target")
      status = target.fetch("current_code_status", "present")
      ensure_status(code_id, status)
      {
        id: code_id,
        concept: plain_section(text, "#{code_id} 설계 개념"),
        file: require_text(target["file"], "#{code_id}.file"),
        symbol: require_text(target["symbol"], "#{code_id}.symbol"),
        current_file: target["current_code_file"] || target["file"],
        current_file_explicit: target.key?("current_code_file"),
        current_status: status,
        current: code_section(text, "#{code_id} 현재 코드", "#{code_id} 현재 코드"),
        proposed: code_section(text, "#{code_id} 제안 코드", "#{code_id} 제안 코드"),
        caller: require_text(content_section(text, "#{code_id} Caller/assembly", "#{code_id} Caller/assembly"), "#{code_id} Caller/assembly"),
        preserved: list_section(text, "#{code_id} 유지 계약"),
        verification: list_section(text, "#{code_id} 검증")
      }
    end
  end

  def yaml_packet(text, heading, root)
    section = WorkplanLayout.markdown_section(text, heading)
    raise ProjectionError, "#{heading} 섹션 누락" if section.empty?
    fenced = section.match(/```ya?ml\s*\n(.*?)\n```/m)
    raise ProjectionError, "#{heading} YAML fence 누락" unless fenced
    parsed = YAML.safe_load(fenced[1], permitted_classes: [], aliases: false) || {}
    mapping = parsed[root]
    raise ProjectionError, "#{heading}의 #{root} mapping 누락" unless mapping.is_a?(Hash)
    mapping
  end

  def yaml_section(text, label)
    section = content_section(text, label, label)
    fenced = section.match(/```ya?ml\s*\n(.*?)\n```/m)
    raise ProjectionError, "#{label} YAML fence 누락" unless fenced
    parsed = YAML.safe_load(fenced[1], permitted_classes: [], aliases: false) || {}
    raise ProjectionError, "#{label} YAML mapping 불일치" unless parsed.is_a?(Hash)
    parsed
  end

  def code_section(text, reference, label)
    section = content_section(text, reference, label)
    fenced = section.match(/```([A-Za-z0-9_+.#-]+)\s*\n(.*?)\n```/m)
    raise ProjectionError, "#{label}에 language tag가 있는 code fence가 필요합니다" unless fenced && !fenced[2].strip.empty?
    { language: fenced[1], code: fenced[2].strip }
  end

  def content_section(text, reference, label)
    heading = reference.to_s.sub(/\A#+\s*/, "")
    raise ProjectionError, "#{label} reference 누락" if heading.strip.empty?
    section = WorkplanLayout.markdown_section(text, "### #{heading}")
    raise ProjectionError, "### #{heading} 섹션 누락" if section.empty?
    section.sub(/\A###\s+#{Regexp.escape(heading)}\s*\n?/, "").strip
  end

  def plain_section(text, label)
    value = content_section(text, label, label)
    require_text(value, label)
  end

  def list_section(text, label)
    content = content_section(text, label, label)
    values = content.lines.each_with_object([]) do |line, result|
      value = line[/^\s*-\s+(.+?)\s*$/, 1]
      result << value if value
    end
    raise ProjectionError, "#{label}에 항목이 필요합니다" if values.empty?
    values
  end

  def verify_entry(entry, repository)
    raise ProjectionError, "repository가 일반 directory가 아닙니다: #{repository}" unless repository&.directory?
    target = safe_repository_path(repository, entry[:file])
    current_path = safe_repository_path(repository, entry[:current_file])
    if entry[:current_status] == "new_file"
      raise ProjectionError, "#{entry[:id]} new_file target이 이미 존재합니다: #{target}" if target.exist?
      unless entry[:current_file_explicit] && entry[:current_file] != entry[:file]
        raise ProjectionError, "#{entry[:id]} new_file은 실제 caller/insertion anchor의 current_code_file이 필요합니다"
      end
    end

    raise ProjectionError, "#{entry[:id]} current code 파일이 없습니다: #{current_path}" unless current_path.file?
    actual = current_path.read(encoding: "UTF-8")
    snippet = entry[:current][:code]
    raise ProjectionError, "#{entry[:id]} current code가 현재 worktree 파일과 다릅니다: #{entry[:current_file]}" unless actual.include?(snippet)
    Array(entry[:existing_tests]).each do |test_id, test|
      verify_existing_test(test_id, test, repository)
    end
  end

  def verification_description(test_id, test)
    kind = test["verification_kind"].to_s
    if kind.empty?
      file = require_text(test["file"], "#{test_id}.file")
      identifier = require_text(test["identifier"], "#{test_id}.identifier")
      command = require_text(test["command"], "#{test_id}.command")
      return "#{test_id}: #{file}##{identifier} — `#{command}`"
    end
    unless %w[existing_test static_review].include?(kind)
      raise ProjectionError, "#{test_id}.verification_kind는 existing_test 또는 static_review여야 합니다"
    end
    common = %w[change failure_risk method pass_criterion].to_h do |field|
      [field, require_text(test[field], "#{test_id}.#{field}")]
    end
    if test.key?("test_code") || test.key?("test_not_applicable")
      raise ProjectionError, "#{test_id}.#{kind}는 test_code/test_not_applicable을 사용하지 않습니다"
    end

    if kind == "existing_test"
      file = require_text(test["file"], "#{test_id}.file")
      identifier = require_text(test["identifier"], "#{test_id}.identifier")
      command = require_text(test["command"], "#{test_id}.command")
      "#{test_id} existing_test (소스 참조, 미실행): #{file}##{identifier} — `#{command}`; risk: #{common['failure_risk']}; pass: #{common['pass_criterion']}"
    else
      review_type = require_text(test["review_type"], "#{test_id}.review_type")
      unless %w[source_review visual_review static_analysis].include?(review_type)
        raise ProjectionError, "#{test_id}.review_type은 source_review, visual_review, static_analysis 중 하나여야 합니다"
      end
      expectation = require_text(test["independent_expectation"], "#{test_id}.independent_expectation")
      scope = require_text(test["scope"], "#{test_id}.scope")
      applicability = require_text(test["applicability_reason"], "#{test_id}.applicability_reason")
      executable_na = test["executable_not_applicable"]
      if test.key?("executable_not_applicable") && !not_applicable_reason?(executable_na)
        raise ProjectionError, "#{test_id}.executable_not_applicable은 not_applicable: <구체적 이유> 형식이어야 합니다"
      end
      waiver = test.key?("executable_not_applicable") ? "; executable: #{executable_na.strip}" : ""
      "#{test_id} static_review (미실행): #{review_type}; scope: #{scope}; expectation: #{expectation}; applicability: #{applicability}#{waiver}; risk: #{common['failure_risk']}; pass: #{common['pass_criterion']}"
    end
  end

  def verify_existing_test(test_id, test, repository)
    relative = require_text(test["file"], "#{test_id}.file")
    unless relative.split(/[\\\/]/).any? { |part| part.match?(/tests?/i) }
      raise ProjectionError, "#{test_id}.file은 test source 경로여야 합니다: #{relative}"
    end
    path = safe_repository_path(repository, relative)
    raise ProjectionError, "#{test_id}.file이 현재 repository에 없습니다: #{relative}" unless path.file?
    real_inside = path.realpath.relative_path_from(repository.realpath).to_s
    if real_inside == ".." || real_inside.start_with?("../")
      raise ProjectionError, "#{test_id}.file symlink realpath이 repository 밖입니다: #{relative}"
    end
    identifier = require_text(test["identifier"], "#{test_id}.identifier")
    source = path.read(encoding: "UTF-8")
    unless source.include?(identifier)
      raise ProjectionError, "#{test_id}.identifier가 현재 test source에 문자열 그대로 없습니다: #{identifier}"
    end
  end

  def verified_git_root(repository)
    raise ProjectionError, "repository가 일반 directory가 아닙니다: #{repository}" unless repository&.directory?
    output, error, status = Open3.capture3("git", "-C", repository.to_s, "rev-parse", "--show-toplevel")
    raise ProjectionError, "repository가 Git worktree가 아닙니다: #{error.strip}" unless status.success?
    root = Pathname(output.strip).realpath
    raise ProjectionError, "--repository는 Git worktree root여야 합니다: #{repository}" unless root == repository.realpath
    root
  end

  def safe_repository_path(repository, relative)
    path = repository.join(relative.to_s).cleanpath
    inside = path.relative_path_from(repository.cleanpath).to_s
    raise ProjectionError, "repository 밖 경로입니다: #{relative}" if inside == ".." || inside.start_with?("../")
    path
  rescue ArgumentError
    raise ProjectionError, "repository 밖 경로입니다: #{relative}"
  end

  def render(id, kind, entries, repository, verify_current:)
    verification = if verify_current
                     "Git worktree root `#{repository}`의 현재 파일에서 현재 snippet과 선언된 existing-test source/identifier 문자열을 대조"
                   elsif repository
                     "미실행 (--repository만 지정됨; --verify-current 필요)"
                   else
                     "미실행"
                   end
    lines = ["# #{id} 승인 구현 투영", "", "- 종류: #{kind}", "- 현재 코드 대조: #{verification}"]
    lines << "- 검증 한계: 제안 코드는 컴파일하거나 의미적으로 검증하지 않았습니다."
    entries.each do |entry|
      status_detail = entry[:current_status] == "deletion" ? " (삭제 전 코드 대조; 삭제 후 caller/대체 경로는 제안 코드로 설명)" : ""
      lines.concat(["", "## #{entry[:id]} — #{entry[:concept]}", "", "- 대상: `#{entry[:file]}##{entry[:symbol]}`", "- 현재 상태: `#{entry[:current_status]}`#{status_detail}", "", "### 현재 코드", "", "```#{entry[:current][:language]}", entry[:current][:code], "```", "", "### 제안 코드", "", "```#{entry[:proposed][:language]}", entry[:proposed][:code], "```", "", "### Caller / assembly", "", entry[:caller], "", "### 유지 계약", ""])
      lines.concat(entry[:preserved].map { |value| "- #{value}" })
      lines.concat(["", "### 검증", ""])
      lines.concat(entry[:verification].map { |value| "- #{value}" })
    end
    lines.join("\n") + "\n"
  end

  def sorted_code_ids(ids)
    ids.map(&:to_s).sort_by { |id| [id[/\d+/].to_i, id] }
  end

  def ensure_status(code_id, status)
    raise ProjectionError, "#{code_id}.current_code_status 불일치" unless CURRENT_STATUSES.include?(status)
  end

  def require_text(value, label)
    raise ProjectionError, "#{label}는 비어 있지 않은 문자열이어야 합니다" unless value.is_a?(String) && !value.strip.empty?
    value.strip
  end

  def required_text_list(value, label)
    raise ProjectionError, "#{label}에 항목이 필요합니다" unless value.is_a?(Array) && !value.empty?
    value.map { |item| require_text(item, label) }
  end

  def not_applicable_reason?(value)
    value.is_a?(String) && value.strip.match?(/\Anot_applicable\s*:\s*\S.+/)
  end
end

if $PROGRAM_NAME == __FILE__
  options = { verify_current: false }
  parser = OptionParser.new do |config|
    config.banner = "Usage: workplan-approval-projection --kind feature|bug [--repository PATH --verify-current] WORKPLAN"
    config.on("--kind KIND") { |value| options[:kind] = value }
    config.on("--repository PATH") { |value| options[:repository] = value }
    config.on("--verify-current") { options[:verify_current] = true }
  end
  parser.parse!
  abort parser.to_s unless ARGV.length == 1 && options[:kind]

  begin
    print WorkplanApprovalProjection.project(ARGV.fetch(0), **options)
  rescue WorkplanApprovalProjection::ProjectionError => error
    warn "ERROR: #{error.message}"
    exit 1
  end
end
