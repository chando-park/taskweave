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
  "## 🧪 테스트",
  "## ⚠️ 남은 위험"
]
required.each { |heading| errors << "필수 섹션 누락: #{heading}" unless body.include?(heading) } unless official
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
