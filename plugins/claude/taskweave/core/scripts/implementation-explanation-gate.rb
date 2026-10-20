#!/usr/bin/env ruby

require "open3"
require "optparse"
require "pathname"
require "yaml"
require_relative "workplan-layout"

module ImplementationExplanationGate
  class ValidationError < StandardError; end

  SCHEMA = "implementation-explanation-v1"
  SOURCE_EXTENSIONS = %w[.swift .m .mm .h .hpp .c .cc .cpp .kt .kts .java .js .jsx .ts .tsx .rb .py .go .rs].freeze
  KINDS = { "features" => "feature", "bugs" => "bug" }.freeze

  module_function

  def validate(workplan, repository:)
    workplan = Pathname(workplan).expand_path
    repository = Pathname(repository).expand_path
    raise ValidationError, "Workplan이 없습니다: #{workplan}" unless workplan.file?
    raise ValidationError, "Git 저장소가 아닙니다: #{repository}" unless repository.join(".git").exist?
    repository = repository.realpath

    _raw, data = WorkplanLayout.frontmatter(workplan.read(encoding: "UTF-8"))
    if WorkplanLayout.approval_memo?(data)
      require_relative "workplan-memo"
      begin
        return WorkplanMemo.validate_implementation_explanation(workplan, repository: repository)
      rescue WorkplanMemo::ValidationError => error
        raise ValidationError, error.message
      end
    end
    expected_kind = KINDS[data["workplan_kind"]]
    return "Implementation explanation gate valid: not applicable" unless expected_kind

    change_path = detail_path(workplan, data, "change")
    raise ValidationError, "Details/change.md 연결이 없습니다" unless change_path&.file?

    packet = explanation_packet(change_path.read(encoding: "UTF-8"))
    errors = []
    errors << "implementation explanation schema 불일치" unless packet["schema"] == SCHEMA
    errors << "implementation kind 불일치: #{packet['kind'].inspect}" unless packet["kind"] == expected_kind
    base_revision = packet["base_revision"]
    result_revision = packet["result_revision"]
    errors << "base_revision은 구현 시작 Git commit이어야 합니다" unless git_revision?(repository, base_revision)
    unless result_revision == "WORKTREE" || git_revision?(repository, result_revision)
      errors << "result_revision은 WORKTREE 또는 구현 결과 Git commit이어야 합니다"
    end

    entries = packet["entries"]
    unless entries.is_a?(Hash) && !entries.empty?
      errors << "implementation explanation entries가 비어 있습니다"
      entries = {}
    end

    planned_code_ids(workplan, data).each do |id|
      errors << "승인 계획 CODE 설명 누락: #{id}" unless entries.key?(id)
    end

    covered = []
    entries.each do |id, entry|
      validate_entry(id, entry, expected_kind, change_path.read(encoding: "UTF-8"), repository, base_revision, result_revision, errors)
      covered.concat(Array(entry["files"]).map(&:to_s)) if entry.is_a?(Hash)
    end

    exclusions = packet["excluded_files"] || {}
    unless exclusions.is_a?(Hash)
      errors << "excluded_files는 path→reason mapping이어야 합니다"
      exclusions = {}
    end
    exclusions.each do |path, reason|
      errors << "excluded_files 사유 누락: #{path}" unless text?(reason)
    end

    changed = changed_source_files(repository, base_revision, result_revision)
    declared = (covered + exclusions.keys.map(&:to_s)).uniq
    (changed - declared).each { |path| errors << "실제 변경 코드 설명 누락: #{path}" }
    (declared - changed).each { |path| errors << "실제 diff에 없는 코드 파일을 설명했습니다: #{path}" }
    errors << "실제 변경 코드가 없습니다" if changed.empty?

    raise ValidationError, errors.join("\n") unless errors.empty?
    "Implementation explanation gate valid: #{entries.size} entries, #{changed.size} files"
  rescue Psych::SyntaxError => error
    raise ValidationError, "implementation explanation packet을 해석할 수 없습니다: #{error.message}"
  end

  def validate_entry(id, entry, kind, markdown, repository, base_revision, result_revision, errors)
    unless id.to_s.match?(/\ACODE-\d+\z/) && entry.is_a?(Hash)
      errors << "CODE ID 또는 entry 불일치: #{id}"
      return
    end
    files = entry["files"]
    errors << "#{id}.files는 비어 있지 않은 상대 경로 배열이어야 합니다" unless string_list?(files) && files.all? { |path| safe_relative?(path) }
    %w[symbol intent callers tests].each do |field|
      value = entry[field]
      valid = %w[callers tests].include?(field) ? string_list?(value) : text?(value)
      errors << "#{id}.#{field} 누락 또는 타입 불일치" unless valid
    end

    primary = entry["primary_file"]
    errors << "#{id}.primary_file은 files 중 하나여야 합니다" unless text?(primary) && Array(files).include?(primary)
    if kind == "feature"
      validate_snippet(id, "최종 코드", entry["final_code"], markdown, repository.join(primary.to_s), errors, revision: result_revision)
      flow = entry["flow"]
      errors << "#{id}.flow는 State/Action/Effect/Delegate/Flow·조립 설명 또는 not_applicable 사유가 필요합니다" unless flow.is_a?(Hash) && flow.values.any? { |value| text?(value) }
    else
      validate_snippet(id, "변경 전", entry["before_code"], markdown, repository.join(primary.to_s), errors, revision: base_revision)
      validate_snippet(id, "변경 후", entry["after_code"], markdown, repository.join(primary.to_s), errors, revision: result_revision)
      errors << "#{id}.preserved_behavior 누락" unless text?(entry["preserved_behavior"])
    end
  end

  def validate_snippet(id, label, reference, markdown, path, errors, revision:)
    expected = "#{id} #{label}"
    unless reference == expected
      errors << "#{id} #{label} 참조는 #{expected.inspect}여야 합니다"
      return
    end
    section = WorkplanLayout.markdown_section(markdown, "### #{expected}")
    match = section.match(/```[^\n]*\n(.+?)```/m)
    unless match
      errors << "#{expected} code fence 누락"
      return
    end
    snippet = normalize(match[1])
    source = revision == "WORKTREE" ? (path.file? ? path.read(encoding: "UTF-8") : "") : git_show(path, revision, errors)
    suffix = revision == "WORKTREE" ? "현재 파일과" : "#{revision} 코드와"
    errors << "#{expected}가 실제 #{suffix} 일치하지 않습니다" unless normalize(source).include?(snippet)
  end

  def changed_source_files(repository, base_revision, result_revision)
    target = result_revision == "WORKTREE" ? nil : result_revision
    args = ["git", "-C", repository.to_s, "diff", "--name-only", "--diff-filter=ACMRTUXB", base_revision]
    args << target if target
    args << "--"
    tracked, error, status = Open3.capture3(*args)
    raise ValidationError, "Git diff 조회 실패: #{error.strip}" unless status.success?
    untracked_lines = []
    if result_revision == "WORKTREE"
      untracked, error, status = Open3.capture3("git", "-C", repository.to_s, "ls-files", "--others", "--exclude-standard")
      raise ValidationError, "untracked 조회 실패: #{error.strip}" unless status.success?
      untracked_lines = untracked.lines
    end
    (tracked.lines + untracked_lines).map(&:strip).reject(&:empty?).select { |path| SOURCE_EXTENSIONS.include?(File.extname(path).downcase) }.uniq.sort
  end

  def git_show(path, revision, errors)
    repository = git_root(path)
    relative = path.relative_path_from(repository).to_s
    output, _error, status = Open3.capture3("git", "-C", repository.to_s, "show", "#{revision}:#{relative}")
    return output if status.success?
    errors << "#{revision}에서 파일을 읽을 수 없습니다: #{relative}"
    ""
  end

  def git_revision?(repository, value)
    return false unless text?(value) && value != "WORKTREE"
    _output, _error, status = Open3.capture3("git", "-C", repository.to_s, "rev-parse", "--verify", "#{value}^{commit}")
    status.success?
  end

  def git_root(path)
    output, error, status = Open3.capture3("git", "-C", path.dirname.to_s, "rev-parse", "--show-toplevel")
    raise ValidationError, "Git root 조회 실패: #{error.strip}" unless status.success?
    Pathname(output.strip)
  end

  def detail_path(workplan, data, role)
    relative = data.fetch("detail_documents", {})[role]
    return unless relative.is_a?(String)
    path = workplan.dirname.join(relative).cleanpath
    return unless path.to_s.start_with?(workplan.dirname.to_s + File::SEPARATOR)
    path
  end

  def planned_code_ids(workplan, data)
    return [] unless data["plan_code_evidence"] == "required"

    path = detail_path(workplan, data, "code_plan") || detail_path(workplan, data, "description")
    return [] unless path&.file?

    path.read(encoding: "UTF-8").scan(/^### (CODE-\d+) (?:현재|제안) 코드\s*$/).flatten.uniq.sort
  end

  def explanation_packet(markdown)
    match = markdown.match(/```yaml\s+implementation-explanation\s*\n(.+?)```/m)
    raise ValidationError, "implementation-explanation YAML block이 없습니다" unless match
    YAML.safe_load(match[1], permitted_classes: [], aliases: false) || {}
  end

  def normalize(text)
    text.to_s.lines.map(&:rstrip).reject { |line| line.strip.empty? }.join("\n").strip
  end

  def text?(value)
    value.is_a?(String) && !value.strip.empty?
  end

  def string_list?(value)
    value.is_a?(Array) && !value.empty? && value.all? { |item| text?(item) }
  end
  def safe_relative?(value)
    return false unless text?(value)
    path = Pathname(value)
    !path.absolute? && !path.each_filename.to_a.include?("..")
  end

  def extract(repository:, path:, start_line:, end_line:, base_revision: nil)
    repository = Pathname(repository).expand_path
    raise ValidationError, "Git 저장소가 아닙니다: #{repository}" unless repository.join(".git").exist?
    repository = repository.realpath
    raise ValidationError, "path는 저장소 상대 경로여야 합니다" unless safe_relative?(path)
    raise ValidationError, "line bounds는 양의 정수여야 합니다" unless start_line.is_a?(Integer) && end_line.is_a?(Integer) && start_line.positive? && end_line >= start_line
    relative = Pathname(path).cleanpath.to_s
    source = if base_revision
               raise ValidationError, "base revision이 Git commit이 아닙니다" unless git_revision?(repository, base_revision)
               output, _error, status = Open3.capture3("git", "-C", repository.to_s, "show", "#{base_revision}:#{relative}")
               raise ValidationError, "base revision에서 파일을 읽을 수 없습니다: #{relative}" unless status.success?
               output
             else
               target = repository.join(relative)
               raise ValidationError, "현재 파일을 읽을 수 없습니다: #{relative}" unless target.file?
               resolved = target.realpath
               raise ValidationError, "현재 파일이 저장소를 벗어납니다: #{relative}" unless resolved.to_s.start_with?(repository.to_s + File::SEPARATOR)
               resolved.read(encoding: "UTF-8")
             end
    lines = source.lines
    raise ValidationError, "line bounds가 파일 범위를 벗어났습니다: #{start_line}-#{end_line}" if end_line > lines.length
    lines[(start_line - 1)..(end_line - 1)].join
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |opts|
    opts.on("--repository ROOT") { |value| options[:repository] = value }
    opts.on("--path PATH") { |value| options[:path] = value }
    opts.on("--start-line LINE", Integer) { |value| options[:start_line] = value }
    opts.on("--end-line LINE", Integer) { |value| options[:end_line] = value }
    opts.on("--base-revision REVISION") { |value| options[:base_revision] = value }
  end
  parser.parse!
  command = ARGV.shift
  begin
    if command == "validate"
      workplan = ARGV.shift
      abort "usage: implementation-explanation-gate.rb validate --repository ROOT <Workplan>" unless workplan && ARGV.empty? && options[:repository]
      puts ImplementationExplanationGate.validate(workplan, repository: options[:repository])
    elsif command == "extract"
      abort "usage: implementation-explanation-gate.rb extract --repository ROOT --path RELATIVE_PATH --start-line N --end-line N [--base-revision REVISION]" unless ARGV.empty? && %i[repository path start_line end_line].all? { |key| options[key] }
      print ImplementationExplanationGate.extract(**options.slice(:repository, :path, :start_line, :end_line, :base_revision))
    else
      abort "usage: implementation-explanation-gate.rb validate|extract ..."
    end
  rescue ImplementationExplanationGate::ValidationError => error
    warn error.message
    exit 1
  end
end
