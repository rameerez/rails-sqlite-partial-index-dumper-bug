# frozen_string_literal: true

# Maps which newline placements do and do not defeat the current Rails parser.
# This is deliberately a characterization test for the unfixed adapter. It
# exits green only while every observed result matches the audited signature.
require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"
  gem "activerecord", ENV.fetch("AR_VERSION", "8.1.3")
  gem "sqlite3", ENV.fetch("SQLITE3_VERSION", "2.9.5")
end

require "active_record"

EXPECTED_WHERE = "status = 'pending'"

CASES = {
  "single line" => [
    "CREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id, user_id) WHERE status = 'pending'",
    EXPECTED_WHERE
  ],
  "leading LF" => [
    "\nCREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id, user_id) WHERE status = 'pending'",
    EXPECTED_WHERE
  ],
  "LF before ON" => [
    "CREATE UNIQUE INDEX INDEX_NAME\nON join_requests (organization_id, user_id) WHERE status = 'pending'",
    EXPECTED_WHERE
  ],
  "LF before WHERE" => [
    "CREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id, user_id)\nWHERE status = 'pending'",
    EXPECTED_WHERE
  ],
  "LF inside columns" => [
    "CREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id,\nuser_id) WHERE status = 'pending'",
    nil
  ],
  "LF inside predicate" => [
    "CREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id, user_id) WHERE status =\n'pending'",
    nil
  ],
  "one terminal LF" => [
    "CREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id, user_id) WHERE status = 'pending'\n",
    nil
  ],
  "two terminal LFs" => [
    "CREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id, user_id) WHERE status = 'pending'\n\n",
    nil
  ],
  "terminal CRLF" => [
    "CREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id, user_id) WHERE status = 'pending'\r\n",
    nil
  ],
  "one terminal space" => [
    "CREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id, user_id) WHERE status = 'pending' ",
    "#{EXPECTED_WHERE} "
  ],
  "terminal tab" => [
    "CREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id, user_id) WHERE status = 'pending'\t",
    "#{EXPECTED_WHERE}\t"
  ],
  "terminal CR" => [
    "CREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id, user_id) WHERE status = 'pending'\r",
    "#{EXPECTED_WHERE}\r"
  ],
  "semicolon" => [
    "CREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id, user_id) WHERE status = 'pending';",
    EXPECTED_WHERE
  ],
  "semicolon plus LF" => [
    "CREATE UNIQUE INDEX INDEX_NAME ON join_requests (organization_id, user_id) WHERE status = 'pending';\n",
    EXPECTED_WHERE
  ]
}.freeze

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
connection = if ActiveRecord::Base.respond_to?(:lease_connection)
  ActiveRecord::Base.lease_connection
else
  ActiveRecord::Base.connection
end
connection.create_table(:join_requests) do |table|
  table.integer :organization_id
  table.integer :user_id
  table.string :status
end

puts "Active Record #{ActiveRecord::VERSION::STRING}; sqlite3 gem #{Gem.loaded_specs.fetch('sqlite3').version}; SQLite #{SQLite3::SQLITE_VERSION}"
puts "case | stored prefix/suffix bytes | Rails where"
puts "--- | --- | ---"

failures = []

CASES.each_with_index do |(label, (template, expected)), position|
  name = "idx_case_#{position}"
  connection.execute(template.sub("INDEX_NAME", name))
  stored = connection.select_value("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = #{connection.quote(name)}")
  actual = connection.indexes(:join_requests).find { |index| index.name == name }.where
  edge_bytes = (stored.bytes.first(2) + stored.bytes.last(2)).join(",")

  puts "#{label} | #{edge_bytes} | #{actual.inspect}"
  failures << "#{label}: expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

abort failures.join("\n") if failures.any?

puts "Characterization matrix matched all #{CASES.size} expected results."
