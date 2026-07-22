# Native Rails validation record

This record complements the standalone release matrix with validation performed
inside a full Rails checkout. It describes the exact final patch submitted in
[rails/rails#58201](https://github.com/rails/rails/pull/58201), not the
monkey-patched harness in `fix_validation.rb`.

## Snapshot

- Audit date: 2026-07-22
- Base Rails commit:
  [`d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096`](https://github.com/rails/rails/commit/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096)
- Submitted patch commit:
  [`a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb`](https://github.com/rails/rails/pull/58201/commits/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb)
- Ruby: 3.4.2
- sqlite3 gem: 2.9.5
- SQLite library: 3.53.2
- Production change:
  [`schema_statements.rb:24`](https://github.com/rameerez/rails/blob/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb/activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb#L24)
- Native regressions:
  [`sqlite3_adapter_test.rb:732-809`](https://github.com/rameerez/rails/blob/a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb/activerecord/test/cases/adapters/sqlite3/sqlite3_adapter_test.rb#L732-L809)

The Rails branch was exactly one commit above the base when these commands ran.
Both worktrees were clean after the submitted commit was pushed.

## Red phase: exact native tests against the original parser

The four final regression tests were left in place while only the production
regex was restored to the base revision. This command ran from `activerecord/`:

```bash
ARCONN=sqlite3_mem RBENV_VERSION=3.4.2 rbenv exec bundle exec ruby \
  -Itest test/cases/adapters/sqlite3/sqlite3_adapter_test.rb \
  -i '/(test_partial_index_with_multiline_where|test_expression_index_with_trailing_newline|test_multiline_expression_index_with_where|test_schema_dump_with_multiline_expression_index)/' \
  --seed 1
```

Exact summary:

```text
4 runs, 4 assertions, 2 failures, 2 errors, 0 skips
```

The outcomes map one-to-one to the claimed defect:

| Native regression | Unpatched outcome |
|---|---|
| `test_partial_index_with_multiline_where` | Failure: expected the two-line predicate, got `nil` |
| `test_expression_index_with_trailing_newline` | Error: `NoMethodError: undefined method 'size' for nil` |
| `test_multiline_expression_index_with_where` | Error: the same `NoMethodError` after a newline inside the expression capture |
| `test_schema_dump_with_multiline_expression_index` | Failure: output contains `Could not dump table "ex"`, the same `NoMethodError`, and no `create_table "ex"` |

This is a causal red test, not merely a run of the standalone reproduction: the
only toggled production line was the parser line changed by the pull request.

## Green phase: focused regressions

After restoring the submitted parser, the same command and seed produced:

```text
4 runs, 11 assertions, 0 failures, 0 errors, 0 skips
```

The assertions cover all three regex decisions:

- `/m` allows newlines inside the `where` and `expressions` dot captures.
- `\s*\z` accepts terminal whitespace for an expression index with no `WHERE`.
- lazy `where` capture leaves the final heredoc newline outside the returned
  predicate while preserving two spaces inside SQL string literals.

The schema-dump test separately confirms that the table and its expression
index are emitted without the rescue diagnostic.

## Green phase: complete adapter test file

```bash
ARCONN=sqlite3 RBENV_VERSION=3.4.2 rbenv exec bundle exec ruby \
  -Itest test/cases/adapters/sqlite3/sqlite3_adapter_test.rb --seed 41723
```

```text
101 runs, 253 assertions, 0 failures, 0 errors, 0 skips
```

## Green phase: complete Active Record SQLite suite

The repository-prescribed SQLite task ran from `activerecord/`:

```bash
RBENV_VERSION=3.4.2 rbenv exec bundle exec rake test:sqlite3
```

```text
Run options: --seed 9565
9643 runs, 32864 assertions, 0 failures, 0 errors, 38 skips
```

Skipped tests are reported by the unchanged upstream suite; the task exited
zero. This is the complete Active Record SQLite suite, not a claim that every
Rails component or every database adapter was run locally.

## Style and patch hygiene

```bash
RBENV_VERSION=3.4.2 rbenv exec bundle exec rubocop \
  activerecord/lib/active_record/connection_adapters/sqlite3/schema_statements.rb \
  activerecord/test/cases/adapters/sqlite3/sqlite3_adapter_test.rb \
  activerecord/CHANGELOG.md
git diff --check
```

```text
3 files inspected, no offenses detected
```

`git diff --check` also exited zero. The submitted commit contains three files,
58 insertions, and one deletion: one production-line replacement, four native
tests, and one changelog entry.

## Hosted validation on the final pull-request SHA

Every check reported by Rails completed successfully on
`a4f3c229b864c6ebbe7e2c03d3a85482ef23c9eb`:

| Hosted check | Terminal result | Exact run |
|---|---|---|
| Rails Buildkite suite | Passed in 6 minutes 9 seconds | [rails/rails build #131320](https://buildkite.com/rails/rails/builds/131320) |
| Rails Docker smoke test | Passed in 2 minutes 37 seconds | [`rails-new-docker` run 29885637092](https://github.com/rails/rails/actions/runs/29885637092) |
| Rails docs preview | Passed in 7 minutes 39 seconds | [docs-preview build #20921](https://buildkite.com/rails/docs-preview/builds/20921) |
| Rails automatic labeler | Passed in 3 seconds | [labeler run 29885636090](https://github.com/rails/rails/actions/runs/29885636090) |

The final public case-file commit before this ledger addition also passed all
nine independent jobs—five Active Record targets, three sqlite3 storage probes,
and Ruby syntax/parser compatibility—in
[Verification run 29885712858](https://github.com/rameerez/rails-sqlite-partial-index-dumper-bug/actions/runs/29885712858).

The canonical aggregate is the
[pull request's checks view](https://github.com/rails/rails/pull/58201/checks).
At the time this record was finalized, the PR was open, non-draft, mergeable,
and reported a clean merge state with no test failure or merge conflict. No
maintainer review had yet been submitted; merge authority remains upstream.

## Process traceability

The test location, Minitest style, issue reference in the commit, and changelog
entry follow the checkout's exact agent instructions:
[`AGENTS.md:128-140`](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/AGENTS.md#L128-L140)
and
[`AGENTS.md:182-191`](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/AGENTS.md#L182-L191).
The ready-for-review state, body sections, issue-closing reference, and checklist
follow Rails' exact
[pull-request template](https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/.github/pull_request_template.md#L1-L45).
