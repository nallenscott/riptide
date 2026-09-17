# frozen_string_literal: true

require "sqlite3"
require "json"
require "fileutils"

module Riptide
  class Store
    SCHEMA = <<~SQL
      CREATE TABLE IF NOT EXISTS tests (
        id INTEGER PRIMARY KEY,
        class_name TEXT NOT NULL,
        method_name TEXT NOT NULL,
        UNIQUE(class_name, method_name)
      );

      CREATE TABLE IF NOT EXISTS test_dependencies (
        id INTEGER PRIMARY KEY,
        test_id INTEGER NOT NULL REFERENCES tests(id),
        source_file TEXT NOT NULL,
        source_blob_sha TEXT NOT NULL,
        covered_lines TEXT NOT NULL,
        UNIQUE(test_id, source_file)
      );

      CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY,
        value TEXT
      );
    SQL

    def initialize(path:)
      FileUtils.mkdir_p(File.dirname(path)) unless path == ":memory:"
      @db = SQLite3::Database.new(path)
      @db.execute_batch(SCHEMA)
    end

    # Persists one test's coverage. +coverage+ is { relative_path =>
    # Set<Integer> }, as produced by Collector. +blob_shas+ is
    # { relative_path => sha }, each file's git blob hash at capture time,
    # from Diff.blob_sha. Replaces whatever was recorded before for a given
    # (test, file) pair, a test's coverage of a file is a fresh snapshot
    # each time it runs, not something to merge with the last one.
    def record(class_name:, method_name:, coverage:, blob_shas:)
      @db.transaction do
        test_id = upsert_test(class_name, method_name)

        coverage.each do |source_file, lines|
          next if lines.empty?

          ranges = Ranges.compress(lines)
          @db.execute(<<~SQL, [test_id, source_file, blob_shas.fetch(source_file), ranges.to_json])
            INSERT INTO test_dependencies (test_id, source_file, source_blob_sha, covered_lines)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(test_id, source_file) DO UPDATE SET
              source_blob_sha = excluded.source_blob_sha,
              covered_lines = excluded.covered_lines
          SQL
        end
      end
    end

    # Every test known to have covered +source_file+, regardless of when it
    # was last recorded:
    #   [{ class_name:, method_name:, source_blob_sha:, ranges: [[start, finish], ...] }, ...]
    def dependencies_for_file(source_file)
      rows = @db.execute(<<~SQL, [source_file])
        SELECT tests.class_name, tests.method_name, test_dependencies.source_blob_sha, test_dependencies.covered_lines
        FROM test_dependencies
        JOIN tests ON tests.id = test_dependencies.test_id
        WHERE test_dependencies.source_file = ?
      SQL

      rows.map do |class_name, method_name, blob_sha, ranges_json|
        {
          class_name: class_name,
          method_name: method_name,
          source_blob_sha: blob_sha,
          ranges: JSON.parse(ranges_json)
        }
      end
    end

    # True until the first test has ever been recorded, the signal a fresh
    # database is a bootstrap case rather than an empty-but-known map.
    def empty?
      @db.execute("SELECT COUNT(*) FROM tests").first.first.zero?
    end

    private

    def upsert_test(class_name, method_name)
      @db.execute(<<~SQL, [class_name, method_name])
        INSERT INTO tests (class_name, method_name) VALUES (?, ?)
        ON CONFLICT(class_name, method_name) DO NOTHING
      SQL

      @db.execute(
        "SELECT id FROM tests WHERE class_name = ? AND method_name = ?", [class_name, method_name]
      ).first.first
    end
  end
end
