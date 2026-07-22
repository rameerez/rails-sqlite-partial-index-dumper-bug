# frozen_string_literal: true

# Turns repro.rb's intentional red test suite into a green CI assertion. CI
# should fail if Rails fixes the bug, if the failure mechanism changes, or if an
# unrelated failure prevents the reproducer from reaching its assertions.
require "open3"
require "rbconfig"

repo_root = File.expand_path("..", __dir__)
command = [RbConfig.ruby, File.join(repo_root, "repro.rb"), "--seed", "1"]
output, status = Open3.capture2e(ENV, *command, chdir: repo_root)

puts output

problems = []
problems << "repro.rb unexpectedly passed" if status.success?

expected_fragments = [
  "BugTest#test_public_add_index_with_heredoc_where_is_preserved",
  "BugTest#test_raw_create_index_with_one_trailing_lf_preserves_where",
  "BugTest#test_raw_multiline_create_index_preserves_where",
  "BugTest#test_schema_round_trip_preserves_partial_unique_semantics",
  "BugTest#test_expression_index_with_trailing_lf_is_introspectable",
  "BugTest#test_schema_dump_keeps_table_with_multiline_expression_index",
  "ActiveRecord::RecordNotUnique",
  "undefined method 'size' for nil",
  "Could not dump table",
  "7 runs, 8 assertions, 4 failures, 2 errors, 0 skips"
]

expected_fragments.each do |fragment|
  problems << "missing expected output: #{fragment.inspect}" unless output.include?(fragment)
end

if problems.any?
  warn "\nBug-signature verification failed:"
  problems.each { |problem| warn "- #{problem}" }
  exit 1
end

puts "\nVerified the complete expected upstream bug signature."
