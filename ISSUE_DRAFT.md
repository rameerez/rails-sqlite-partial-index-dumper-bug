# SQLite3: partial-index WHERE clause silently dropped from schema.rb (and `indexes` crashes for expression indexes) when CREATE INDEX SQL is multi-line

<!-- Title above; body below. Re-verify AR_SOURCE=edge before filing. -->

### Steps to reproduce

SQLite stores `CREATE INDEX` statements verbatim in `sqlite_master`. `SQLite3::SchemaStatements#indexes` recovers the `WHERE` clause of a partial index by parsing that stored SQL with a regex that has no `/m` flag and an absolute `\z` anchor — so it fails on any newline, including a **single trailing `"\n"`**. Every partial index created via a heredoc migration (`execute <<~SQL … SQL`) is affected.

Executable test case (bug-report-template style — the tests assert correct behavior, failures demonstrate the bug):

```ruby
# frozen_string_literal: true

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"
  gem "rails", github: "rails/rails", branch: "main"
  gem "sqlite3"
end

require "active_record"
require "minitest/autorun"
require "stringio"

ActiveRecord::Base.logger = nil

class BugTest < Minitest::Test
  def setup
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    @conn = ActiveRecord::Base.lease_connection
    @conn.create_table :join_requests, force: true do |t|
      t.integer :organization_id, null: false
      t.integer :user_id, null: false
      t.string :status, null: false, default: "pending"
    end
  end

  # Control — the only formatting the parser accepts. PASSES.
  def test_control_single_line_where_is_preserved
    @conn.execute "CREATE UNIQUE INDEX idx_pending ON join_requests (organization_id, user_id) WHERE status = 'pending'"
    assert_equal "status = 'pending'", index("idx_pending").where
  end

  # Minimal trigger: ONE trailing newline. FAILS (where comes back nil).
  def test_trailing_newline_where_is_preserved
    @conn.execute "CREATE UNIQUE INDEX idx_pending ON join_requests (organization_id, user_id) WHERE status = 'pending'\n"
    assert_equal "status = 'pending'", index("idx_pending").where
  end

  # Real-world shape: heredoc migration. FAILS (where nil).
  def test_heredoc_where_is_preserved
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_pending
      ON join_requests (organization_id, user_id)
      WHERE status = 'pending'
    SQL
    assert_equal "status = 'pending'", index("idx_pending").where
  end

  # The data-integrity payload: schema.rb round-trip. FAILS with
  # ActiveRecord::RecordNotUnique — the reloaded index is a FULL unique.
  def test_schema_roundtrip_preserves_partial_index_semantics
    @conn.execute <<~SQL
      CREATE UNIQUE INDEX idx_pending
      ON join_requests (organization_id, user_id)
      WHERE status = 'pending'
    SQL

    # The MIGRATED database honors partial-index semantics:
    @conn.execute "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'rejected')"
    @conn.execute "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'pending')"

    io = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, io)

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    eval(io.string.gsub(/version: [\d_.]+/, "version: 0"))

    fresh = ActiveRecord::Base.lease_connection
    fresh.execute "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'rejected')"
    # MUST succeed (previous row is not 'pending') — raises RecordNotUnique under the bug:
    fresh.execute "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'pending')"

    assert_equal "status = 'pending'", fresh.indexes(:join_requests).find { |i| i.name == "idx_pending" }.where
  end

  # Second symptom: for EXPRESSION indexes the parse failure isn't silent —
  # PRAGMA index_info yields nil column names, the code falls back to the
  # regex's (also nil) expressions capture, and IndexDefinition#initialize
  # crashes in concise_options (`columns.size` on nil). So even
  # `db:schema:dump` raises. FAILS with NoMethodError.
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
    @conn.indexes(:join_requests).find { |i| i.name == name } || flunk("index #{name} not returned at all")
  end
end
```

### Expected behavior

`connection.indexes` returns the index with `where: "status = 'pending'"` regardless of how the `CREATE INDEX` statement was formatted, schema.rb round-trips partial indexes faithfully, and expression indexes never crash introspection.

### Actual behavior

- `where` comes back **nil** whenever the stored SQL contains a newline — the schema dumper then emits the index **without `where:`**, i.e. as a **full unique index**. Because the columns are recovered separately via `PRAGMA index_info`, nothing errors: every database provisioned from that schema.rb (all Rails test databases, any `db:schema:load` bootstrap) silently enforces a *stricter* constraint than the migrated database. In the app where we found this, "one *pending* join request per user" became "one join request per user *ever*" in schema-loaded databases — inserts that production accepts raise `ActiveRecord::RecordNotUnique` in test.
- For **expression** indexes with multi-line SQL, `connection.indexes` (and therefore `db:schema:dump`) raises `NoMethodError: undefined method 'size' for nil` from `IndexDefinition#concise_options` — the `expressions` capture of the same failed regex is the columns fallback.

Root cause — `activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb` (`#indexes`):

```ruby
/\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+))?(?:\s*\/\*.*\*\/)?\z/i =~ index_sql
```

No `/m` (so `.` can't cross a newline) + absolute `\z` (so not even a trailing newline may follow the clause), applied to `sqlite_master.sql`, which is the *verbatim* original statement. The overall match fails, both named captures are nil.

A possible fix — tolerate surrounding/internal newlines while keeping them out of the capture:

```ruby
/\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+?))?(?:\s*\/\*.*\*\/)?\s*\z/im
```

(add `/m`, make the `where` capture lazy, anchor with `\s*\z`). I've validated this candidate against the test case above with `#indexes` monkey-patched: all tests pass, including a regression guard for WHERE clauses containing multi-space string literals (`WHERE note = 'two  spaces'` — the reason a whitespace-collapsing normalization would be wrong). Happy to send the PR with regression tests if the approach sounds right.

Related, for context: #55627 (same regex, different trigger — unconventional table names; closed stale) and #31603 (partial index lost through the `alter_table` recreation path; different code).

PostgreSQL/MySQL are unaffected — their servers return normalized/structured index definitions; only SQLite round-trips the user's raw SQL text.

### System configuration

**Rails version**: reproduced on 7.1.6, 7.2.3.1, 8.0.5, 8.1.3, and main (8.2.0.alpha) — identical failure signature on all five.

**Ruby version**: 3.4.x
