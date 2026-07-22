# Audit record and proof

## Verdict

This is a reproducible upstream Active Record correctness bug, not an
application misuse and not a security vulnerability.

The strongest proof uses Rails' documented public API:

```ruby
connection.add_index :join_requests, [:organization_id, :user_id],
  unique: true,
  name: :idx_pending,
  where: <<~SQL
    status = 'pending'
  SQL
```

For the resulting database object, three independently observable facts
conflict:

1. Ruby documents that the heredoc includes its ending LF.
2. SQLite retains that LF for this statement and reports `partial=1` through
   `PRAGMA index_list`.
3. Active Record returns an `IndexDefinition` with `unique=true` and
   `where=nil`.

The Rails and database sources for each step are catalogued in
[SOURCES.md](SOURCES.md). The contradiction itself is executable in
[`repro.rb`](repro.rb).

## Audit snapshot

- Audit date: 2026-07-22
- Ruby: 3.4.2
- Fixed SQLite binding for the Active Record matrix: sqlite3 gem 2.9.5
- SQLite library bundled by that gem on the audit machine: 3.53.2
- Rails edge revision:
  [`d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096`](https://github.com/rails/rails/commit/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096)
- Edge revision timestamp: 2026-07-21 20:59:32 -0400
- Parser-line SHA-256 in every tested Active Record version:
  `4d2203a33bf826e388379e1c2d708a4355b2c76eee1adf3cc781999f93b4051a`

The upstream line is pinned at
[`sqlite3/schema_statements.rb:24`](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L24):

```ruby
/\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+))?(?:\s*\/\*.*\*\/)?\z/i =~ index_sql
```

## Filed upstream contribution

- Bug report:
  [rails/rails#58200](https://github.com/rails/rails/issues/58200)
- Fix pull request:
  [rails/rails#58201](https://github.com/rails/rails/pull/58201)
- Submitted commit:
  [`a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb`](https://github.com/rails/rails/pull/58201/commits/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb)
- Exact native [parser change](https://github.com/rameerez/rails/blob/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L24),
  [regression tests](https://github.com/rameerez/rails/blob/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb/activerecord/test/cases/adapters/sqlite3/sqlite3_adapter_test.rb#L732-L809),
  and [changelog entry](https://github.com/rameerez/rails/blob/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb/activerecord/CHANGELOG.md#L1-L3)
- Green hosted checks: [Rails Buildkite #131320](https://buildkite.com/rails/rails/builds/131320),
  [`rails-new-docker` run 29885637092](https://github.com/rails/rails/actions/runs/29885637092),
  [docs-preview #20921](https://buildkite.com/rails/docs-preview/builds/20921),
  and [labeler run 29885636090](https://github.com/rails/rails/actions/runs/29885636090)
- Green independent case-file matrix:
  [Verification run 29885712858](https://github.com/rameerez/rails-sqlite-partial-index-dumper-bug/actions/runs/29885712858)

The exact final native regressions were intentionally run against the original
parser before the fix. They produced the nil-predicate failure, two expression
introspection errors, and schema-dump table omission: `4 runs, 4 assertions, 2
failures, 2 errors`. With the fix restored:

```text
Focused regressions:          4 runs,    11 assertions, 0 failures, 0 errors
sqlite3_adapter_test.rb:    101 runs,   253 assertions, 0 failures, 0 errors
Full Active Record SQLite: 9,643 runs, 32,864 assertions, 0 failures, 0 errors, 38 skips
RuboCop:                       3 files inspected, no offenses detected
```

The commands, seeds, failure mapping, and complete native validation boundary
are preserved in [UPSTREAM_VALIDATION.md](UPSTREAM_VALIDATION.md).

## Released and edge version matrix

`repro.rb` asserts correct behavior, so its expected result while the bug is
present is red: `7 runs, 8 assertions, 4 failures, 2 errors`. The candidate
validator must be green: `14 runs, 25 assertions, 0 failures, 0 errors`.

| Active Record | Upstream repro | Candidate fix | Raw evidence |
|---|---:|---:|---|
| 7.1.6 | 4 failures, 2 errors | 14/14 tests pass | [`repro`](results/repro-ar-7.1.6.log) · [`fix`](results/fix-ar-7.1.6.log) |
| 7.2.3.1 | 4 failures, 2 errors | 14/14 tests pass | [`repro`](results/repro-ar-7.2.3.1.log) · [`fix`](results/fix-ar-7.2.3.1.log) |
| 8.0.5 | 4 failures, 2 errors | 14/14 tests pass | [`repro`](results/repro-ar-8.0.5.log) · [`fix`](results/fix-ar-8.0.5.log) |
| 8.1.3 | 4 failures, 2 errors | 14/14 tests pass | [`repro`](results/repro-ar-8.1.3.log) · [`fix`](results/fix-ar-8.1.3.log) |
| 8.2.0.alpha at pinned main | 4 failures, 2 errors | 14/14 tests pass | [`repro`](results/repro-edge.log) · [`fix`](results/fix-edge.log) |

The compact issue version is separately captured in
[`results/issue-repro-edge.log`](results/issue-repro-edge.log): `5 runs, 6
assertions, 2 failures, 2 errors` on the same edge revision.

The test order is fixed with `--seed 1` only to make logs diffable. Every test
creates a fresh in-memory database, so order is not needed for correctness.

### What each failing test proves

| Test | Evidence | Upstream result |
|---|---|---|
| `test_control_single_line_where_is_preserved` | The supported feature and parser work when the predicate has no LF. | Passes |
| `test_public_add_index_with_heredoc_where_is_preserved` | No raw SQL escape hatch is required. SQLite says `partial=1`, the stored SQL ends in LF, and Rails returns nil. | Fails on `where=nil` after the two SQLite assertions pass |
| `test_raw_create_index_with_one_trailing_lf_preserves_where` | One terminal LF is sufficient; a statement need not otherwise be multiline. | Fails on `where=nil` |
| `test_raw_multiline_create_index_preserves_where` | The semicolon-free migration-heredoc shape fails. | Fails on `where=nil` |
| `test_schema_round_trip_preserves_partial_unique_semantics` | The migrated DB accepts a rejected and pending row for one key; the schema-loaded DB rejects the same pair. | Errors with `ActiveRecord::RecordNotUnique` on the second fresh-DB insert |
| `test_expression_index_with_trailing_lf_is_introspectable` | The same parse failure makes the expression fallback nil. | Errors with `NoMethodError: undefined method 'size' for nil` |
| `test_schema_dump_keeps_table_with_multiline_expression_index` | `SchemaDumper` catches that error at table scope rather than propagating it. | Fails because the returned schema contains `Could not dump table` and no `create_table` for the affected table |

## Exact causal chain: ordinary partial unique index

1. The public `add_index(..., where:)` path preserves the predicate string into
   generated SQL. Rails' exact implementation is linked in
   [SOURCES.md](SOURCES.md#rails-implementation-and-public-contract).
2. A squiggly heredoc contains a final LF by Ruby's documented semantics.
3. For this CREATE INDEX shape, SQLite's schema row retains that LF. This is
   directly asserted rather than inferred from SQLite's broader schema-text
   normalization contract.
4. Rails retrieves the schema SQL, then applies a regex whose dot does not
   match LF and whose `\z` requires the absolute string end.
5. The complete match fails. Ruby named captures `expressions` and `where`
   therefore become nil.
6. For an ordinary index, Rails obtains non-nil column names from
   `PRAGMA index_info`, so only `where` is visibly lost.
7. `SchemaDumper#index_parts` emits `where:` only when that value is non-nil.
   It therefore writes a full unique index with the same name and columns.
8. Loading that schema changes the business invariant. SQLite defines a unique
   partial index as uniqueness over only the predicate-selected rows; the full
   index enforces uniqueness over every row.

The round-trip test demonstrates the semantic change with writes, not merely
string comparison. Both inserts succeed before dumping. After loading the dump
into a fresh in-memory database, the second insert raises
`ActiveRecord::RecordNotUnique`.

This failure makes the schema-loaded database stricter than the migrated
database. It blocks valid writes; it does not weaken the constraint or permit
otherwise-invalid duplicate pending rows.

## Exact causal chain: expression index

SQLite documents that `PRAGMA index_info` returns a NULL column name when an
index term is an expression. Rails detects that nil and replaces the column
array with the parser's `expressions` capture. When the complete regex failed,
that capture is also nil. `IndexDefinition#concise_options` then evaluates
`columns.size`, causing the observed `NoMethodError`.

There are two distinct public outcomes:

- Calling `connection.indexes(table)` directly raises.
- `ActiveRecord::SchemaDumper` calls that method while constructing a table,
  catches the exception at table scope, writes a diagnostic comment, omits the
  whole table, and returns normally. The database task does not subsequently
  validate table completeness.

The second point corrects the earlier claim that `db:schema:dump` itself must
raise. The actual behavior is arguably more dangerous operationally: a dump can
complete while omitting a table.

## Trigger characterization

“Any newline fails” is false. The exact current behavior is produced and
asserted by [`script/trigger_matrix.rb`](script/trigger_matrix.rb); its captured
output is [`results/trigger-matrix.log`](results/trigger-matrix.log).

| Placement | Rails `where` | Why |
|---|---|---|
| No newline | Preserved | Control |
| Leading LF | Preserved | SQLite's documented normalization removes leading spaces |
| LF before `ON` | Preserved | Matching starts at `ON`; the regex is not start-anchored |
| LF between `)` and `WHERE` | Preserved | Existing `\s*` crosses line endings |
| LF inside the parenthesized capture | nil | Existing `.` cannot cross LF |
| LF inside the predicate capture | nil | Existing `.` cannot cross LF |
| One terminal LF | nil | Existing absolute `\z` cannot match before it |
| Two terminal LFs | nil | Same |
| Terminal CRLF | nil | Same |
| Terminal space, tab, or bare CR | Preserved with that terminator included in `where` | Dot consumes it, so the absolute anchor still matches |
| Semicolon | Preserved | For this input SQLite stores the SQL without the terminator |
| Semicolon plus terminal LF | Preserved | For this input SQLite stores neither terminator, so Rails sees a single line |

The accurate scope is therefore: semicolon-free, un-chomped heredocs are a
reliable trigger because of their terminal LF; newlines within either dot-based
capture also trigger the bug. Newlines consumed by an existing `\s*` need not.

## SQLite storage characterization

SQLite does not promise to store arbitrary CREATE SQL byte-for-byte. It
documents a copy of the original CREATE text subject to specific normalization.
For the affected statement shape, these direct probes all returned byte equality
and retained byte `10` at the end:

| sqlite3 gem | SQLite library | Input equals stored SQL | `PRAGMA partial` |
|---|---:|---:|---:|
| 1.7.3 | 3.45.2 | true | 1 |
| 2.5.0 | 3.47.2 | true | 1 |
| 2.9.5 | 3.53.2 | true | 1 |

Run [`script/sqlite_storage_probe.rb`](script/sqlite_storage_probe.rb) with
`SQLITE3_VERSION` to reproduce. Raw logs are in `results/sqlite-storage-*.log`.

## Fix design and why it has this exact shape

The validated candidate changes only the parser regex:

```ruby
/\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+?))?(?:\s*\/\*.*\*\/)?\s*\z/im
```

- `/m` is required because Ruby defines it to let dot include newline. That
  repairs newlines inside expression and predicate captures.
- `\s*\z` is required because expression indexes with no `WHERE` still have
  nothing after their closing parenthesis that can consume terminal whitespace.
  It also handles LF, CRLF, spaces, and tabs rather than special-casing one LF.
- Making `where` lazy allows final whitespace to be consumed outside the named
  capture, so the dumper does not preserve a migration's formatting terminator
  as part of the predicate.
- The full SQL string is not passed through `squish`. Rails implements `squish`
  by collapsing consecutive whitespace everywhere, including inside SQL string
  literals. The validator protects `WHERE note = 'two  spaces'` explicitly.
- No final `where.strip` is currently needed for the tested grammar because the
  lazy capture plus terminal whitespace group yields the desired predicate. A
  production PR should keep the patch minimal unless upstream tests identify a
  separate need.

### Alternatives rejected

| Alternative | Why it is incomplete or unsafe |
|---|---|
| `index_sql.strip` | Repairs the terminal-whitespace case but not newlines inside `expressions` or `where`. |
| Replace `\z` with `\Z` | Ruby permits only one ending LF there; it does not solve CRLF, multiple line endings, or internal newlines. |
| Add `/m` only | It does not give an expression index without `WHERE` a token that can consume whitespace after the closing parenthesis. |
| `index_sql.squish` or `gsub(/\s+/, " ")` | Can alter SQL literal contents and therefore the predicate's meaning. |
| `where&.strip` only | Runs after matching and cannot repair a complete-match failure. |

## Standalone and native validation coverage

[`fix_validation.rb`](fix_validation.rb) prepends a copied `#indexes` method
with the candidate regex and covers all of these cases on every version in the
matrix:

- unchanged single-line public API behavior;
- public API predicate supplied by heredoc;
- one terminal LF;
- terminal CRLF;
- terminal space, tab, bare CR, and repeated LF excluded from the predicate;
- multiline ordinary columns and predicate;
- expression index without `WHERE` plus terminal LF;
- multiline expression index with `WHERE`;
- multiline expression body through a full dump/load round-trip;
- ordinary partial-unique semantic round-trip;
- expression-index table retained by `SchemaDumper`;
- trailing block comment plus LF;
- two spaces inside a predicate string literal preserved exactly;
- Rails' existing nested expression and adjacent `)WHERE(` syntax unchanged.

A second, dependency-free comparison feeds all six index shapes from Rails'
existing single-line SQLite test corpus through the old and candidate regexes,
including the existing trailing-comment cleanup. Every `expressions` and `where`
capture is identical. See
[`script/parser_comparison.rb`](script/parser_comparison.rb) and its
[`captured output`](results/parser-comparison.log).

The validator contains query-method compatibility glue only because Rails main
renamed the internal query path used by released versions. That glue is test
harness code, not part of the proposed upstream change.

The upstream patch adds four native Minitest cases in
[`sqlite3_adapter_test.rb`](https://github.com/rameerez/rails/blob/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb/activerecord/test/cases/adapters/sqlite3/sqlite3_adapter_test.rb#L732-L809).
Together they cover every part of the one-line production change, including the
schema-dumper rescue boundary. The entire Active Record SQLite suite passed
locally after those cases were added.

## Why this satisfies the upstream-bug burden

- It reproduces through a documented Rails public API, not only arbitrary raw
  SQL.
- Rails explicitly reports support for both affected index features.
- SQLite independently reports that the index is partial.
- Rails' own generic schema-dumper contract expects supported partial predicates
  to be emitted.
- A schema dump/load changes observable uniqueness semantics.
- A second supported index form breaks introspection and causes silent table
  omission from the Ruby schema.
- The same parser and behavior exist in four release points and current main.
- A narrow candidate repair eliminates every positive reproduction while
  retaining controls and literal whitespace.

## Boundaries and remaining work

- This repository does not claim every newline fails, every heredoc shape fails,
  or SQLite stores every DDL string verbatim.
- It does not claim PostgreSQL or MySQL have the same implementation bug. MySQL
  is not a meaningful partial-index comparison because Rails documents partial
  index support only for PostgreSQL and SQLite.
- It does not claim every Rails test database is schema-loaded. Rails' documented
  default is to maintain the test schema from the configured schema file.
- `structure.sql` is a viable application workaround, but partial indexes are
  already a supported `schema.rb` feature, and the same predicate dumps correctly
  without the triggering formatting.
- This repository's CI validates standalone release/edge behavior. Separately,
  the native patch passed the complete Active Record SQLite suite locally; the
  Rails pull request's hosted cross-platform checks are the authoritative wider
  integration result.
- The existing parser has other known grammar limitations, notably
  [#55627](https://github.com/rails/rails/issues/55627). The candidate is a scoped
  newline fix, not a claim that regex parsing of arbitrary SQLite index SQL is
  now complete.
