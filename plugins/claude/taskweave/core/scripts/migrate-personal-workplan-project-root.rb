#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "open3"
require "optparse"
require "pathname"
require_relative "workplan-layout"

options = { apply: false }
OptionParser.new do |parser|
  parser.on("--source-root PATH") { |value| options[:source_root] = value }
  parser.on("--project-id ID") { |value| options[:project_id] = value }
  parser.on("--apply") { options[:apply] = true }
end.parse!

def approval_revision(script, main)
  stdout, stderr, status = Open3.capture3("ruby", script.to_s, main.to_s)
  raise(stderr.strip.empty? ? "approval revision 계산 실패: #{main}" : stderr.strip) unless status.success?

  stdout.strip
end

def bundle_manifest(bundle)
  bundle.glob("**/*", File::FNM_DOTMATCH).select(&:file?).sort.each_with_object({}) do |path, manifest|
    manifest[path.relative_path_from(bundle).to_s] = Digest::SHA256.file(path).hexdigest
  end
end

def project_moves(source_root, project_id, revision_script)
  mains = source_root.glob("*/*.md").select do |main|
    main.basename(".md").to_s == main.dirname.basename.to_s && main.dirname.basename.to_s != project_id
  end.sort
  raise "이동할 개인 Workplan bundle이 없습니다: #{source_root}" if mains.empty?

  ids = {}
  mains.map do |main|
    _raw, data = WorkplanLayout.frontmatter(main.read(encoding: "UTF-8"))
    id = data.fetch("id")
    raise "bundle 이름과 ID 불일치: #{main}" unless main.dirname.basename.to_s == id
    raise "project_id 불일치: #{main}" unless data.fetch("project_id") == project_id
    raise "Workplan ID 중복: #{id}" if ids.key?(id)

    ids[id] = true
    stored_revision = data["approval_revision"].to_s
    calculated_revision = stored_revision.empty? ? nil : approval_revision(revision_script, main)

    {
      id: id,
      source: main.dirname,
      target: source_root.join(project_id, id),
      manifest: bundle_manifest(main.dirname),
      approval_revision: stored_revision,
      calculated_revision: calculated_revision
    }
  end
end

def verify_moved!(moves, revision_script)
  moves.each do |move|
    raise "source bundle이 남았습니다: #{move[:source]}" if move[:source].exist?
    raise "target bundle이 없습니다: #{move[:target]}" unless move[:target].directory?
    raise "bundle hash 불일치: #{move[:id]}" unless bundle_manifest(move[:target]) == move[:manifest]

    next if move[:approval_revision].empty?

    main = move[:target].join("#{move[:id]}.md")
    raise "이동 후 approval revision 계산값 불일치: #{move[:id]}" unless approval_revision(revision_script, main) == move[:calculated_revision]
  end
end

begin
  source_root = Pathname(options.fetch(:source_root)).expand_path
  project_id = options.fetch(:project_id)
  raise "project-id가 비어 있습니다" if project_id.empty?
  raise "source root가 없습니다: #{source_root}" unless source_root.directory?

  target_root = source_root.join(project_id)
  raise "대상 project root가 이미 있습니다: #{target_root}" if target_root.exist?
  revision_script = Pathname(__dir__).join("workplan-approval-revision.rb")
  moves = project_moves(source_root, project_id, revision_script)
  moves.each do |move|
    raise "대상 bundle이 이미 있습니다: #{move[:target]}" if move[:target].exist?
    approval_status = if move[:approval_revision].empty?
                        "none"
                      elsif move[:approval_revision] == move[:calculated_revision]
                        "matched"
                      else
                        "preexisting-mismatch"
                      end
    puts "#{move[:id]}\t#{move[:source]}\t#{move[:target]}\tfiles=#{move[:manifest].size}\tapproval=#{approval_status}"
  end
  puts "OK: #{moves.size} bundles #{options[:apply] ? 'ready to migrate' : 'validated (dry-run)'}"
  exit unless options[:apply]

  staging = source_root.join(".#{project_id}.migration-#{Process.pid}")
  raise "staging 경로가 이미 있습니다: #{staging}" if staging.exist?
  staging.mkpath
  installed_root = nil
  begin
    fail_after = ENV["WORKPLAN_MIGRATION_TEST_FAIL_AFTER"]&.to_i
    moves.each_with_index do |move, index|
      FileUtils.mv(move[:source], staging.join(move[:id]))
      raise "injected migration failure" if fail_after && index + 1 == fail_after
    end
    FileUtils.mv(staging, target_root)
    installed_root = target_root
    moves.each { |move| move[:target] = target_root.join(move[:id]) }
    verify_moved!(moves, revision_script)
  rescue StandardError
    rollback_root = installed_root&.directory? ? installed_root : staging
    moves.reverse_each do |move|
      current = rollback_root.join(move[:id])
      FileUtils.mv(current, move[:source]) if current.exist? && !move[:source].exist?
    end
    rollback_root.rmdir if rollback_root.directory? && rollback_root.children.empty?
    raise
  end

  puts "MIGRATED: #{moves.size} bundles -> #{target_root}"
rescue KeyError, RuntimeError, Errno::ENOENT, Errno::EEXIST, Errno::ENOTEMPTY => error
  warn error.message
  exit 1
end
