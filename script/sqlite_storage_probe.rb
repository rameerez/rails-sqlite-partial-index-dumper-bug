# frozen_string_literal: true

# Confirms the narrower empirical fact this bug relies on without overstating
# SQLite's documented normalization rules: for this CREATE INDEX shape, the SQL
# returned from sqlite_schema exactly equals the input and retains its final LF.
require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"
  gem "sqlite3", ENV.fetch("SQLITE3_VERSION", "2.9.5")
end

require "sqlite3"

database = SQLite3::Database.new(":memory:")
database.results_as_hash = true
database.execute("CREATE TABLE join_requests (organization_id INTEGER, user_id INTEGER, status TEXT)")

sql = "CREATE UNIQUE INDEX idx_pending ON join_requests (organization_id, user_id) WHERE status = 'pending'\n"
database.execute(sql)
stored = database.get_first_value("SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = 'idx_pending'")
metadata = database.get_first_row("PRAGMA index_list('join_requests')")

puts "sqlite3 gem version: #{Gem.loaded_specs.fetch('sqlite3').version}"
puts "SQLite library version: #{SQLite3::SQLITE_VERSION}"
puts "input equals stored SQL: #{stored == sql}"
puts "stored terminal bytes: #{stored.bytes.last(4).inspect}"
puts "PRAGMA partial flag: #{metadata.fetch('partial')}"

abort "stored SQL did not retain this input exactly" unless stored == sql
abort "stored SQL did not retain terminal LF" unless stored.end_with?("\n")
abort "SQLite did not report a partial index" unless metadata.fetch("partial") == 1
