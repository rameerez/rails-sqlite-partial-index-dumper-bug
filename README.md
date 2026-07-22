# Rails SQLite index introspection loses multiline partial predicates

[![Verification](https://github.com/rameerez/rails-sqlite-partial-index-dumper-bug/actions/workflows/ci.yml/badge.svg)](https://github.com/rameerez/rails-sqlite-partial-index-dumper-bug/actions/workflows/ci.yml)

Executable reproduction and source-backed audit of an Active Record
SQLite3Adapter bug. A terminal newline—or a newline inside one of the parser's
dot-based captures—can make Rails forget a partial index's `WHERE` clause. An
expression index can instead break introspection and cause `schema.rb` to omit
the entire table.

Status: **confirmed on Active Record 7.1.6, 7.2.3.1, 8.0.5, 8.1.3, and Rails
main at [`d9e67f6`](https://github.com/rails/rails/commit/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096).**
This is an ordinary correctness bug, not a security vulnerability. It is filed
upstream as [rails/rails#58200](https://github.com/rails/rails/issues/58200),
with the tested fix in
[rails/rails#58201](https://github.com/rails/rails/pull/58201).

## Upstream issue and native fix

The upstream artifacts are deliberately cross-linked and independently
reviewable:

- [Issue #58200](https://github.com/rails/rails/issues/58200) contains the
  compact executable reproduction and exact causal chain.
- [Pull request #58201](https://github.com/rails/rails/pull/58201) contains the
  one-line adapter fix, four native Minitest regressions, and the Active Record
  changelog entry.
- [Commit `a4f3c229b8`](https://github.com/rails/rails/pull/58201/commits/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb)
  is based on the same pinned Rails revision used by this audit.
- The exact submitted [parser line](https://github.com/rameerez/rails/blob/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L24)
  and [regression tests](https://github.com/rameerez/rails/blob/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb/activerecord/test/cases/adapters/sqlite3/sqlite3_adapter_test.rb#L732-L809)
  are immutable links into the submitted commit.

The native tests were run without the fix first. They reproduced predicate
loss, expression-index `NoMethodError`, and schema-dump table omission. With the
fix applied, validation on Ruby 3.4.2 and sqlite3 2.9.5 produced:

```text
Focused regressions:          4 runs,    11 assertions, 0 failures, 0 errors
sqlite3_adapter_test.rb:    101 runs,   253 assertions, 0 failures, 0 errors
Full Active Record SQLite: 9,643 runs, 32,864 assertions, 0 failures, 0 errors, 38 skips
RuboCop:                       3 files inspected, no offenses detected
```

## The shortest convincing proof

This is not limited to raw `execute` SQL. The documented public API triggers it:

```ruby
connection.add_index :join_requests, [:organization_id, :user_id],
  unique: true,
  name: :idx_pending,
  where: <<~SQL
    status = 'pending'
  SQL
```

After that call:

- SQLite's structured `PRAGMA index_list` metadata says the index is both unique
  and partial (`partial=1`). [SQLite documents that field
  exactly](https://www.sqlite.org/pragma.html#pragma_index_list).
- SQLite's stored CREATE text ends with the heredoc's LF for this input.
- `connection.indexes(:join_requests)` returns the index with `unique=true` but
  `where=nil`.
- `schema.rb` consequently emits a full unique index. Loading it into a fresh
  database changes the constraint from “one pending request per key” to “one
  request per key regardless of status.”

The round-trip test proves the semantic payload: a rejected row followed by a
pending row succeeds in the migrated database, while the same writes against a
schema-loaded database raise `ActiveRecord::RecordNotUnique`.

[`repro.rb`](repro.rb) makes every step executable. The complete reasoning,
trigger map, raw outputs, corrections to earlier hypotheses, and fix analysis
are in [EVIDENCE.md](EVIDENCE.md). Every external claim is mapped to an exact
primary source in [SOURCES.md](SOURCES.md).

## Run it

Ruby 3.4.2 is recorded in [`.ruby-version`](.ruby-version). The scripts use
`bundler/inline` and in-memory SQLite; there is no application setup.

```bash
# Intentionally red: tests assert the correct Rails behavior.
ruby repro.rb

# Green only when the complete known upstream failure signature is present.
ruby script/verify_bug.rb

# Green validation of the candidate parser change.
ruby fix_validation.rb
```

Test exact releases or current Rails main:

```bash
AR_VERSION=7.1.6 ruby script/verify_bug.rb
AR_VERSION=7.2.3.1 ruby script/verify_bug.rb
AR_VERSION=8.0.5 ruby script/verify_bug.rb
AR_VERSION=8.1.3 ruby script/verify_bug.rb
AR_SOURCE=edge ruby script/verify_bug.rb

AR_VERSION=7.1.6 ruby fix_validation.rb
AR_SOURCE=edge ruby fix_validation.rb
```

The direct repro is supposed to exit nonzero with:

```text
7 runs, 8 assertions, 4 failures, 2 errors, 0 skips
```

The wrapper rejects partial, incidental, or changed failures; it checks all six
affected test names, `RecordNotUnique`, the expression-index `NoMethodError`, the
schema-dumper diagnostic, and the exact summary. The candidate validator exits
zero with:

```text
14 runs, 25 assertions, 0 failures, 0 errors, 0 skips
```

## What actually fails

| Case | Current upstream behavior |
|---|---|
| Single-line `where:` control | Correctly returns the predicate |
| Public `add_index` with a heredoc predicate | SQLite says partial; Rails returns `where=nil` |
| Otherwise single-line raw SQL plus one final LF | Rails returns `where=nil` |
| Semicolon-free multiline migration heredoc | Rails returns `where=nil` |
| Dump/load of the partial unique index | Valid second insert raises `RecordNotUnique` |
| Expression index plus final LF | `connection.indexes` raises `NoMethodError` |
| Schema dump with that expression index | Dumper catches the error, writes `Could not dump table`, omits the entire table, and returns normally |

That final row is important. The expression-index case does **not** necessarily
make `db:schema:dump` exit nonzero: Rails rescues at table scope in
[`SchemaDumper#table`](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/schema_dumper.rb#L225-L248).
The reproducible result is a diagnostic comment and a missing table.

## Root cause

Rails main parses `sqlite_master.sql` here:
[`sqlite3/schema_statements.rb:7-52`](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L7-L52).
The exact line is:

```ruby
/\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+))?(?:\s*\/\*.*\*\/)?\z/i =~ index_sql
```

Two Ruby regex rules interact:

- Dot excludes newline without `/m`; [Ruby documents `/./` versus
  `/./m`](https://docs.ruby-lang.org/en/3.4/Regexp.html#class-Regexp-label-Shorthand+Character+Classes).
- `\z` means the exact end of the string and does not tolerate a final LF;
  [Ruby distinguishes `\Z` and `\z`
  explicitly](https://docs.ruby-lang.org/en/3.4/Regexp.html#class-Regexp-label-Boundary+Anchors).

Ruby also documents that [a heredoc result includes its ending
newline](https://docs.ruby-lang.org/en/3.4/syntax/literals_rdoc.html#label-Here+Document+Literals).
Rails carries a public `where:` string through index definition and SQL creation
without stripping it:
[`add_index_options`](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_statements.rb#L1601-L1623)
and
[`visit_CreateIndexDefinition`](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_creation.rb#L106-L123).

When the complete match fails, both named captures are nil. Ordinary columns
still come from `PRAGMA index_info`, so predicate loss is silent. SQLite returns
a NULL name for an expression term; Rails then substitutes the nil
`expressions` capture and `IndexDefinition` calls `columns.size`, explaining the
second symptom exactly:
[`schema_statements.rb:26-50`](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L26-L50),
[`schema_definitions.rb:64-71`](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_definitions.rb#L64-L71),
and [SQLite's `PRAGMA index_info`
contract](https://www.sqlite.org/pragma.html#pragma_index_info).

## Precise trigger scope

The old shorthand “any newline” was too broad. The green characterization probe
[`script/trigger_matrix.rb`](script/trigger_matrix.rb) establishes:

- terminal LF, repeated terminal LFs, and CRLF fail;
- terminal space, tab, and bare CR match but are currently retained inside the
  returned `where` string;
- newline inside the expression/column capture or predicate capture fails;
- leading newline, newline before `ON`, and newline immediately before `WHERE`
  can survive because SQLite normalization or an existing `\s*` handles them;
- a semicolon-terminated input is not the same trigger in this setup because
  SQLite stores it without the semicolon and trailing LF.

Likewise, SQLite's precise contract is not “verbatim storage.” It stores a copy
of CREATE text with [documented
normalization](https://www.sqlite.org/schematab.html#interpretation_of_the_schema_table).
Our narrower empirical claim—this affected SQL retains its final LF byte—is
asserted across sqlite3 gems 1.7.3, 2.5.0, and 2.9.5 by
[`script/sqlite_storage_probe.rb`](script/sqlite_storage_probe.rb).

## Why this is unambiguously a Rails bug

- Rails [documents partial indexes for PostgreSQL and
  SQLite](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/abstract/schema_statements.rb#L909-L917)
  and reports both partial- and expression-index support in the
  [SQLite adapter](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/lib/active_record/connection_adapters/sqlite3_adapter.rb#L209-L214).
- The strongest reproducer uses that documented public `add_index` API.
- Rails' generic dumper test expects `where:` whenever an adapter reports
  support: [`schema_dumper_test.rb:250-257`](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/test/cases/schema_dumper_test.rb#L250-L257).
- The database's independent metadata contradicts the Rails object.
- The dump/load changes actual uniqueness semantics, not merely formatting.
- Rails says `schema.rb` attempts to capture the database and is the default
  source used to build new databases: [migration guide,
  lines 1552-1609](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/guides/source/active_record_migrations.md#L1552-L1609).
- The bug remains on current main, and the exact parser line is byte-identical
  across every tested version.

Using `structure.sql` is an application workaround, not a rebuttal: partial
indexes are already representable by `schema.rb`, and the dumper handles the
same index correctly when formatting avoids the parser defect.

## Implemented and validated fix

The narrow fix submitted in
[rails/rails#58201](https://github.com/rails/rails/pull/58201) is:

```ruby
/\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+?))?(?:\s*\/\*.*\*\/)?\s*\z/im
```

It adds `/m`, makes the predicate lazy, and consumes final whitespace outside
the capture. [`fix_validation.rb`](fix_validation.rb) applies that regex to a
copy of `#indexes` and passes all 14 positive/regression cases across the entire
release/edge matrix. The upstream commit applies the same change directly to
the adapter and adds native coverage beside Rails' existing SQLite index tests.

It intentionally does not normalize the whole SQL with `squish` or
`gsub(/\s+/, " ")`. Rails' [`String#squish`
implementation](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activesupport/lib/active_support/core_ext/string/filters.rb#L3-L26)
collapses internal whitespace, which can change a predicate such as
`WHERE note = 'two  spaces'`. The validator has an exact regression guard for
that case.

The native Rails patch was also proven red before green and passed the complete
Active Record SQLite suite. Its [submitted tests](https://github.com/rameerez/rails/blob/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb/activerecord/test/cases/adapters/sqlite3/sqlite3_adapter_test.rb#L732-L809)
exercise the public-API predicate, terminal-newline expression, combined
multiline expression/predicate, literal whitespace, and full schema-dump paths.

## Prior art checked

- [#31603](https://github.com/rails/rails/issues/31603), fixed by
  [#31607](https://github.com/rails/rails/pull/31607): same broad partial-index
  loss, different SQLite table-recreation path.
- [#53570](https://github.com/rails/rails/pull/53570): merged fix to this parser
  for trailing comments, reinforcing that accurate introspection is intended.
- [#55627](https://github.com/rails/rails/issues/55627): same regex, different
  unconventional-table-name trigger; closed stale without a fix.
- [#58136](https://github.com/rails/rails/pull/58136): open multiline SQLite
  parser work for virtual tables, generated columns, and collations; it does not
  modify index introspection.

Targeted issue/PR searches found no direct report of this newline trigger as of
2026-07-22. Full query details and exact states are in [SOURCES.md](SOURCES.md).

## Repository map

- [`repro.rb`](repro.rb): intentionally failing, public-API-first bug report.
- [`issue_repro.rb`](issue_repro.rb): compact, edge-only version for the eventual
  upstream issue body.
- [`script/verify_bug.rb`](script/verify_bug.rb): green CI oracle for the exact
  upstream failure signature.
- [`fix_validation.rb`](fix_validation.rb): all-green candidate-fix validation.
- [`script/trigger_matrix.rb`](script/trigger_matrix.rb): exact newline placement
  characterization.
- [`script/sqlite_storage_probe.rb`](script/sqlite_storage_probe.rb): storage and
  structured-metadata probe across SQLite binding versions.
- [`script/parser_comparison.rb`](script/parser_comparison.rb): proves unchanged
  captures for Rails' existing single-line SQLite index corpus.
- [`EVIDENCE.md`](EVIDENCE.md): full proof, corrections, causal chain, candidate
  design, and explicit boundaries.
- [`SOURCES.md`](SOURCES.md): immutable source ledger for every material claim.
- [`ISSUE_DRAFT.md`](ISSUE_DRAFT.md): preserved source for the filed
  [upstream issue](https://github.com/rails/rails/issues/58200).
- [`PR_DRAFT.md`](PR_DRAFT.md): preserved source for the filed
  [upstream fix](https://github.com/rails/rails/pull/58201).
- [`results/`](results): deterministic raw logs for releases, edge, candidate
  validation, trigger mapping, and storage probes.
- [`.github/workflows/ci.yml`](.github/workflows/ci.yml): public CI matrix.

## Regenerate all checked-in evidence

```bash
ruby script/capture_results.rb
```

This rewrites the release/edge, fix, trigger, and SQLite storage logs only after
each expected result is verified.
