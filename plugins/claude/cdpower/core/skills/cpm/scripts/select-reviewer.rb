#!/usr/bin/env ruby

require "json"
require "pathname"
require "tempfile"

class ReviewerError < StandardError; end

Reviewer = Struct.new(:name, :username, :user_id, :assignment_count, :status, :line_index, keyword_init: true)

def parse_reviewers(path)
  lines = path.readlines
  reviewers = []

  lines.each_with_index do |line, index|
    stripped = line.strip
    next unless stripped.start_with?("|") && stripped.end_with?("|")

    cells = stripped[1...-1].split("|", -1).map(&:strip)
    next if cells.all? { |cell| cell.match?(/\A:?-+:?\z/) }
    next if cells.any? { |cell| cell == "GitLab username" }
    next unless cells.length == 5

    count = Integer(cells[3], exception: false)
    raise ReviewerError, "배정 횟수가 정수가 아닙니다: #{line.strip}" unless count

    username = cells[1].delete_prefix("`").delete_suffix("`")
    user_id = cells[2].delete_prefix("`").delete_suffix("`")
    raise ReviewerError, "리뷰어 username 또는 user_id가 비어 있습니다: #{line.strip}" if username.empty? || user_id.empty?

    reviewers << Reviewer.new(
      name: cells[0],
      username: username,
      user_id: user_id,
      assignment_count: count,
      status: cells[4],
      line_index: index
    )
  end

  raise ReviewerError, "유효한 리뷰어 행이 없습니다: #{path}" if reviewers.empty?
  [lines, reviewers]
end

def reviewer_json(reviewer)
  JSON.pretty_generate(
    "name" => reviewer.name,
    "username" => reviewer.username,
    "user_id" => reviewer.user_id,
    "assignment_count" => reviewer.assignment_count,
    "status" => reviewer.status
  )
end

begin
  command = ARGV.shift
  path = Pathname.new(ARGV.shift.to_s).expand_path
  raise ReviewerError, "reviewer 파일이 없습니다: #{path}" unless path.file?

  lines, reviewers = parse_reviewers(path)

  case command
  when "select"
    available = reviewers.reject { |reviewer| reviewer.status.include?("휴가") }
    raise ReviewerError, "배정 가능한 리뷰어가 없습니다." if available.empty?

    selected = available.min_by { |reviewer| [reviewer.assignment_count, reviewer.line_index] }
    puts reviewer_json(selected)
  when "increment"
    username = ARGV.shift.to_s
    matches = reviewers.select { |reviewer| reviewer.username == username }
    raise ReviewerError, "리뷰어를 정확히 하나 찾을 수 없습니다: #{username}" unless matches.length == 1

    reviewer = matches.first
    original_mode = path.stat.mode & 0o777
    lines[reviewer.line_index] = "| #{reviewer.name} | `#{reviewer.username}` | `#{reviewer.user_id}` | #{reviewer.assignment_count + 1} | #{reviewer.status} |\n"
    Tempfile.create([path.basename.to_s, ".tmp"], path.dirname.to_s) do |file|
      file.write(lines.join)
      file.flush
      File.chmod(original_mode, file.path)
      File.rename(file.path, path.to_s)
    end
    puts reviewer_json(reviewer.dup.tap { |value| value.assignment_count += 1 })
  else
    raise ReviewerError, "사용법: select-reviewer.rb select <file> | increment <file> <username>"
  end
rescue ReviewerError, Errno::ENOENT, Errno::EACCES => error
  warn "ERROR: #{error.message}"
  exit 1
end
