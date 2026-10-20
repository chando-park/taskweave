#!/usr/bin/env ruby

require "digest"
require "date"
require "pathname"
require "yaml"
require "json"

RESULT_DOCUMENT_PATHS = %w[
  Details/change.md
  Details/verification.md
  Details/knowledge-candidate.md
  change.md
  verification.md
  knowledge-candidate.md
].freeze

def canonical_plan_document(role, content)
  return content.rstrip unless role == "description"

  fence = nil
  content.lines.reject do |line|
    marker = line.lstrip[/\A(`{3,}|~{3,})/, 1]
    if fence
      fence = nil if marker && marker[0] == fence[0] && marker.length >= fence.length
      false
    elsif marker
      fence = marker
      false
    else
      RESULT_DOCUMENT_PATHS.any? do |relative|
        line.match?(%r{\A\s*-\s+\[[^\]]+\]\(#{Regexp.escape(relative)}(?:#[^)]+)?\)\s*\z})
      end
    end
  end.join.rstrip
end

path = Pathname(ARGV.fetch(0) { abort "usage: workplan-approval-revision.rb <workplan.md>" }).expand_path
content = path.read(encoding: "UTF-8")
frontmatter = content[/\A---\s*\n(.*?)\n---\s*\n/m, 1]
metadata = frontmatter ? YAML.safe_load(frontmatter, permitted_classes: [Date, Time], aliases: false) : {}
control_metadata = metadata || {}
if metadata && metadata["approval_basis"]
  path = path.dirname.join(metadata.fetch("approval_basis")).expand_path
  content = path.read(encoding: "UTF-8")
  if control_metadata["approval_basis_payload"] == "legacy-original"
    start_marker = "<!-- legacy-original:start -->\n"
    end_marker = "<!-- legacy-original:end -->"
    begin
      content = content.split(start_marker, 2).fetch(1).split(end_marker, 2).fetch(0)
    rescue IndexError
      abort "approval basis payload marker가 없습니다: #{path}"
    end
  end
  frontmatter = content[/\A---\s*\n(.*?)\n---\s*\n/m, 1]
  metadata = frontmatter ? YAML.safe_load(frontmatter, permitted_classes: [Date, Time], aliases: false) : {}
end
body = content.sub(/\A---\s*\n.*?\n---\s*\n/m, "")
if control_metadata["workplan_schema"] == "approval-memo-v1"
  require_relative "workplan-memo"
  projection = WorkplanMemo.approval_projection(path, data: control_metadata, body: body)
  puts "sha256:#{Digest::SHA256.hexdigest(JSON.generate(projection))}"
  exit 0
end
Array(control_metadata["approval_basis_excluded_sections"]).each do |heading|
  body = body.sub(/^## #{Regexp.escape(heading.to_s)}\s*$.*?(?=^## |\z)/m, "")
end
schema = control_metadata["approval_revision_schema"] || (metadata && metadata["approval_revision_schema"])
if %w[scope-v2 scope-v3].include?(schema)
  sections = body.scan(/^## (결정 및 승인 범위|변경 범위|완료 조건)\s*$\n(.*?)(?=^## |\z)/m).to_h
  approved_scope = %w[결정\ 및\ 승인\ 범위 변경\ 범위 완료\ 조건].map { |name| "## #{name}\n#{sections.fetch(name, '').strip}" }.join("\n\n").rstrip
  if schema == "scope-v3"
    source_digest = control_metadata["expected_source_inventory_digest"]
    if source_digest && !source_digest.to_s.empty?
      approved_scope = "## metadata:expected_source_inventory_digest\n#{source_digest}\n\n#{approved_scope}"
    end
    roles = %w[description requirements code_plan test_plan knowledge]
    declared = control_metadata["detail_documents"]
    abort "scope-v3 detail_documents mapping이 없습니다: #{path}" unless declared.is_a?(Hash)
    roles.each do |role|
      next unless declared.key?(role)
      relative = declared.fetch(role).to_s
      expected = {
        "description" => "Details/description.md",
        "requirements" => "Details/requirements.md",
        "code_plan" => "Details/code-plan.md",
        "test_plan" => "Details/test-plan.md",
        "knowledge" => "Details/knowledge.md"
      }.fetch(role)
      abort "scope-v3 detail path 불일치: #{role}=#{relative}" unless relative == expected
      document = path.dirname.join(relative).cleanpath
      begin
        inside = document.relative_path_from(path.dirname.cleanpath).to_s
        abort "scope-v3 detail path가 bundle 밖입니다: #{relative}" if inside.start_with?("../") || inside == ".."
      rescue ArgumentError
        abort "scope-v3 detail path가 bundle 밖입니다: #{relative}"
      end
      abort "scope-v3 detail 문서가 없습니다: #{document}" unless document.file?
      begin
        real_inside = document.realpath.relative_path_from(path.dirname.realpath).to_s
        abort "scope-v3 detail symlink realpath가 bundle 밖입니다: #{relative}" if real_inside.start_with?("../") || real_inside == ".."
      rescue ArgumentError, Errno::ENOENT
        abort "scope-v3 detail symlink realpath가 bundle 밖입니다: #{relative}"
      end
      document_content = canonical_plan_document(role, document.read(encoding: "UTF-8"))
      approved_scope << "\n\n## detail:#{role}:#{relative}\n#{document_content}"
    end
  end
else
  approved_scope = body.split(/^## 승인 답변\s*$/, 2).first.to_s.rstrip
end
abort "approval scope is empty: #{path}" if approved_scope.empty?

puts "sha256:#{Digest::SHA256.hexdigest(approved_scope)}"
