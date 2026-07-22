# frozen_string_literal: true

# Guards the candidate regex against capture changes for the single-line index
# grammar already exercised by Rails' SQLite adapter tests:
# https://github.com/rails/rails/blob/d9e67f6268fc6793ecc7bbfa6c71e145a6dc8096/activerecord/test/cases/adapters/sqlite3/sqlite3_adapter_test.rb#L723-L773
OLD_PARSER = /\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+))?(?:\s*\/\*.*\*\/)?\z/i
CANDIDATE_PARSER = /\bON\b\s*"?(\w+?)"?\s*\((?<expressions>.+?)\)(?:\s*WHERE\b\s*(?<where>.+?))?(?:\s*\/\*.*\*\/)?\s*\z/im

CORPUS = {
  "partial index with comment" => 'CREATE INDEX "fun" ON "ex" ("id") WHERE number > 0 /*tag:test*/',
  "expression" => 'CREATE INDEX "expression" ON "ex" (max(id, number))',
  "expression with trailing comment" => "CREATE INDEX expression on ex (number % 10) /* comment */",
  "expression with where" => 'CREATE INDEX "expression" ON "ex" (id % 10, max(id, number)) WHERE id > 1000',
  "nested expression with adjacent WHERE" => "CREATE INDEX expression ON ex (id % 10, (CASE WHEN number > 0 THEN max(id, number) END))WHERE(id > 1000)",
  "mixed column and expression" => 'CREATE INDEX "expression" ON "ex" (id, max(id, number))'
}.freeze

def captures(parser, sql)
  match = parser.match(sql)
  abort "parser did not match #{sql.inspect}" unless match

  where = match[:where]
  where = where.sub(/\s*\/\*.*\*\/\z/, "") if where
  { expressions: match[:expressions], where: where }
end

CORPUS.each do |label, sql|
  old_result = captures(OLD_PARSER, sql)
  candidate_result = captures(CANDIDATE_PARSER, sql)
  abort "#{label}: #{old_result.inspect} != #{candidate_result.inspect}" unless old_result == candidate_result

  puts "#{label}: #{candidate_result.inspect}"
end

puts "Candidate captures match the current parser for all #{CORPUS.size} single-line corpus cases."
