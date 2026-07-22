# frozen_string_literal: true

# Executable reproduction for an Active Record SQLite3Adapter bug.
#
# The tests assert the behavior Rails promises. One control passes; the other
# tests fail or error while the upstream bug exists. A green CI wrapper lives at
# script/verify_bug.rb and verifies this precise, intentional failure signature.
#
# Usage:
#   ruby repro.rb
#   AR_VERSION=7.1.6 ruby repro.rb
#   AR_SOURCE=edge ruby repro.rb
#
# Primary upstream references:
# - Rails parser under test (pinned main commit, lines 7-52):
#   https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L7-L52
# - Rails documents partial indexes for PostgreSQL and SQLite (lines 909-917):
#   https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_statements.rb#L909-L917
# - Ruby heredocs include their ending newline:
#   https://docs.ruby-lang.org/en/3.4/syntax/literals_rdoc.html#label-Here+Document+Literals
# - SQLite schema SQL is original CREATE text with documented normalization:
#   https://www.sqlite.org/schematab.html
require "bundler/inline"

SQLITE3_VERSION = ENV.fetch("SQLITE3_VERSION", "2.9.5")

gemfile(true) do
  source "https://rubygems.org"

  if ENV["AR_SOURCE"] == "edge"
    gem "rails", github: "rails/rails", branch: "main"
  elsif ENV["AR_VERSION"]
    gem "activerecord", ENV.fetch("AR_VERSION")
  else
    gem "activerecord"
  end

  gem "sqlite3", SQLITE3_VERSION
end

require "active_record"
require "logger"
require "minitest/autorun"
require "open3"
require "stringio"

ActiveRecord::Base.logger = nil

puts "Active Record version: #{ActiveRecord::VERSION::STRING}"
puts "sqlite3 gem version: #{Gem.loaded_specs.fetch('sqlite3').version}"
puts "SQLite library version: #{SQLite3::SQLITE_VERSION}"

if ENV["AR_SOURCE"] == "edge"
  rails_root = File.expand_path("..", Gem.loaded_specs.fetch("activerecord").full_gem_path)
  revision, status = Open3.capture2("git", "-C", rails_root, "rev-parse", "HEAD")
  puts "Rails source commit: #{revision.strip}" if status.success?
end

module SchemaRoundTrip
  private

  # Active Record 7.1's SchemaDumper.dump accepts a connection; 7.2+ accepts a
  # pool. Detect the named parameter so this repro tests the Rails bug instead
  # of failing on an unrelated version-specific API difference:
  # https://github.com/rails/rails/blob/v7.1.6/activerecord/lib/active_record/schema_dumper.rb#L43-L47
  # https://github.com/rails/rails/blob/v7.2.3.1/activerecord/lib/active_record/schema_dumper.rb#L43-L49
  def dump_schema
    source = if ActiveRecord::SchemaDumper.method(:dump).parameters.first.last == :pool
      ActiveRecord::Base.connection_pool
    else
      @conn
    end

    StringIO.new.tap { |stream| ActiveRecord::SchemaDumper.dump(source, stream) }.string
  end

  def current_connection
    if ActiveRecord::Base.respond_to?(:lease_connection)
      ActiveRecord::Base.lease_connection
    else
      ActiveRecord::Base.connection
    end
  end

  def load_schema_into_fresh_database(schema)
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false

    # schema.rb is executable Ruby by design; Rails loads it the same way. The
    # string here was generated locally by ActiveRecord::SchemaDumper.
    # https://guides.rubyonrails.org/active_record_migrations.html#using-the-default-ruby-schema
    eval(schema.gsub(/version: [\d_.]+/, "version: 0")) # rubocop:disable Security/Eval
    current_connection
  end
end

class BugTest < Minitest::Test
  include SchemaRoundTrip

  EXPECTED_WHERE = "status = 'pending'"
  INSERT_REJECTED = "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'rejected')"
  INSERT_PENDING = "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'pending')"

  def setup
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    @conn = current_connection
    @conn.create_table :join_requests, force: true do |t|
      t.integer :organization_id, null: false
      t.integer :user_id, null: false
      t.string :status, null: false, default: "pending"
    end
  end

  # Control: Rails-generated SQL with a one-line predicate has no terminal LF,
  # so the current parser returns the predicate correctly.
  def test_control_single_line_where_is_preserved
    @conn.add_index :join_requests, [:organization_id, :user_id],
      unique: true, name: :idx_pending, where: EXPECTED_WHERE

    assert_equal EXPECTED_WHERE, index("idx_pending").where
  end

  # Strongest reproducer: this uses the documented public add_index API, not a
  # raw CREATE INDEX statement. SchemaCreation appends index.where unchanged:
  # https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_creation.rb#L106-L123
  def test_public_add_index_with_heredoc_where_is_preserved
    @conn.add_index :join_requests, [:organization_id, :user_id],
      unique: true, name: :idx_pending, where: <<~SQL
        status = 'pending'
      SQL

    metadata = sqlite_index_metadata("idx_pending")

    # SQLite independently and structurally identifies this as a partial index.
    # PRAGMA index_list column 5 is 1 for partial and 0 for full indexes:
    # https://www.sqlite.org/pragma.html#pragma_index_list
    assert_equal 1, metadata.fetch("partial")
    assert sqlite_index_sql("idx_pending").end_with?("\n"), "SQLite's stored SQL did not retain the terminal LF"
    assert_equal EXPECTED_WHERE, index("idx_pending").where
  end

  # Minimal raw-SQL trigger: one LF after an otherwise passing statement.
  def test_raw_create_index_with_one_trailing_lf_preserves_where
    @conn.execute "CREATE UNIQUE INDEX idx_pending ON join_requests (organization_id, user_id) WHERE status = 'pending'\n"

    assert_equal EXPECTED_WHERE, index("idx_pending").where
  end

  # Common migration shape: a semicolon-free squiggly heredoc includes a final
  # LF, as Ruby's literal documentation specifies.
  def test_raw_multiline_create_index_preserves_where
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_pending
      ON join_requests (organization_id, user_id)
      WHERE status = 'pending'
    SQL

    assert_equal EXPECTED_WHERE, index("idx_pending").where
  end

  # Observable data-integrity payload. The migrated database permits one
  # rejected row plus one pending row for the same key. The dumped schema loses
  # WHERE and reloads a full unique index, so the second valid insert raises.
  def test_schema_round_trip_preserves_partial_unique_semantics
    @conn.add_index :join_requests, [:organization_id, :user_id],
      unique: true, name: :idx_pending, where: <<~SQL
        status = 'pending'
      SQL

    @conn.execute INSERT_REJECTED
    @conn.execute INSERT_PENDING

    fresh = load_schema_into_fresh_database(dump_schema)
    fresh.execute INSERT_REJECTED
    fresh.execute INSERT_PENDING

    assert_equal EXPECTED_WHERE, fresh.indexes(:join_requests).find { |candidate| candidate.name == "idx_pending" }.where
  end

  # The same failed match sets the named `expressions` capture to nil. SQLite's
  # PRAGMA index_info returns a nil name for an expression, so Rails substitutes
  # that nil capture and IndexDefinition calls columns.size:
  # https://www.sqlite.org/pragma.html#pragma_index_info
  # https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_definitions.rb#L64-L71
  def test_expression_index_with_trailing_lf_is_introspectable
    @conn.add_column :join_requests, :email, :string
    @conn.execute "CREATE INDEX idx_email ON join_requests (LOWER(email))\n"

    assert_equal "LOWER(email)", index("idx_email").columns
  end

  # connection.indexes raises for the expression case, but SchemaDumper rescues
  # at table scope. It writes a diagnostic comment, omits the entire table, and
  # returns normally:
  # https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/schema_dumper.rb#L235-L248
  def test_schema_dump_keeps_table_with_multiline_expression_index
    @conn.add_column :join_requests, :email, :string
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_email
      ON join_requests (organization_id, LOWER(email))
      WHERE status = 'pending'
    SQL

    schema = dump_schema

    assert_includes schema, 'create_table "join_requests"'
    refute_includes schema, "Could not dump table"
  end

  private

  def index(name)
    @conn.indexes(:join_requests).find { |candidate| candidate.name == name } ||
      flunk("index #{name.inspect} was not returned")
  end

  def sqlite_index_metadata(name)
    @conn.select_all("PRAGMA index_list(#{@conn.quote_table_name(:join_requests)})").find do |row|
      row["name"] == name
    end || flunk("SQLite did not return index metadata for #{name.inspect}")
  end

  def sqlite_index_sql(name)
    @conn.select_value(<<~SQL)
      SELECT sql FROM sqlite_master
      WHERE type = 'index' AND name = #{@conn.quote(name)}
    SQL
  end
end
