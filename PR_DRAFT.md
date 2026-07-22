### Motivation / Background

Fixes rails/rails#58200.

SQLite index introspection parses the original `CREATE INDEX` text stored in `sqlite_schema.sql`. The current regular expression cannot match a newline inside its dot-based captures or even one terminal newline. A predicate supplied through the public `add_index(..., where:)` API as a heredoc therefore comes back from `connection.indexes` as `where: nil`, and `schema.rb` turns the partial index into a full index. For expression indexes, the same failed match can make `connection.indexes` raise and cause `SchemaDumper` to omit the entire table.

### Detail

This pull request makes the SQLite index parser match across lines, captures the `WHERE` expression lazily, and consumes terminal whitespace outside that capture. This preserves both multiline expressions and predicates without leaking a heredoc's final newline into `schema.rb`.

The parser intentionally does not normalize or `squish` the stored SQL. Such normalization could alter significant whitespace inside a string literal; the new partial-index test protects a doubled-space literal explicitly.

The regression tests cover:

- a multiline partial predicate created through `add_index`;
- a terminal newline on an expression index;
- a multiline expression index with a partial predicate; and
- the complete schema-dump path that previously emitted `Could not dump table` and omitted the table.

### Additional information

The standalone reproduction, exact release matrix, raw logs, trigger characterization, and primary-source ledger are in the public [evidence repository](https://github.com/rameerez/rails-sqlite-partial-index-dumper-bug). The same failure signature is confirmed on Active Record 7.1.6, 7.2.3.1, 8.0.5, 8.1.3, and Rails main at `d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096`. Its independent verification matrix is [green](https://github.com/rameerez/rails-sqlite-partial-index-dumper-bug/actions/runs/29885712858).

Validation against Rails main:

```text
Focused regressions:          4 runs,    11 assertions, 0 failures, 0 errors
sqlite3_adapter_test.rb:    101 runs,   253 assertions, 0 failures, 0 errors
Full Active Record SQLite: 9,643 runs, 32,864 assertions, 0 failures, 0 errors, 38 skips
RuboCop:                       3 files inspected, no offenses detected
```

Before applying the parser change, the native tests reproduce both branches of the defect: the partial predicate is nil, expression-index introspection raises `NoMethodError`, and the schema dumper omits the affected table.

All checks on the submitted Rails SHA are green: the [Rails Buildkite suite](https://buildkite.com/rails/rails/builds/131320), [`rails-new-docker`](https://github.com/rails/rails/actions/runs/29885637092), [docs preview](https://buildkite.com/rails/docs-preview/builds/20921), and [labeler](https://github.com/rails/rails/actions/runs/29885636090).

Related work has different triggers or code paths: rails/rails#31603 and rails/rails#31607 addressed table recreation; rails/rails#53570 added support for trailing comments; rails/rails#55627 concerns unconventional table names; and rails/rails#58136 changes other multiline SQLite parsers.

### Checklist

Before submitting the PR make sure the following are checked:

- [x] This Pull Request is related to one change. Unrelated changes should be opened in separate PRs.
- [x] Commit message has a detailed description of what changed and why. If this PR fixes a related issue include it in the commit message. Ex: `[Fix #issue-number]`
- [x] Tests are added or updated if you fix a bug or add a feature.
- [x] CHANGELOG files are updated for the changed libraries if there is a behavior change or additional feature. Minor bug fixes and documentation changes should not be included.
