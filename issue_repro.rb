# frozen_string_literal: true

# Compact, edge-Rails-only test case intended for the upstream issue body.
# The comprehensive release matrix and trigger characterization live elsewhere
# in this repository.
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
    eval(schema.gsub(/version: [\d_.]+/, "version: 0")) # rubocop:disable Security/Eval
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
