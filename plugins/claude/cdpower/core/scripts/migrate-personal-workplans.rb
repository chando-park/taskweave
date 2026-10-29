#!/usr/bin/env ruby

require "fileutils"
require "optparse"
require_relative "workplan-layout"

options = { apply: false }
OptionParser.new do |parser|
  parser.on("--root PATH") { |value| options[:root] = value }
  parser.on("--apply") { options[:apply] = true }
end.parse!

def sections(text)
  body = text.sub(/\A---\s*\n.*?\n---\s*\n/m, "")
  result = {}
  current = nil
  body.each_line do |line|
    if (match = line.match(/^##\s+(.+?)\s*$/))
      current = match[1]
      result[current] = []
    elsif current
      result[current] << line
    end
  end
  result.transform_values { |lines| lines.join.strip }
end

def useful_lines(value, limit)
  value.to_s.lines.map(&:strip).reject do |line|
    line.empty? || line == "-" || line.match?(/^- [^:]+:\s*$/)
  end.first(limit)
end

def compact_main(raw_frontmatter, data, original)
  id = data.fetch("id")
  status = data.fetch("status")
  schema = "scope-v2"
  additions = [
    "workplan_layout: #{WorkplanLayout::LAYOUT}",
    "details_root: Details",
    "approval_revision_schema: #{schema}"
  ].compact
  metadata = ([raw_frontmatter.rstrip] + additions).join("\n")
  title = original.sub(/\A---\s*\n.*?\n---\s*\n/m, "")[/^#\s+(.+)$/, 1] || id
  source = sections(original)
  summary = useful_lines(source["현상"] || source["목표"], 2)
  summary = ["- 상태: `#{status}`"] if summary.empty?
  decision = useful_lines(source["승인 답변"], 2)
  decision = useful_lines(source["권장 변경안"] || source["승인 범위"], 3) if decision.empty?
  question = useful_lines(source["확인 질문"], 2)
  decision = question unless question.empty? || !%w[awaiting_approval needs_reapproval].include?(status)
  scope = useful_lines(source["변경 범위"] || source["변경 대상"], 3)
  completion_source = source["회귀 테스트 설계"] || source["테스트 설계"] || source["검증 계획"]
  completion = useful_lines(completion_source, 2)
  result = useful_lines([source["구현 결과"], source["검증 결과"]].compact.join("\n"), 3)
  next_action = case WorkplanLayout.state_group(status)
                when "Active" then status == "awaiting_approval" ? "- 사용자 승인 대기." : "- 현재 lifecycle 상태를 계속 진행."
                when "Waiting" then "- 차단 사유 해소 또는 재승인 대기."
                else "- 없음."
                end
  render = lambda do |values, fallback|
    values.empty? ? fallback : values.join("\n")
  end

  <<~MD
    ---
    #{metadata}
    ---

    # #{title}

    ## 상태와 승인
    - 상태: `#{status}`
    - 승인: #{data['approved_at'].to_s.empty? ? '미승인' : '승인됨'}

    ## 결정 및 승인 범위
    #{render.call(decision, "- 승인 기록과 상세 결정은 작업 설명 참조.")}

    ## 변경 범위
    #{render.call(scope, "- 상세 범위는 작업 설명 참조.")}

    ## 완료 조건
    #{render.call(completion, "- 승인된 검증과 상태 조건 충족.")}

    ## 현재 결과
    #{render.call(result, "- 아직 기록되지 않음.")}

    ## 다음 행동
    #{next_action}

    ## 문서
    - [작업 설명](Details/description.md)
  MD
end

def description(original, id)
  body = original.sub(/\A---\s*\n.*?\n---\s*\n/m, "").sub(/\A#\s+.*\n+/, "")
  body = body.gsub(/^### /, "#### ").gsub(/^## /, "### ")
  "# #{id} 작업 설명\n\n## 기존 작업 문서\n\n#{body.strip}\n"
end

begin
  root = Pathname(options.fetch(:root)).expand_path
  legacy_files = root.children.select { |path| path.file? && path.extname == ".md" && path.basename.to_s != "README.md" }.sort
  plans = legacy_files.map do |source|
    original = source.read(encoding: "UTF-8")
    raw, data = WorkplanLayout.frontmatter(original)
    id = data.fetch("id")
    raise "파일명과 ID가 다릅니다: #{source}" unless source.basename(".md").to_s == id
    [source, original, raw, data, WorkplanLayout.bundle_directory(root, data)]
  end
  targets = plans.map(&:last)
  lifecycle = %w[Active Waiting Completed].flat_map do |state|
    root.glob("#{state}/**/*.md").select { |path| path.basename(".md").to_s == path.dirname.basename.to_s }
  end.map do |main|
    _raw, data = WorkplanLayout.frontmatter(main.read(encoding: "UTF-8"))
    [main, data, WorkplanLayout.bundle_directory(root, data)]
  end
  targets += lifecycle.map(&:last)
  raise "migration 대상 bundle이 중복됩니다" unless targets.uniq.size == targets.size
  targets.each { |target| raise "대상 bundle이 이미 있습니다: #{target}" if target.exist? }

  plans.each { |source, _original, _raw, _data, target| puts "#{source} -> #{target}" }
  lifecycle.each { |main, _data, target| puts "#{main.dirname} -> #{target}" }
  exit unless options[:apply]

  plans.each do |source, original, raw, data, target|
    id = data.fetch("id")
    details = target.join("Details")
    details.mkpath
    details.join("description.md").write(description(original, id), encoding: "UTF-8")
    target.join("#{id}.md").write(compact_main(raw, data, original), encoding: "UTF-8")
    File.delete(source)
  end
  lifecycle.each do |main, _data, target|
    raise "대상 bundle이 이미 있습니다: #{target}" if target.exist?
    FileUtils.mv(main.dirname, target)
    moved = target.join(main.basename)
    text = moved.read(encoding: "UTF-8")
    text = text.sub(/^workplan_layout:\s*.*$/, "workplan_layout: #{WorkplanLayout::LAYOUT}")
    moved.write(text, encoding: "UTF-8")
  end
  %w[Active Waiting Completed].each do |state|
    container = root.join(state)
    FileUtils.rm_rf(container) if container.directory? && container.glob("**/*", File::FNM_DOTMATCH).none?(&:file?)
  end
rescue KeyError, RuntimeError, Errno::ENOENT => error
  warn error.message
  exit 1
end
