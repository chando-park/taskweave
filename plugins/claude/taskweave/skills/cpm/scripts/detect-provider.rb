#!/usr/bin/env ruby

remote = ARGV.first.to_s.downcase

case remote
when /(^|[.@:\/])github\.com([:\/]|$)/
  puts "github"
when /(^|[.@:\/])gitlab\.com([:\/]|$)/, /(^|[.@:\/])gitlab([.\/:]|$)/
  puts "gitlab"
else
  warn "ERROR: 지원하는 Git provider를 판별할 수 없습니다: #{ARGV.first}"
  exit 1
end
