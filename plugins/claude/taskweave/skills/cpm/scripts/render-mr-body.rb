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

begin
  input_path = Pathname.new(ARGV.fetch(0)).expand_path
  output_path = Pathname.new(ARGV.fetch(1)).expand_path
  data = JSON.parse(input_path.read)
  reject_literal_newlines(data)

  summary = fetch_string(data, "summary")
  changes = data.fetch("changes")
  files = data.fetch("files")
  review = data.fetch("review")
  tests = data.fetch("tests")
  risks = data.fetch("remaining_risks", [])
  raise BodyError, "changes는 비어 있지 않은 배열이어야 합니다." unless changes.is_a?(Array) && !changes.empty?
  raise BodyError, "files는 비어 있지 않은 배열이어야 합니다." unless files.is_a?(Array) && !files.empty?
  raise BodyError, "review는 객체여야 합니다." unless review.is_a?(Hash)
  raise BodyError, "tests는 비어 있지 않은 배열이어야 합니다." unless tests.is_a?(Array) && !tests.empty?

  scores = review.fetch("scores")
  %w[code_quality architecture security].each do |key|
    score = scores.fetch(key)
    raise BodyError, "#{key} 점수는 0~10 정수여야 합니다." unless score.is_a?(Integer) && score.between?(0, 10)
  end
  verdict = review.fetch("verdict")
  raise BodyError, "알 수 없는 review verdict입니다." unless %w[APPROVE REQUEST_CHANGES COMMENT].include?(verdict)

  lines = []
  lines << "## 📋 개요"
  lines << summary
  lines << ""
  lines << "## ✅ 변경 사항"
  lines.concat(list_lines(changes))
  lines << ""
  lines << "## 📁 변경된 파일"
  lines << "| 파일 | 내용 |"
  lines << "| --- | --- |"
  files.each do |file|
    path = fetch_string(file, "path").gsub("|", "\\|")
    description = fetch_string(file, "description").gsub("|", "\\|")
    lines << "| `#{path}` | #{description} |"
  end
  lines << ""
  lines << "## 📋 코드 리뷰 결과"
  lines << "### 변경 사항 개요"
  lines << fetch_string(review, "overview")
  {
    "critical" => "### 🔴 Critical Issues",
    "warnings" => "### 🟡 Warnings",
    "suggestions" => "### 🟢 Suggestions",
    "positive" => "### ✅ Positive Points"
  }.each do |key, heading|
    lines << ""
    lines << heading
    lines.concat(list_lines(review.fetch(key)))
  end
  lines << ""
  lines << "### 📊 종합 평가"
  lines << "| 항목 | 평가 |"
  lines << "| --- | --- |"
  lines << "| 코드 품질 | #{scores.fetch('code_quality')}/10 |"
  lines << "| 아키텍처 | #{scores.fetch('architecture')}/10 |"
  lines << "| 보안 | #{scores.fetch('security')}/10 |"
  lines << ""
  lines << "판정: `#{verdict}`"
  lines << ""
  lines << "## 🧪 테스트"
  tests.each do |test|
    command = fetch_string(test, "command")
    result = fetch_string(test, "result")
    raise BodyError, "테스트 결과가 너무 깁니다. 원시 로그 대신 요약하세요." if result.bytesize > 1_000
    lines << "- `#{command}` — #{result}"
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
