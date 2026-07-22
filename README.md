# Rails SQLite3Adapter: partial-index `WHERE` silently dropped (and `indexes` can crash) for multi-line `CREATE INDEX` SQL

Self-contained repro + case file for an upstream Active Record bug. Everything an agent (or human) needs to file the issue or write the fix PR is in this repo — no other context required.

## TL;DR

SQLite stores `CREATE INDEX` statements **verbatim** in `sqlite_master`. The SQLite3 adapter recovers a partial index's `WHERE` clause by parsing that stored SQL with a regex that cannot tolerate a newline — not even **one trailing `"\n"`**. Any partial index created via a heredoc migration (`execute <<~SQL`) therefore:

1. **Dumps to schema.rb as a FULL unique index** (`where:` silently dropped) — every database provisioned from schema.rb (all Rails test DBs, every `db:schema:load` bootstrap) enforces a **stricter constraint than the migrated production database**. Silent data-integrity divergence.
2. For **expression** indexes (`ON t (LOWER(email))`), `connection.indexes` **hard-crashes** with `NoMethodError: undefined method 'size' for nil` — so `db:schema:dump` itself raises.

Confirmed on **AR 7.1.6, 7.2.3.1, 8.0.5, 8.1.3, and 8.2.0.alpha (rails main)** — identical failure signature everywhere. PostgreSQL and MySQL are unaffected (their servers return normalized/structured index definitions; only SQLite round-trips the user's raw SQL text), which is exactly what makes this a portability trap.

## Run it

```bash
ruby repro.rb                        # latest released Active Record
AR_VERSION="~> 7.1.0" ruby repro.rb  # any release line
AR_SOURCE=edge ruby repro.rb         # rails/rails main
```

Single file, `bundler/inline`, in-memory SQLite, minitest — modeled on the official [Active Record bug report template](https://github.com/rails/rails/blob/main/guides/bug_report_templates/active_record.rb). The tests assert the **correct** behavior, so failures demonstrate the bug. Expected output on every version: `5 runs … 2 failures, 2 errors` — the control (single-line, no trailing newline) passes, everything else fails. Captured runs live in `results/`.

| Test | What it proves | Result |
|---|---|---|
| `test_control_single_line…` | the parser works for exactly one formatting | ✅ passes |
| `test_trailing_newline…` | ONE trailing `"\n"` is the minimal trigger → `where` = nil | ❌ fails |
| `test_heredoc…` | the real-world migration shape → `where` = nil | ❌ fails |
| `test_schema_roundtrip…` | dump → load → an INSERT that the migrated DB accepts raises `RecordNotUnique` in the schema-loaded DB | ❌ errors |
| `test_multiline_expression_index…` | expression + multi-line → `connection.indexes` raises `NoMethodError` | ❌ errors |

## Root cause (exact)

`activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb`, `#indexes` (line ~24 on main; byte-identical regex from 7.1 through main as of 2026-07-22):

```ruby
/\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+))?(?:\s*\/\*.*\*\/)?\z/i =~ index_sql
```

Three interacting properties:

- **No `/m`** → `.` never matches `\n`, so `(?<where>.+)` cannot cross (or consume) a newline.
- **`\z` anchor** → absolute end-of-string; not even a trailing newline is allowed after the clause (`\Z` would tolerate exactly that; `\z` doesn't).
- `index_sql` comes from `SELECT sql FROM sqlite_master`, which is the **verbatim** text of the original `CREATE INDEX` — a heredoc migration stores internal newlines *and* a trailing newline.

So for heredoc SQL the entire regex fails to match (nothing anchors), and **both** named captures come back nil:

- `where` → nil. The index itself still appears in the dump because the **columns come from `PRAGMA index_info`**, not from the regex — this is what makes the WHERE loss *silent*: nothing errors, schema.rb just quietly gains a stricter index.
- `expressions` → nil. For plain-column indexes that's masked (PRAGMA has the columns). For **expression** indexes, `PRAGMA index_info` yields nil column names, so the code falls back to `columns = expressions` = nil… and `IndexDefinition#initialize` → `concise_options` calls `columns.size` → **`NoMethodError`** (`abstract/schema_definitions.rb`, `concise_options`). This second symptom is a crash, not silence — `connection.indexes(table)` and therefore `db:schema:dump` raise.

## How we found it

During a pre-release audit of a Rails engine gem ([rameerez/organizations](https://github.com/rameerez/organizations) v0.5.0), whose migrations create three partial unique indexes via `execute <<~SQL` (business invariants like "at most one OWNER membership per organization", "one PENDING join request per user per org"). The checked-in dummy-app schema.rb had one of the three indexes without its `where:` — while the other two kept theirs. The discrepancy turned out to be *history*, not code: the two surviving indexes' `sqlite_master` rows had been created by an older single-line form of the migration, while the newest index was created by the current heredoc form. A controlled probe (three multi-line indexes + one single-line control in a fresh `:memory:` DB, then `SchemaDumper.dump`) reproduced it deterministically: **all** multi-line variants lose `where:`, the single-line control keeps it. Downstream impact in that gem before the fix: a database provisioned from the broken schema.rb enforced "one join request per user EVER" instead of "one *pending* request" — a user whose request was rejected could never request again (`RecordNotUnique` through a passing model validation). The gem's fix was to keep index SQL on one line (with a comment warning against re-prettifying); this repro exists to get the *actual* bug fixed upstream.

## Steelman: anticipated objections, answered

1. **"Use `add_index …, where:` instead of raw SQL."** Best practice today, yes — and it's how the gem fixed itself. But `execute` is a fully supported migration primitive, heredocs are the idiomatic way to write multi-line SQL in Ruby, partial indexes via raw SQL predate `where:` support and live in countless legacy migrations. A supported input producing a **silently wrong** dump of a **UNIQUE constraint** is a data-integrity bug regardless of whether a nicer API exists. And the expression-index variant doesn't degrade — it *crashes* `db:schema:dump`, which cannot be intended behavior under any reading.
2. **"schema.rb can't express everything; use structure.sql."** Partial indexes are not in that category: `where:` is a first-class, documented schema.rb feature, and the dumper emits it correctly for the single-line case. This is a parser failing on *formatting* of a feature the format fully supports — not an expressiveness limit.
3. **"It's SQLite."** SQLite is a blessed production database in Rails 8 (the Solid-stack default story), and even for PG/MySQL production apps, **test databases are provisioned from schema.rb** — CI silently enforces different uniqueness semantics than production. That divergence is the worst failure mode of a schema dumper.
4. **"Is it really unreported?"** Closest prior art, neither covering this trigger:
   - [rails/rails#55627](https://github.com/rails/rails/issues/55627) — *same regex*, different trigger (unconventional table names break the `"?(\w+?)"?` table capture). Closed **stale**, unfixed. Signals: (a) the parser is a known fragility, (b) reports without patches die — a fix PR should accompany or quickly follow the issue.
   - [rails/rails#31603](https://github.com/rails/rails/issues/31603) (2017) — partial index lost through SQLite's table-recreation (`alter_table` copy) path; different code path.

## Suggested fix (for the PR)

Two candidate shapes, smallest first:

1. **Normalize before parsing** — `index_sql = index_sql.strip if index_sql` right after the `sqlite_master` read. Fixes the trailing-newline trigger (every heredoc) with zero regex risk, but not internal newlines *between* `ON …(…)` and `WHERE`… actually `\s*` already crosses those; the remaining internal-newline case is a WHERE clause spanning lines, which `strip` alone doesn't cure.
2. **Make the regex newline-proof** (complete fix):

   ```ruby
   /\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+?))?(?:\s*\/\*.*\*\/)?\s*\z/im
   ```

   i.e. add `/m` (let `.` cross newlines), make the `where` capture lazy (`.+?`), and anchor with `\s*\z` so trailing whitespace/newlines are consumed outside the capture. Existing post-processing (`where.sub(/\s*\/\*.*\*\/\z/, "")`) keeps working; consider a final `where&.strip`. Avoid the tempting `index_sql.gsub(/\s+/, " ")` — it would corrupt string literals inside WHERE clauses (`WHERE note = 'two  spaces'`).

   **Candidate 2 is VALIDATED**: `fix_validation.rb` runs the same five tests against an `#indexes` monkey-patched with exactly this regex — **6 runs / 0 failures** (the five bug tests plus a regression guard proving WHERE clauses with multi-space string literals survive). See `results/fix-validation.log`.

Regression tests belong in `activerecord/test/cases/adapters/sqlite3/sqlite3_adapter_test.rb` (grep for existing `def test.*index.*where` cases): trailing-newline, heredoc, heredoc + expression index, and ideally a schema round-trip.

## Filing checklist for the next agent

1. `ISSUE_DRAFT.md` in this repo is ready to paste into a new rails/rails issue (repro script inlined, per their bug-report guidelines). Re-run `AR_SOURCE=edge ruby repro.rb` first and update the version line if main moved.
2. Given #55627 died stale, strongly prefer opening the **PR** (fix candidate 2 + tests) alongside or instead of the issue; link both.
3. CVE-worthiness: no — it requires the app's own migrations, isn't attacker-controllable. It's a correctness bug, not a vulnerability; file publicly.

## Repo contents

- `repro.rb` — the executable test case (this is also the artifact to inline in the issue).
- `fix_validation.rb` — the same tests against a monkey-patched `#indexes` carrying the proposed regex; all green (plus the multi-space-literal regression guard). This is effectively the PR's diff + tests, pre-validated.
- `results/` — captured runs: `ar-710.log` (7.1.6), `ar-720.log` (7.2.3.1), `ar-800.log` (8.0.5), `ar-latest.log` (8.1.3), `ar-edge.log` (8.2.0.alpha/main) — all `2 failures, 2 errors` with the control passing — and `fix-validation.log` (6/0F on the patch).
- `ISSUE_DRAFT.md` — ready-to-file upstream issue text.
