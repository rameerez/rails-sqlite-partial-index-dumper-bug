# SQLite3: newline in stored index SQL drops partial WHERE or omits expression-index table from schema.rb

<!--
Draft only. Do not file until we decide whether to open the fix PR alongside it.
Before filing, rerun `AR_SOURCE=edge ruby issue_repro.rb`, update the pinned main
SHA/output if it moved, and replace this comment with any linked PR number.
-->

### Steps to reproduce

A terminal newline in SQLite's stored `CREATE INDEX` SQL makes
`SQLite3::SchemaStatements#indexes` lose a partial predicate. This can be
triggered through the documented public `add_index(..., where:)` API by supplying
the predicate as a Ruby heredoc; it does not require raw SQL.

The compact executable case below follows the Active Record bug-report-template
style. Its tests assert expected behavior, so the current bug produces intentional
failures/errors.

<details>
<summary>Executable test case</summary>

```ruby
# frozen_string_literal: true

require "bundler/inline"

gemfile(true) do
  source "https://rubygems.org"
  gem "rails", github: "rails/rails", branch: "main"
  gem "sqlite3", "2.9.5"
end

require "active_record"
require "minitest/autorun"
require "open3"
require "stringio"

ActiveRecord::Base.logger = nil

rails_root = File.expand_path("..", Gem.loaded_specs.fetch("activerecord").full_gem_path)
revision, status = Open3.capture2("git", "-C", rails_root, "rev-parse", "HEAD")
puts "Active Record #{ActiveRecord::VERSION::STRING} at #{revision.strip}" if status.success?
puts "sqlite3 #{Gem.loaded_specs.fetch('sqlite3').version}; SQLite #{SQLite3::SQLITE_VERSION}"

class SQLiteIndexNewlineBugTest < Minitest::Test
  WHERE = "status = 'pending'"
  REJECTED = "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'rejected')"
  PENDING = "INSERT INTO join_requests (organization_id, user_id, status) VALUES (1, 1, 'pending')"

  def setup
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    @connection = ActiveRecord::Base.lease_connection
    @connection.create_table(:join_requests) do |table|
      table.integer :organization_id, null: false
      table.integer :user_id, null: false
      table.string :status, null: false
    end
  end

  def test_control
    @connection.add_index :join_requests, [:organization_id, :user_id],
      name: :idx_pending, unique: true, where: WHERE

    assert_equal WHERE, index("idx_pending").where
  end

  def test_public_add_index_heredoc
    @connection.add_index :join_requests, [:organization_id, :user_id],
      name: :idx_pending, unique: true, where: <<~SQL
        status = 'pending'
      SQL

    metadata = @connection.select_all('PRAGMA index_list("join_requests")').find do |row|
      row["name"] == "idx_pending"
    end
    stored_sql = @connection.select_value("SELECT sql FROM sqlite_master WHERE name = 'idx_pending'")

    assert_equal 1, metadata.fetch("partial")
    assert stored_sql.end_with?("\n")
    assert_equal WHERE, index("idx_pending").where
  end

  def test_schema_round_trip_semantics
    @connection.add_index :join_requests, [:organization_id, :user_id],
      name: :idx_pending, unique: true, where: <<~SQL
        status = 'pending'
      SQL
    @connection.execute REJECTED
    @connection.execute PENDING

    schema = StringIO.new.tap do |stream|
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, stream)
    end.string

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    eval(schema.gsub(/version: [\d_.]+/, "version: 0"))
    fresh = ActiveRecord::Base.lease_connection

    fresh.execute REJECTED
    fresh.execute PENDING
  end

  def test_expression_index_introspection
    @connection.add_column :join_requests, :email, :string
    @connection.execute "CREATE INDEX idx_email ON join_requests (LOWER(email))\n"

    assert_equal "LOWER(email)", index("idx_email").columns
  end

  def test_schema_dumper_keeps_expression_index_table
    @connection.add_column :join_requests, :email, :string
    @connection.execute <<~SQL
      CREATE UNIQUE INDEX idx_email
      ON join_requests (organization_id, LOWER(email))
      WHERE status = 'pending'
    SQL

    schema = StringIO.new.tap do |stream|
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, stream)
    end.string

    assert_includes schema, 'create_table "join_requests"'
    refute_includes schema, "Could not dump table"
  end

  private

  def index(name)
    @connection.indexes(:join_requests).find { |candidate| candidate.name == name }
  end
end
```

</details>

The same file is available as
[`issue_repro.rb`](https://github.com/rameerez/rails-sqlite-partial-index-dumper-bug/blob/main/issue_repro.rb).

On main commit
[`d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096`](https://github.com/rails/rails/commit/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096),
the summary is:

```text
5 runs, 6 assertions, 2 failures, 2 errors, 0 skips
```

The two SQLite assertions inside `test_public_add_index_heredoc` pass first:
SQLite reports `partial=1`, and the stored SQL ends in LF. The next assertion
fails because Rails returns `where=nil`.

### Expected behavior

- `connection.indexes` returns `where: "status = 'pending'"` independent of
  harmless CREATE INDEX line formatting.
- Dumping and loading `schema.rb` preserves the partial unique constraint's
  semantics.
- Expression indexes remain introspectable.
- The schema dumper retains the affected table.

These expectations follow Rails' existing contracts:

- Rails [documents partial indexes for PostgreSQL and
  SQLite](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_statements.rb#L909-L917).
- The SQLite adapter [reports partial- and expression-index
  support](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/sqlite3_adapter.rb#L209-L214).
- The generic schema-dumper test [expects `where:` whenever the adapter reports
  support](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/test/cases/schema_dumper_test.rb#L250-L257).

### Actual behavior

There are two related outcomes from the same failed regex match.

For ordinary partial unique indexes, columns still come from
`PRAGMA index_info`, but `where` is nil. The Ruby schema therefore emits a full
unique index. The migrated database accepts a rejected row and a pending row for
one key; a fresh database loaded from the dump raises
`ActiveRecord::RecordNotUnique` for the same pair.

For expression indexes, SQLite returns a NULL name for the expression entry in
`PRAGMA index_info`. Rails substitutes the failed regex's nil `expressions`
capture, and `IndexDefinition#concise_options` calls `columns.size`. Direct
`connection.indexes` therefore raises `NoMethodError: undefined method 'size'
for nil`. `SchemaDumper` catches that error at table scope, writes a `Could not
dump table` comment, omits the whole table, and returns normally.

Exact implementation links:

- [`SQLite3::SchemaStatements#indexes`, lines 7-52](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L7-L52)
- [`IndexDefinition#concise_options`, lines 64-71](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_definitions.rb#L64-L71)
- [`SchemaDumper` table-scope rescue, lines 225-248](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/schema_dumper.rb#L225-L248)
- [SQLite `PRAGMA index_info` output contract](https://www.sqlite.org/pragma.html#pragma_index_info)

### Root cause

The current parser is:

```ruby
/\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+))?(?:\s*\/\*.*\*\/)?\z/i =~ index_sql
```

It has no `/m`, so dot cannot cross LF, and it ends in absolute `\z`, so a
terminal LF prevents the whole match. Ruby documents [dot's `/m`
behavior](https://docs.ruby-lang.org/en/3.4/Regexp.html#class-Regexp-label-Shorthand+Character+Classes),
[`\Z` versus `\z`](https://docs.ruby-lang.org/en/3.4/Regexp.html#class-Regexp-label-Boundary+Anchors),
and that [heredocs include their ending
newline](https://docs.ruby-lang.org/en/3.4/syntax/literals_rdoc.html#label-Here+Document+Literals).

Rails passes the public API predicate into generated SQL without stripping it:
[`add_index_options`, lines 1601-1623](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_statements.rb#L1601-L1623)
and
[`visit_CreateIndexDefinition`, lines 106-123](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_creation.rb#L106-L123).

SQLite documents that `sqlite_schema.sql` is a copy of the original CREATE text
subject to specified normalization—not arbitrary whitespace canonicalization:
[schema-table documentation](https://www.sqlite.org/schematab.html#interpretation_of_the_schema_table).
For this input, direct probes with sqlite3 gems 1.7.3, 2.5.0, and 2.9.5 all
preserve the terminal LF exactly.

The trigger is narrower than “any newline”: newlines consumed by an existing
`\s*` can work. Terminal LF/CRLF and newlines inside `expressions` or `where`
fail. A complete characterization is in the public
[evidence report](https://github.com/rameerez/rails-sqlite-partial-index-dumper-bug/blob/main/EVIDENCE.md#trigger-characterization).

### Candidate fix

This candidate passes 14 positive and regression cases across Active Record
7.1.6, 7.2.3.1, 8.0.5, 8.1.3, and the pinned main revision:

```ruby
/\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+?))?(?:\s*\/\*.*\*\/)?\s*\z/im
```

It adds `/m`, makes the predicate lazy so terminal whitespace remains outside
the capture, and permits whitespace before `\z`. The validator intentionally
does not `squish` the full SQL because Rails' [implementation collapses internal
whitespace](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activesupport/lib/active_support/core_ext/string/filters.rb#L3-L26),
which could change `WHERE note = 'two  spaces'`. That literal is a regression
test.

Candidate code, CI matrix, raw logs, and the complete source ledger are at
https://github.com/rameerez/rails-sqlite-partial-index-dumper-bug.

### Related work

- #31603 / #31607: same broad symptom, different table-recreation path; fixed.
- #53570: merged change to this parser for trailing comments.
- #55627: same regex, different unconventional-table-name trigger; closed stale
  without a fix.
- #58136: current multiline SQLite work in other parsers; it does not touch
  index introspection.

Targeted issue/PR searches found no direct report of this newline trigger as of
2026-07-22.

### System configuration

**Rails version**: 8.2.0.alpha at
`d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096`; also reproduced on 7.1.6,
7.2.3.1, 8.0.5, and 8.1.3

**Ruby version**: 3.4.2

**sqlite3 gem**: 2.9.5

**SQLite library**: 3.53.2 on the audit machine; CI may use the platform build
