# frozen_string_literal: true

# Executable test case for a SQLite3Adapter schema-introspection bug:
# the WHERE clause of a partial index is silently dropped when the stored
# CREATE INDEX SQL contains a trailing newline or spans multiple lines
# (i.e. whenever it was created via `execute <<~SQL`).
#
# Modeled on rails/rails guides/bug_report_templates/active_record.rb.
# Tests assert the CORRECT behavior — failures demonstrate the bug.
#
# Usage:
#   ruby repro.rb                        # latest released Active Record
#   AR_VERSION="~> 7.1.0" ruby repro.rb  # a specific release line
#   AR_SOURCE=edge ruby repro.rb         # rails/rails main
require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"

  if ENV["AR_SOURCE"] == "edge"
    gem "rails", github: "rails/rails", branch: "main"
  elsif ENV["AR_VERSION"]
    gem "activerecord", ENV["AR_VERSION"]
  else
    gem "activerecord"
  end

  gem "sqlite3"
end

require "active_record"
require "minitest/autorun"
require "stringio"
require "logger"

puts "Active Record version: #{ActiveRecord::VERSION::STRING}"

ActiveRecord::Base.logger = nil

# Each test gets a fresh in-memory database.
class BugTest < Minitest::Test
  def setup
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    @conn = ActiveRecord::Base.lease_connection rescue ActiveRecord::Base.connection
    @conn.create_table :join_requests, force: true do |t|
      t.integer :organization_id, null: false
      t.integer :user_id, null: false
      t.string :status, null: false, default: "pending"
    end
  end

  # ── Control: single-line CREATE INDEX, no trailing newline ─────────────
  # This is the ONLY formatting the parser accepts. Passes on all versions.
  def test_control_single_line_where_is_preserved
    @conn.execute "CREATE UNIQUE INDEX idx_pending ON join_requests (organization_id, user_id) WHERE status = 'pending'"

    assert_equal "status = 'pending'", index("idx_pending").where
  end

  # ── Minimal trigger: ONE trailing newline character ────────────────────
  # SQLite stores the CREATE INDEX text verbatim in sqlite_master. The
  # parser's regex ends in an absolute end-of-string anchor (\z) and the
  # `where` capture is (.+) without /m — it cannot consume a newline, so a
  # single trailing "\n" makes the whole match fail and `where` comes back
  # nil. FAILS on every version tested (7.1 → edge).
  def test_trailing_newline_where_is_preserved
    @conn.execute "CREATE UNIQUE INDEX idx_pending ON join_requests (organization_id, user_id) WHERE status = 'pending'\n"

    assert_equal "status = 'pending'", index("idx_pending").where
  end

  # ── Real-world shape: heredoc migration (multi-line + trailing \n) ─────
  # This is how partial indexes are commonly written in migrations, because
  # add_index historically pushed people to raw SQL for anything fancy:
  #
  #   execute <<~SQL
  #     CREATE UNIQUE INDEX ... ON ... (...)
  #     WHERE status = 'pending'
  #   SQL
  #
  # FAILS on every version tested.
  def test_heredoc_where_is_preserved
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_pending
      ON join_requests (organization_id, user_id)
      WHERE status = 'pending'
    SQL

    assert_equal "status = 'pending'", index("idx_pending").where
  end

  # ── The data-integrity payload: schema.rb round-trip ───────────────────
  # Because PRAGMA index_info still supplies the columns, the failed parse
  # is SILENT: the index is dumped WITHOUT its where:, i.e. as a FULL
  # unique index. Every database provisioned from that schema.rb (every
  # Rails test database, every `db:schema:load` bootstrap) then enforces a
  # DIFFERENT, stricter constraint than the migrated production database.
  #
  # Here: "one PENDING request per user" silently becomes "one request per
  # user EVER" — a rejected request forever blocks a new one. FAILS.
  def test_schema_roundtrip_preserves_partial_index_semantics
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_pending
      ON join_requests (organization_id, user_id)
      WHERE status = 'pending'
    SQL

    # Sanity: the MIGRATED database honors partial-index semantics.
    @conn.execute "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'rejected')"
    @conn.execute "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'pending')"

    # Dump schema.rb from it, load into a fresh database.
    io = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, io)
    dump = io.string

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    eval(dump.sub("ActiveRecord::Schema", "ActiveRecord::Schema").gsub(/version: [\d_.]+/, "version: 0")) # rubocop:disable Security/Eval -- schema.rb is executed by Rails the same way

    fresh = ActiveRecord::Base.lease_connection rescue ActiveRecord::Base.connection
    fresh.execute "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'rejected')"

    # Under a faithful dump this insert MUST succeed (previous row is not
    # 'pending'). Under the bug it raises RecordNotUnique: the reloaded
    # index is a full unique index.
    fresh.execute "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'pending')"

    assert_equal "status = 'pending'", fresh.indexes(:join_requests).find { |i| i.name == "idx_pending" }.where
  end

  # ── Secondary failure: multi-line EXPRESSION index ─────────────────────
  # For an expression index the columns CANNOT be recovered from
  # PRAGMA index_info (it yields nil entries), so the code falls back to
  # the regex's `expressions` capture — which also failed. The dumped
  # index ends up with nil/empty columns. FAILS (shape varies by version).
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

  private

  def index(name)
    @conn.indexes(:join_requests).find { |i| i.name == name } ||
      flunk("index #{name} not returned at all")
  end
end
