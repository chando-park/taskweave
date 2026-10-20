#!/usr/bin/env ruby

require "json"
require "open3"
require "optparse"
require "pathname"
require "rbconfig"
require "tempfile"
require "time"
require "yaml"

SHA256 = /\Asha256:[0-9a-f]{64}\z/
APPROVABLE_STATUSES = %w[awaiting_approval needs_reapproval].freeze
ALREADY_APPROVED_STATUSES = %w[approved implementing verifying verification_blocked awaiting_completion].freeze

options = {
  approved_by: "user",
  source: "conversation",
  at: Time.now.iso8601
}

OptionParser.new do |parser|
  parser.on("--expected-revision REVISION") { |value| options[:expected_revision] = value }
  parser.on("--approved-by NAME") { |value| options[:approved_by] = value }
  parser.on("--source SOURCE") { |value| options[:source] = value }
  parser.on("--scope SUMMARY") { |value| options[:scope] = value }
  parser.on("--at ISO8601") { |value| options[:at] = value }
end.parse!

workplan = Pathname(ARGV.fetch(0) do
  abort "usage: record-workplan-approval --expected-revision sha256:... [--approved-by NAME] [--source SOURCE] [--scope SUMMARY] [--at ISO8601] <Workplan>"
end).expand_path
abort "Workplan이 없습니다: #{workplan}" unless workplan.file?

expected_revision = options[:expected_revision].to_s
abort "--expected-revision 형식이 올바르지 않습니다" unless expected_revision.match?(SHA256)
abort "--approved-by가 비어 있습니다" if options[:approved_by].to_s.strip.empty?
abort "--source가 비어 있습니다" if options[:source].to_s.strip.empty?

begin
  approved_at = Time.iso8601(options[:at]).iso8601
rescue ArgumentError
  abort "--at은 초와 UTC offset을 포함한 ISO 8601이어야 합니다"
end
abort "--at은 초와 UTC offset을 포함한 ISO 8601이어야 합니다" unless options[:at].match?(/T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/)

raw = workplan.read(encoding: "UTF-8")
match = raw.match(/\A---\s*\n(.*?)\n---\s*\n/m)
abort "Workplan frontmatter를 찾을 수 없습니다: #{workplan}" unless match
frontmatter = match[1]
metadata = YAML.safe_load(frontmatter, permitted_classes: [Date, Time], aliases: false) || {}
abort "Workplan frontmatter는 mapping이어야 합니다" unless metadata.is_a?(Hash)

revision_script = Pathname(__dir__).join("workplan-approval-revision.rb")
stdout, stderr, status = Open3.capture3(RbConfig.ruby, revision_script.to_s, workplan.to_s)
abort stderr.strip unless status.success?
current_revision = stdout.strip
abort "계획이 승인 질문 이후 변경되었습니다: expected=#{expected_revision} actual=#{current_revision}" unless current_revision == expected_revision

current_status = metadata["status"].to_s
if ALREADY_APPROVED_STATUSES.include?(current_status) && metadata["authority_status"] == "approved" && metadata["approval_revision"] == current_revision
  puts JSON.generate("status" => "already-approved", "workplan" => workplan.to_s, "approval_revision" => current_revision)
  exit 0
end

abort "승인할 수 없는 Workplan 상태입니다: #{current_status.inspect}" unless APPROVABLE_STATUSES.include?(current_status)
abort "readiness가 ready 또는 conditional이 아닙니다" unless %w[ready conditional].include?(metadata["readiness"])
abort "authority_status가 proposal이 아닙니다" unless metadata["authority_status"] == "proposal"

scope = options[:scope].to_s.strip
scope = "Workplan approval revision #{current_revision}" if scope.empty?
updates = {
  "status" => "approved",
  "development_status" => "approved",
  "authority_status" => "approved",
  "approval_revision" => current_revision,
  "approved_at" => approved_at,
  "approved_by" => options[:approved_by].to_s,
  "approval_source" => options[:source].to_s,
  "approval_scope" => scope,
  "updated" => approved_at
}

lines = frontmatter.lines(chomp: true)
updates.each do |key, value|
  indexes = lines.each_index.select { |index| lines[index].match?(/\A#{Regexp.escape(key)}\s*:/) }
  abort "중복된 top-level metadata입니다: #{key}" if indexes.length > 1
  rendered = case key
             when "status", "development_status", "authority_status", "approval_revision"
               "#{key}: #{value}"
             else
               "#{key}: #{JSON.generate(value)}"
             end
  indexes.empty? ? lines << rendered : lines[indexes.first] = rendered
end

new_frontmatter = lines.join("\n")
updated_raw = raw.sub(match[0], "---\n#{new_frontmatter}\n---\n")

Tempfile.create([".workplan-approval-", ".tmp"], workplan.dirname.to_s) do |temporary|
  temporary.chmod(workplan.stat.mode)
  temporary.write(updated_raw)
  temporary.flush
  temporary.fsync
  temporary.close
  File.rename(temporary.path, workplan.to_s)
end

post_revision, post_error, post_status = Open3.capture3(RbConfig.ruby, revision_script.to_s, workplan.to_s)
abort post_error.strip unless post_status.success?
abort "승인 기록이 계획 revision을 변경했습니다" unless post_revision.strip == current_revision

if metadata["workplan_schema"] == "approval-memo-v1"
  artifact_root = workplan.dirname.join("Artifacts")
  abort "approval snapshot parent가 symlink입니다" if artifact_root.symlink?
  artifact_root.mkpath
  feedback_reapproval = !metadata["feedback_prepared_snapshot"].to_s.empty?
  if feedback_reapproval
    history_root = artifact_root.join("approval-revisions")
    abort "approval revision parent가 symlink입니다" if history_root.symlink?
    history_root.mkpath
    snapshot = history_root.join("#{current_revision.delete_prefix('sha256:')}.json")
  else
    snapshot = artifact_root.join("approval-snapshot.json")
  end
  approval_snapshot = {
    "schema" => "approval-memo-snapshot-v1",
    "workplan" => workplan.basename.to_s,
    "approval_revision" => current_revision,
    "approved_at" => approved_at,
    "approved_by" => options[:approved_by].to_s,
    "approval_source" => options[:source].to_s,
    "approval_scope" => scope,
    "prepared_snapshot_hash" => metadata["prepared_snapshot_hash"]
  }
  approval_snapshot["feedback_prepared_snapshot_hash"] = metadata["feedback_prepared_snapshot_hash"] if feedback_reapproval
  begin
    File.open(snapshot, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
      file.write(JSON.pretty_generate(approval_snapshot) + "\n")
      file.flush
      file.fsync
    end
  rescue Errno::EEXIST
    existing = JSON.parse(snapshot.read(encoding: "UTF-8"))
    abort "기존 approval snapshot이 현재 승인과 다릅니다" unless existing == approval_snapshot
  rescue JSON::ParserError
    abort "기존 approval snapshot을 읽을 수 없습니다"
  end
end

puts JSON.generate(
  "status" => "approved",
  "workplan" => workplan.to_s,
  "approval_revision" => current_revision,
  "approved_at" => approved_at,
  "detail_documents_modified" => false
)
