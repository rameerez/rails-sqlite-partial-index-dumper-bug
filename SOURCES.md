# Primary-source ledger

This file maps every material technical claim and implementation decision in
this repository to an exact upstream location. Rails links are immutable commit
or release-tag permalinks. The edge revision audited on 2026-07-22 is
[`d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096`](https://github.com/rails/rails/commit/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096),
which was also the tip of `rails/rails:main` when the evidence was regenerated.

## Filed upstream contribution

| Artifact or decision | Exact source |
|---|---|
| Canonical upstream bug report. | [rails/rails#58200](https://github.com/rails/rails/issues/58200) |
| Canonical upstream fix pull request. | [rails/rails#58201](https://github.com/rails/rails/pull/58201) |
| Submitted commit based on the audited Rails revision. | [`a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb`](https://github.com/rails/rails/pull/58201/commits/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb) |
| The production change is one parser line. | [Submitted `schema_statements.rb`, line 24](https://github.com/rameerez/rails/blob/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L24) |
| Four native regressions cover multiline predicates, terminal newlines, expression indexes, literal whitespace, and schema dumping. | [Submitted `sqlite3_adapter_test.rb`, lines 732-809](https://github.com/rameerez/rails/blob/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb/activerecord/test/cases/adapters/sqlite3/sqlite3_adapter_test.rb#L732-L809) |
| The changelog entry follows this checkout's explicit bug-fix instruction. | [Submitted `activerecord/CHANGELOG.md`, lines 1-3](https://github.com/rameerez/rails/blob/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb/activerecord/CHANGELOG.md#L1-L3) · [Rails `AGENTS.md`, lines 128-134](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/AGENTS.md#L128-L134) |
| Exact native red/green commands, seeds, outputs, and validation boundaries. | [Native Rails validation record](UPSTREAM_VALIDATION.md) |
| All Rails-hosted checks passed on the submitted SHA. | [Rails Buildkite #131320](https://buildkite.com/rails/rails/builds/131320) · [`rails-new-docker` run 29885637092](https://github.com/rails/rails/actions/runs/29885637092) · [docs-preview #20921](https://buildkite.com/rails/docs-preview/builds/20921) · [labeler run 29885636090](https://github.com/rails/rails/actions/runs/29885636090) |
| The public case-file matrix passed after issue/PR cross-linking. | [Verification run 29885712858](https://github.com/rameerez/rails-sqlite-partial-index-dumper-bug/actions/runs/29885712858) |

## Rails implementation and public contract

| Claim or decision | Exact source |
|---|---|
| SQLite index introspection reads `sqlite_master.sql`, applies the affected regex, gets ordinary columns from `PRAGMA index_info`, substitutes the regex's `expressions` capture when a PRAGMA column name is nil, and builds `IndexDefinition` with the captured `where`. | [`sqlite3/schema_statements.rb`, lines 7-52](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L7-L52) |
| The exact parser line under test is line 24. | [`sqlite3/schema_statements.rb`, line 24](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L24) |
| Rails explicitly advertises both partial-index and expression-index support for SQLite. | [`sqlite3_adapter.rb`, lines 209-214](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/sqlite3_adapter.rb#L209-L214) |
| `add_index(..., where:)` is documented for PostgreSQL and SQLite. | [`abstract/schema_statements.rb`, lines 909-917](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_statements.rb#L909-L917) |
| The `where` option is carried into the index definition without whitespace normalization. | [`abstract/schema_statements.rb`, lines 1601-1623](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_statements.rb#L1601-L1623) |
| SQL generation appends `WHERE #{index.where}` and joins fragments with spaces; it does not strip the predicate. This is why a terminal LF supplied through the public API reaches SQLite. | [`abstract/schema_creation.rb`, lines 106-123](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_creation.rb#L106-L123) |
| `IndexDefinition` stores `columns`, then `concise_options` calls `columns.size`; a nil expression fallback therefore raises the observed `NoMethodError`. | [`abstract/schema_definitions.rb`, lines 20-40 and 64-71](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_definitions.rb#L20-L71) |
| Schema dumping emits `where:` only when introspection returned a non-nil predicate. | [`schema_dumper.rb`, lines 285-295](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/schema_dumper.rb#L285-L295) |
| Schema dumping rescues failures at table scope, writes `Could not dump table`, omits that table, and continues. This corrects the tempting but false claim that the expression-index case necessarily makes `db:schema:dump` exit nonzero. | [`schema_dumper.rb`, lines 225-248](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/schema_dumper.rb#L225-L248) |
| The Ruby-schema database task opens the destination for writing and calls `SchemaDumper.dump`; no later completeness validation rejects a table-omission diagnostic. | [`database_tasks.rb`, lines 450-475](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/tasks/database_tasks.rb#L450-L475) |
| Rails' generic dumper test treats preservation of `where:` as expected behavior whenever the adapter reports partial-index support. | [`schema_dumper_test.rb`, lines 250-257](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/test/cases/schema_dumper_test.rb#L250-L257) |
| Existing SQLite tests cover partial indexes with comments and single-line expression indexes, but not a terminal newline or multiline captures. | [`sqlite3_adapter_test.rb`, lines 723-773](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/test/cases/adapters/sqlite3/sqlite3_adapter_test.rb#L723-L773) |
| `execute` is a documented migration escape hatch when helpers are insufficient. | [Active Record Migrations guide, lines 868-880](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/guides/source/active_record_migrations.md#L868-L880) |
| `db:migrate` invokes `db:schema:dump`. | [Active Record Migrations guide, lines 1210-1218](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/guides/source/active_record_migrations.md#L1210-L1218) |
| Rails says the database is the source of truth; `schema.rb` attempts to capture it, is the default format, and is used to create new databases. | [Active Record Migrations guide, lines 1552-1609](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/guides/source/active_record_migrations.md#L1552-L1609) |
| Rails also says the schema file is authoritative for rebuilding a database. | [Active Record Migrations guide, lines 1721-1726](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/guides/source/active_record_migrations.md#L1721-L1726) |
| Test-schema maintenance from `schema.rb` or `structure.sql` defaults to true. The accurate claim is therefore “default Rails test setup,” not “every test database.” | [Configuration guide, lines 1292-1296](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/guides/source/configuring.md#L1292-L1296) |
| Active Record 7.1's dumper entry point accepts a connection. | [`v7.1.6/schema_dumper.rb`, lines 43-47](https://github.com/rails/rails/blob/v7.1.6/activerecord/lib/active_record/schema_dumper.rb#L43-L47) |
| Active Record 7.2's dumper entry point accepts a pool. The repro detects this API change so the 7.1 run reaches the actual uniqueness failure. | [`v7.2.3.1/schema_dumper.rb`, lines 43-49](https://github.com/rails/rails/blob/v7.2.3.1/activerecord/lib/active_record/schema_dumper.rb#L43-L49) |
| `String#squish` collapses all consecutive internal whitespace. Applying it to complete index SQL could mutate a SQL string literal, so the candidate fix deliberately does not use it. | [`filters.rb`, lines 3-26](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activesupport/lib/active_support/core_ext/string/filters.rb#L3-L26) |

## Parser provenance across versions

The complete parser line has SHA-256
`4d2203a33bf826e388379e1c2d708a4355b2c76eee1adf3cc781999f93b4051a`
in every tested version. These links make the comparison independently
reviewable:

- [Active Record 7.1.6](https://github.com/rails/rails/blob/v7.1.6/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L24)
- [Active Record 7.2.3.1](https://github.com/rails/rails/blob/v7.2.3.1/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L24)
- [Active Record 8.0.5](https://github.com/rails/rails/blob/v8.0.5/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L24)
- [Active Record 8.1.3](https://github.com/rails/rails/blob/v8.1.3/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L24)
- [Rails main at `d9e67f6`](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L24)

## Ruby and SQLite semantics

| Claim | Exact source |
|---|---|
| A Ruby heredoc result includes its ending newline; the same section documents squiggly heredocs. | [Ruby 3.4 literal syntax, “Here Document Literals”](https://docs.ruby-lang.org/en/3.4/syntax/literals_rdoc.html#label-Here+Document+Literals) |
| Without `/m`, dot excludes newline; with `/m`, dot includes newline. | [Ruby 3.4 `Regexp`, “Shorthand Character Classes”](https://docs.ruby-lang.org/en/3.4/Regexp.html#class-Regexp-label-Shorthand+Character+Classes) |
| `\Z` permits one final newline while `\z` means the exact string end. | [Ruby 3.4 `Regexp`, “Boundary Anchors”](https://docs.ruby-lang.org/en/3.4/Regexp.html#class-Regexp-label-Boundary+Anchors) |
| SQLite stores a copy of the original CREATE text subject to explicitly documented normalization. The repo therefore says “retains the affected terminal LF for these inputs,” not “stores all SQL verbatim.” | [SQLite schema-table documentation, `sql` column](https://www.sqlite.org/schematab.html#interpretation_of_the_schema_table) |
| `PRAGMA index_list` column 5 is SQLite's independent partial-index flag. | [SQLite `PRAGMA index_list`](https://www.sqlite.org/pragma.html#pragma_index_list) |
| `PRAGMA index_info` reports expression-index entries with table-column rank `-2` and a NULL column name; Rails sees that nil and falls back to its regex capture. | [SQLite `PRAGMA index_info`](https://www.sqlite.org/pragma.html#pragma_index_info) |
| A partial index indexes only a subset of rows, and a unique partial index enforces uniqueness only for that subset. | [SQLite Partial Indexes, sections 1 and 2.1](https://www.sqlite.org/partialindex.html) |
| SQLite supports indexes on expressions. | [SQLite Indexes On Expressions](https://www.sqlite.org/expridx.html) |

The exact retention behavior is also tested rather than inferred from the
documentation: [`script/sqlite_storage_probe.rb`](script/sqlite_storage_probe.rb)
asserts input equality, terminal LF, and `partial=1` with sqlite3 gems 1.7.3,
2.5.0, and 2.9.5.

## Prior art and current neighboring work

- [rails/rails#31603](https://github.com/rails/rails/issues/31603) reported the
  same broad outcome in 2017 through SQLite table recreation. It was fixed by
  merged [rails/rails#31607](https://github.com/rails/rails/pull/31607); that is a
  different code path.
- [rails/rails#53570](https://github.com/rails/rails/pull/53570) changed this
  parser to handle trailing index comments and was merged in 2024. It confirms
  that faithful SQLite index introspection is maintained behavior.
- [rails/rails#55627](https://github.com/rails/rails/issues/55627) reports the
  same regex failing on unconventional but valid table names. It was closed
  `not_planned` with the `stale` label on 2025-12-12, without a fix. It does not
  report the newline trigger.
- [rails/rails#58136](https://github.com/rails/rails/pull/58136) is an open 2026
  change for multiline virtual tables, generated columns, and collations. Its
  [exact commit](https://github.com/rails/rails/commit/8447e67bcc7172113c894abd1e8b41080a8f569c)
  touches other SQLite parsers, not `sqlite3/schema_statements.rb#indexes`. The
  PR's “Additional information” explicitly notes that `squish` also collapses
  whitespace inside string literals. That acknowledged trade-off is why this
  index-predicate fix does not transplant its whole-SQL normalization approach.
- Targeted GitHub issue/PR searches on 2026-07-22 for `sqlite partial index
  newline`, `sqlite index heredoc where schema dump`, `sqlite expression index
  newline`, and `"sqlite_master" "partial index" newline` returned no direct
  report. Search absence is supporting context, not proof of nonexistence.

## Contribution-process decisions

- Rails asks for an executable failing test and provides an Active Record
  template: [contribution guide, lines 23-54](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/guides/source/contributing_to_ruby_on_rails.md#L23-L54)
  and the pinned [Active Record template](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/guides/bug_report_templates/active_record.rb).
- Rails requires tests that fail before and pass after a code change:
  [contribution guide, lines 275-283](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/guides/source/contributing_to_ruby_on_rails.md#L275-L283).
- The general guide says a bug-fix changelog is unnecessary and minor fixes
  generally should not get one: [lines 275-283](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/guides/source/contributing_to_ruby_on_rails.md#L275-L283)
  and [lines 614-620](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/guides/source/contributing_to_ruby_on_rails.md#L614-L620).
  The checkout-specific `AGENTS.md` explicitly says to add one when fixing bugs,
  so the submitted patch follows that more specific repository instruction:
  [`AGENTS.md`, lines 128-134](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/AGENTS.md#L128-L134).
- The PR is ready for review rather than a draft and follows the required body
  sections and checklist: [Rails PR template, lines 1-45](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/.github/pull_request_template.md#L1-L45).
- Rails explicitly distinguishes ordinary public bug reports from security
  reports: [contribution guide, lines 23-34 and 56-58](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/guides/source/contributing_to_ruby_on_rails.md#L23-L58).
  This repository concerns deterministic schema correctness from an
  application's own DDL, not attacker-controlled input, so the ordinary public
  contribution path is appropriate.
