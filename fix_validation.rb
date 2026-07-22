# frozen_string_literal: true

# Validates the fix proposed in ISSUE_DRAFT.md: same five tests as repro.rb,
# but with SQLite3::SchemaStatements#indexes monkey-patched to use the
# newline-proof regex. ALL FIVE must pass here (they 2F/2E in repro.rb).
#
#   ruby fix_validation.rb
#
# The patched method body is copied from Active Record 8.1.x with ONE line
# changed (the regex): /m added, lazy where capture, \s*\z anchor.
require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"
  gem "activerecord", "~> 8.1.0"
  gem "sqlite3"
end

require "active_record"
require "active_record/connection_adapters/sqlite3_adapter"
require "minitest/autorun"
require "stringio"

puts "Active Record version: #{ActiveRecord::VERSION::STRING} (PATCHED #indexes)"

ActiveRecord::Base.logger = nil

module PatchedIndexes
  def indexes(table_name)
    internal_exec_query("PRAGMA index_list(#{quote_table_name(table_name)})", "SCHEMA").filter_map do |row|
      next if row["name"].start_with?("sqlite_")

      index_sql = query_value(<<~SQL, "SCHEMA")
        SELECT sql
        FROM sqlite_master
        WHERE name = #{quote(row['name'])} AND type = 'index'
        UNION ALL
        SELECT sql
        FROM sqlite_temp_master
        WHERE name = #{quote(row['name'])} AND type = 'index'
      SQL

      # THE FIX — was:
      #   /\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+))?(?:\s*\/\*.*\*\/)?\z/i
      /\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+?))?(?:\s*\/\*.*\*\/)?\s*\z/im =~ index_sql

      columns = internal_exec_query("PRAGMA index_info(#{quote(row['name'])})", "SCHEMA").map do |col|
        col["name"]
      end

      where = where.sub(/\s*\/\*.*\*\/\z/, "") if where
      orders = {}

      if columns.any?(&:nil?)
        columns = expressions
      else
        if index_sql
          index_sql.scan(/"(\w+)" DESC/).flatten.each { |order_column|
            orders[order_column] = :desc
          }
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
end

ActiveRecord::ConnectionAdapters::SQLite3Adapter.prepend(PatchedIndexes)

class FixValidationTest < Minitest::Test
  def setup
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    @conn = ActiveRecord::Base.lease_connection
    @conn.create_table :join_requests, force: true do |t|
      t.integer :organization_id, null: false
      t.integer :user_id, null: false
      t.string :status, null: false, default: "pending"
    end
  end

  def test_control_single_line_where_is_preserved
    @conn.execute "CREATE UNIQUE INDEX idx_pending ON join_requests (organization_id, user_id) WHERE status = 'pending'"
    assert_equal "status = 'pending'", index("idx_pending").where
  end

  def test_trailing_newline_where_is_preserved
    @conn.execute "CREATE UNIQUE INDEX idx_pending ON join_requests (organization_id, user_id) WHERE status = 'pending'\n"
    assert_equal "status = 'pending'", index("idx_pending").where
  end

  def test_heredoc_where_is_preserved
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_pending
      ON join_requests (organization_id, user_id)
      WHERE status = 'pending'
    SQL
    assert_equal "status = 'pending'", index("idx_pending").where
  end

  def test_schema_roundtrip_preserves_partial_index_semantics
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_pending
      ON join_requests (organization_id, user_id)
      WHERE status = 'pending'
    SQL

    @conn.execute "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'rejected')"
    @conn.execute "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'pending')"

    io = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, io)

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    eval(io.string.gsub(/version: [\d_.]+/, "version: 0")) # rubocop:disable Security/Eval

    fresh = ActiveRecord::Base.lease_connection
    fresh.execute "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'rejected')"
    fresh.execute "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'pending')"

    assert_equal "status = 'pending'", fresh.indexes(:join_requests).find { |i| i.name == "idx_pending" }.where
  end

  def test_multiline_expression_index_keeps_its_expression
    @conn.add_column :join_requests, :email, :string
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_email
      ON join_requests (organization_id, LOWER(email))
      WHERE status = 'pending'
    SQL

    idx = index("idx_email")
    assert_equal "organization_id, LOWER(email)", idx.columns
    assert_equal "status = 'pending'", idx.where
  end

  # The fix must not regress WHERE clauses containing multi-space string
  # literals (the reason a whitespace-collapsing normalization is wrong).
  def test_where_clause_with_literal_spaces_survives
    @conn.add_column :join_requests, :note, :string
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_note
      ON join_requests (user_id)
      WHERE note = 'two  spaces'
    SQL

    assert_equal "note = 'two  spaces'", index("idx_note").where
  end

  private

  def index(name)
    @conn.indexes(:join_requests).find { |i| i.name == name } || flunk("index #{name} not returned at all")
  end
end
