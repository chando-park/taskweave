#!/usr/bin/env ruby

require "json"
require "pathname"

class BodyError < StandardError; end

def fetch_string(hash, key)
  value = hash.fetch(key)
  raise BodyError, "#{key}는 비어 있지 않은 문자열이어야 합니다." unless value.is_a?(String) && !value.strip.empty?
  value.strip
end

def list_lines(values, empty: "없음")
  raise BodyError, "목록 값이 배열이 아닙니다." unless values.is_a?(Array)
  return [empty] if values.empty?
  values.map { |value| "- #{value}" }
end

def reject_literal_newlines(value, path = "root")
  case value
  when Hash
    value.each { |key, child| reject_literal_newlines(child, "#{path}.#{key}") }
  when Array
    value.each_with_index { |child, index| reject_literal_newlines(child, "#{path}[#{index}]") }
  when String
    raise BodyError, "literal \\n을 사용할 수 없습니다: #{path}" if value.include?("\\n")
  end
end

def review_verdict(review)
  raise BodyError, "review는 객체여야 합니다." unless review.is_a?(Hash)
  verdict = review.fetch("verdict")
  raise BodyError, "알 수 없는 review verdict입니다." unless %w[APPROVE REQUEST_CHANGES COMMENT].include?(verdict)
  verdict
end

def change_review_lines(data, level: 2)
  changes = data.fetch("changes")
  files = data.fetch("files")
  review = data.fetch("review")
  raise BodyError, "changes는 비어 있지 않은 배열이어야 합니다." unless changes.is_a?(Array) && !changes.empty?
  raise BodyError, "files는 비어 있지 않은 배열이어야 합니다." unless files.is_a?(Array) && !files.empty?
  verdict = review_verdict(review)
  heading = "#" * level
  lines = ["#{heading} ✅ 변경 사항", *list_lines(changes), "", "#{heading} 📁 변경된 파일", "| 파일 | 내용 |", "| --- | --- |"]
  files.each do |file|
    path = fetch_string(file, "path").gsub("|", "\\|")
    description = fetch_string(file, "description").gsub("|", "\\|")
    lines << "| `#{path}` | #{description} |"
  end
  lines.concat(["", "#{heading} 📋 코드 리뷰 결과", "#{heading}# 변경 사항 개요", fetch_string(review, "overview")])
  { "critical" => "🔴 Critical Issues", "warnings" => "🟡 Warnings", "suggestions" => "🟢 Suggestions", "positive" => "✅ Positive Points" }.each do |key, title|
    lines.concat(["", "#{heading}# #{title}", *list_lines(review.fetch(key))])
  end
  lines.concat(["", "#{level == 2 ? '###' : heading} 📊 종합 평가", "- 최종 의견: `#{verdict}`"])
  lines
end

begin
  input_path = Pathname.new(ARGV.fetch(0)).expand_path
  output_path = Pathname.new(ARGV.fetch(1)).expand_path
  data = JSON.parse(input_path.read)
  reject_literal_newlines(data)

  commits = data["commits"]
  commit_ids = []
  if data.key?("commits")
    raise BodyError, "커밋별 본문에는 2개 이상의 commits가 필요합니다." unless commits.is_a?(Array) && commits.length >= 2
    commit_ids = commits.map do |commit|
      raise BodyError, "commit은 객체여야 합니다." unless commit.is_a?(Hash)
      sha = fetch_string(commit, "sha")
      raise BodyError, "유효하지 않은 커밋 SHA입니다." unless sha.match?(/\A[0-9a-f]{7,40}\z/)
      sha
    end
    raise BodyError, "커밋 SHA가 중복되었습니다." unless commit_ids.uniq.length == commit_ids.length
  end
  tests = data.fetch("tests", [])
  risks = data.fetch("remaining_risks", [])
  raise BodyError, "tests는 배열이어야 합니다." unless tests.is_a?(Array)
  coverage_revisions = []
  coverage_lines = tests.map do |test|
    raise BodyError, "tests 항목은 객체여야 합니다." unless test.is_a?(Hash)
    count = test.fetch("executed_count", 0)
    raise BodyError, "executed_count는 0 이상 정수여야 합니다." unless count.is_a?(Integer) && count >= 0
    next if count.zero?

    revision = test["revision"]
    if commits && !commit_ids.include?(revision)
      raise BodyError, "커밋별 커버리지에는 본문에 포함된 측정 커밋 revision이 필요합니다."
    end
    if revision && !revision.is_a?(String)
      raise BodyError, "revision은 커밋 SHA 문자열이어야 합니다."
    end
    coverage_revisions << revision

    name = fetch_string(test, "module")
    if test.key?("coverage_error")
      next "- #{name}: 수집 실패 (#{fetch_string(test, 'coverage_error')})"
    end
    covered = test["covered_lines"]
    executable = test["executable_lines"]
    if covered.nil? && executable.nil?
      next "- #{name}: 수집 실패 (커버리지 결과 없음)"
    end
    unless covered.is_a?(Integer) && executable.is_a?(Integer) && executable > 0 && covered.between?(0, executable)
      raise BodyError, "커버리지 줄 수는 0 <= covered_lines <= executable_lines이고 executable_lines > 0이어야 합니다."
    end
    "- #{name}: #{format('%.1f', covered.fdiv(executable) * 100)}% (#{covered}/#{executable}줄)"
  end.compact
  lines = []
  if commits
    lines.concat(["## 🎯 해결하려는 문제", fetch_string(data, "problem"), "", "## 🛠️ 접근 방법", fetch_string(data, "approach"), "", "## 📝 커밋별 변경 사항·코드 리뷰"])
    commits.each_with_index do |commit, index|
      lines.concat(["", "### #{index + 1}. #{commit.fetch('sha')} — #{fetch_string(commit, 'title')}", "", *change_review_lines(commit, level: 4)])
    end
    integration = data.fetch("integration_review")
    verdict = review_verdict(integration)
    lines.concat(["", "## 🔎 커밋 간 연계 검토", *list_lines(integration.fetch("findings")), "- 최종 의견: `#{verdict}`"])
  else
    lines.concat(["## 📋 개요", fetch_string(data, "summary"), "", *change_review_lines(data)])
  end
  unless coverage_lines.empty?
    lines << ""
    lines << "## 🧪 테스트"
    coverage_revisions.zip(coverage_lines).group_by(&:first).each do |revision, entries|
      lines << "측정 기준: 커밋 `#{revision}`" if revision
      lines.concat(entries.map(&:last))
      lines << ""
    end
  end
  lines << ""
  lines << "## ⚠️ 남은 위험"
  lines.concat(list_lines(risks))
  lines << ""

  body = lines.join("\n")
  raise BodyError, "MR 본문이 12KB를 초과합니다." if body.bytesize > 12_000
  output_path.dirname.mkpath
  output_path.write(body)
  puts output_path
rescue BodyError, JSON::ParserError, KeyError, Errno::ENOENT, IndexError => error
  warn "ERROR: #{error.message}"
  exit 1
end
