# frozen_string_literal: true

# Regenerates the checked-in evidence logs with deterministic Minitest ordering.
require "fileutils"
require "open3"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
RESULTS = File.join(ROOT, "results")
SQLITE_VERSION = "2.9.5"
TARGETS = ["7.1.6", "7.2.3.1", "8.0.5", "8.1.3", "edge"].freeze

FileUtils.mkdir_p(RESULTS)

def environment_for(target)
  base = { "SQLITE3_VERSION" => SQLITE_VERSION, "AR_SOURCE" => nil, "AR_VERSION" => nil }
  target == "edge" ? base.merge("AR_SOURCE" => "edge") : base.merge("AR_VERSION" => target)
end

def run_and_capture(script, target)
  command = [RbConfig.ruby, File.join(ROOT, script), "--seed", "1"]
  Open3.capture2e(environment_for(target), *command, chdir: ROOT)
end

TARGETS.each do |target|
  slug = target == "edge" ? "edge" : "ar-#{target}"

  repro_output, repro_status = run_and_capture("repro.rb", target)
  expected_signature = repro_output.include?("7 runs, 8 assertions, 4 failures, 2 errors, 0 skips")
  abort "unexpected repro result for #{target}" if repro_status.success? || !expected_signature
  File.write(File.join(RESULTS, "repro-#{slug}.log"), repro_output)

  fix_output, fix_status = run_and_capture("fix_validation.rb", target)
  expected_fix = fix_output.include?("14 runs, 25 assertions, 0 failures, 0 errors, 0 skips")
  abort "candidate fix failed for #{target}" unless fix_status.success? && expected_fix
  File.write(File.join(RESULTS, "fix-#{slug}.log"), fix_output)

  puts "captured #{target}"
end

issue_output, issue_status = run_and_capture("issue_repro.rb", "edge")
issue_signature = issue_output.include?("5 runs, 6 assertions, 2 failures, 2 errors, 0 skips")
abort "unexpected compact issue repro result" if issue_status.success? || !issue_signature
File.write(File.join(RESULTS, "issue-repro-edge.log"), issue_output)

matrix_output, matrix_status = Open3.capture2e(
  { "AR_VERSION" => "8.1.3", "SQLITE3_VERSION" => SQLITE_VERSION },
  RbConfig.ruby,
  File.join(ROOT, "script/trigger_matrix.rb"),
  chdir: ROOT
)
abort "trigger matrix failed" unless matrix_status.success?
File.write(File.join(RESULTS, "trigger-matrix.log"), matrix_output)

parser_output, parser_status = Open3.capture2e(
  RbConfig.ruby,
  File.join(ROOT, "script/parser_comparison.rb"),
  chdir: ROOT
)
abort "single-line parser comparison failed" unless parser_status.success?
File.write(File.join(RESULTS, "parser-comparison.log"), parser_output)

["1.7.3", "2.5.0", "2.9.5"].each do |sqlite_version|
  storage_output, storage_status = Open3.capture2e(
    { "SQLITE3_VERSION" => sqlite_version },
    RbConfig.ruby,
    File.join(ROOT, "script/sqlite_storage_probe.rb"),
    chdir: ROOT
  )
  abort "SQLite storage probe failed for #{sqlite_version}" unless storage_status.success?
  File.write(File.join(RESULTS, "sqlite-storage-#{sqlite_version}.log"), storage_output)
end

puts "captured trigger, parser-comparison, and SQLite storage probes"
