# frozen_string_literal: true

# Independent validation of the candidate parser fix documented in README.md.
# Unlike repro.rb, every test in this file must pass. The adapter method is based
# on the pinned current-main implementation. Small query helpers bridge Rails
# 7.1-8.1 (`internal_exec_query`) and main (`query_all`) so the main-targeted
# candidate can also be exercised under every affected dependency set.
#
# Usage:
#   ruby fix_validation.rb
#   AR_VERSION=7.1.6 ruby fix_validation.rb
#   AR_SOURCE=edge ruby fix_validation.rb
#
# Upstream method under test, pinned to the main revision used by this audit:
# https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L7-L52
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
require "active_record/connection_adapters/sqlite3_adapter"
require "minitest/autorun"
require "open3"
require "stringio"

ActiveRecord::Base.logger = nil

puts "Active Record version: #{ActiveRecord::VERSION::STRING} (candidate fix applied)"
puts "sqlite3 gem version: #{Gem.loaded_specs.fetch('sqlite3').version}"
puts "SQLite library version: #{SQLite3::SQLITE_VERSION}"

if ENV["AR_SOURCE"] == "edge"
  rails_root = File.expand_path("..", Gem.loaded_specs.fetch("activerecord").full_gem_path)
  revision, status = Open3.capture2("git", "-C", rails_root, "rev-parse", "HEAD")
  puts "Rails source commit: #{revision.strip}" if status.success?
end

module SchemaRoundTrip
  private

  # Active Record 7.1 takes a connection here; 7.2+ takes a pool.
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
    eval(schema.gsub(/version: [\d_.]+/, "version: 0")) # rubocop:disable Security/Eval
    current_connection
  end
end

module CandidateIndexesFix
  def indexes(table_name)
    schema_query_all("PRAGMA index_list(#{quote_table_name(table_name)})").filter_map do |row|
      next if row["name"].start_with?("sqlite_")

      index_sql = schema_query_value(<<~SQL)
        SELECT sql
        FROM sqlite_master
        WHERE name = #{quote(row['name'])} AND type = 'index'
        UNION ALL
        SELECT sql
        FROM sqlite_temp_master
        WHERE name = #{quote(row['name'])} AND type = 'index'
      SQL

      # Candidate change:
      # - /m lets each dot cross line boundaries.
      # - lazy `where` lets final whitespace remain outside the capture.
      # - \s*\z accepts LF, CRLF, tabs, and spaces at the absolute end.
      # Ruby semantics: https://docs.ruby-lang.org/en/3.4/Regexp.html#class-Regexp-label-Anchors
      # and https://docs.ruby-lang.org/en/3.4/Regexp.html#class-Regexp-label-Options
      /\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+?))?(?:\s*\/\*.*\*\/)?\s*\z/im =~ index_sql

      columns = schema_query_all("PRAGMA index_info(#{quote(row['name'])})").map do |column|
        column["name"]
      end

      where = where.sub(/\s*\/\*.*\*\/\z/, "") if where
      orders = {}

      if columns.any?(&:nil?)
        columns = expressions
      elsif index_sql
        index_sql.scan(/"(\w+)" DESC/).flatten.each do |order_column|
          orders[order_column] = :desc
        end
      end

      ActiveRecord::ConnectionAdapters::IndexDefinition.new(
        table_name,
        row["name"],
        row["unique"] != 0,
        columns,
        where: where,
        orders: orders
      )
    end
  end

  private

  def schema_query_all(sql)
    if respond_to?(:query_all, true)
      query_all(sql)
    else
      internal_exec_query(sql, "SCHEMA")
    end
  end

  def schema_query_value(sql)
    if respond_to?(:query_all, true)
      query_value(sql)
    else
      query_value(sql, "SCHEMA")
    end
  end
end

ActiveRecord::ConnectionAdapters::SQLite3Adapter.prepend(CandidateIndexesFix)

class FixValidationTest < Minitest::Test
  include SchemaRoundTrip

  EXPECTED_WHERE = "status = 'pending'"
  INSERT_REJECTED = "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'rejected')"
  INSERT_PENDING = "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'pending')"

  def setup
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    @conn = current_connection
    @conn.create_table :join_requests, force: true do |table|
      table.integer :organization_id, null: false
      table.integer :user_id, null: false
      table.string :status, null: false, default: "pending"
    end
  end

  def test_control_single_line_is_unchanged
    @conn.add_index :join_requests, [:organization_id, :user_id],
      unique: true, name: :idx_pending, where: EXPECTED_WHERE

    assert_equal EXPECTED_WHERE, index("idx_pending").where
  end

  def test_public_add_index_heredoc_predicate
    @conn.add_index :join_requests, [:organization_id, :user_id],
      unique: true, name: :idx_pending, where: <<~SQL
        status = 'pending'
      SQL

    assert_equal EXPECTED_WHERE, index("idx_pending").where
  end

  def test_one_terminal_lf
    @conn.execute "CREATE UNIQUE INDEX idx_pending ON join_requests (organization_id, user_id) WHERE status = 'pending'\n"

    assert_equal EXPECTED_WHERE, index("idx_pending").where
  end

  def test_crlf_terminated_statement
    sql = "CREATE UNIQUE INDEX idx_pending ON join_requests (organization_id, user_id) WHERE status = 'pending'\r\n"
    @conn.execute sql

    assert_equal EXPECTED_WHERE, index("idx_pending").where
  end

  def test_other_terminal_whitespace_is_not_part_of_where
    [" ", "\t", "\r", "\n\n"].each_with_index do |terminator, position|
      name = "idx_terminal_#{position}"
      sql = "CREATE UNIQUE INDEX #{name} ON join_requests (organization_id, user_id) WHERE status = 'pending'#{terminator}"
      @conn.execute sql

      assert_equal EXPECTED_WHERE, index(name).where
    end
  end

  def test_multiline_columns_and_predicate
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_pending ON join_requests (
        organization_id,
        user_id
      ) WHERE status =
        'pending'
    SQL

    assert_equal "status =\n  'pending'", index("idx_pending").where
  end

  def test_expression_index_without_where_and_with_terminal_lf
    @conn.add_column :join_requests, :email, :string
    @conn.execute "CREATE INDEX idx_email ON join_requests (LOWER(email))\n"

    assert_equal "LOWER(email)", index("idx_email").columns
  end

  def test_multiline_expression_index
    @conn.add_column :join_requests, :email, :string
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_email
      ON join_requests (organization_id, LOWER(email))
      WHERE status = 'pending'
    SQL

    candidate = index("idx_email")
    assert_equal "organization_id, LOWER(email)", candidate.columns
    assert_equal EXPECTED_WHERE, candidate.where
  end

  # Mirrors the nested, adjacent-WHERE grammar already covered by Rails' own
  # single-line SQLite adapter corpus, guarding against a regression while the
  # newline cases are added:
  # https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/test/cases/adapters/sqlite3/sqlite3_adapter_test.rb#L758-L764
  def test_existing_complicated_expression_syntax_is_unchanged
    @conn.execute <<~SQL.chomp
      CREATE INDEX idx_complicated ON join_requests (organization_id % 10, (CASE WHEN user_id > 0 THEN max(organization_id, user_id) END))WHERE(organization_id > 1000)
    SQL

    candidate = index("idx_complicated")
    assert_equal "organization_id % 10, (CASE WHEN user_id > 0 THEN max(organization_id, user_id) END)", candidate.columns
    assert_equal "(organization_id > 1000)", candidate.where
  end

  def test_multiline_expression_body_round_trips
    @conn.add_column :join_requests, :email, :string
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_email ON join_requests (
        organization_id,
        LOWER(email)
      ) WHERE status = 'pending'
    SQL

    schema = dump_schema
    fresh = load_schema_into_fresh_database(schema)
    candidate = fresh.indexes(:join_requests).find { |item| item.name == "idx_email" }

    refute_nil candidate
    assert_includes candidate.columns, "LOWER(email)"
    assert_equal EXPECTED_WHERE, candidate.where
  end

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

    assert_equal EXPECTED_WHERE, fresh.indexes(:join_requests).find { |item| item.name == "idx_pending" }.where
  end

  def test_schema_dumper_keeps_expression_index_table
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

  def test_trailing_block_comment_and_lf
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_pending ON join_requests (organization_id, user_id)
      WHERE status = 'pending' /* migration note */
    SQL

    assert_equal EXPECTED_WHERE, index("idx_pending").where
  end

  # ActiveSupport's String#squish collapses internal whitespace, so normalizing
  # the complete SQL string would mutate this predicate's string literal:
  # https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activesupport/lib/active_support/core_ext/string/filters.rb#L3-L26
  def test_multiple_spaces_inside_string_literal_are_preserved
    @conn.add_column :join_requests, :note, :string
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_note ON join_requests (user_id)
      WHERE note = 'two  spaces'
    SQL

    assert_equal "note = 'two  spaces'", index("idx_note").where
  end

  private

  def index(name)
    @conn.indexes(:join_requests).find { |candidate| candidate.name == name } ||
      flunk("index #{name.inspect} was not returned")
  end
end
