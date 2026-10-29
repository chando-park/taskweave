#!/usr/bin/env ruby

require "pathname"

errors = []
official = ARGV.delete("--official")
path = Pathname.new(ARGV.first.to_s).expand_path

unless path.file?
  warn "ERROR: MR 본문 파일이 없습니다: #{path}"
  exit 1
end

body = path.read
required = [
  "## 📋 개요",
  "## ✅ 변경 사항",
  "## 📁 변경된 파일",
  "## 📋 코드 리뷰 결과",
  "## ⚠️ 남은 위험"
]
unless official
  if body.match?(/^## 📝 커밋별 변경 사항·코드 리뷰$/)
    required = ["## 🎯 해결하려는 문제", "## 🛠️ 접근 방법", "## 🔎 커밋 간 연계 검토", "## ⚠️ 남은 위험"]
    commits = body.split(/^### \d+\. /).drop(1)
    errors << "커밋별 본문에는 2개 이상의 커밋이 필요합니다." if commits.length < 2
    commits.each_with_index do |commit, index|
      ["#### ✅ 변경 사항", "#### 📁 변경된 파일", "#### 📋 코드 리뷰 결과", "#### 📊 종합 평가",
       "##### 🔴 Critical Issues", "##### 🟡 Warnings", "##### 🟢 Suggestions", "##### ✅ Positive Points"].each do |heading|
        errors << "커밋 #{index + 1} 섹션 누락: #{heading}" unless commit.lines.map(&:strip).include?(heading)
      end
    end
  end
  required.each { |heading| errors << "필수 섹션 누락: #{heading}" unless body.lines.map(&:strip).include?(heading) }
end
errors << "종합 평가는 점수 없이 최종 의견만 작성하세요." if !official && body.match?(/(?:코드 품질|아키텍처(?: 준수)?|보안)[^\n]*\b\d+\/10\b/)
errors << "MR 본문이 비어 있습니다." if body.strip.empty?
errors << "literal \\n이 남아 있습니다." if body.include?("\\n")
errors << "원시 테스트 로그가 포함되어 있습니다." if body.match?(/^\s*(?:-\s*)?(?:Test (?:Suite|Case)|◇ Test run|↳ Testing Library Version)/)
errors << "빈 inline code가 있습니다." if body.match?(/(?<!`)``(?!`)/)
errors << "MR 본문이 12KB를 초과합니다." if body.bytesize > 12_000

if errors.empty?
  puts "OK: #{path}"
else
  errors.each { |error| warn "ERROR: #{error}" }
  exit 1
end
