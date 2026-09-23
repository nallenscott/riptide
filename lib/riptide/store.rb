# frozen_string_literal: true

require "sqlite3"
require "json"
require "fileutils"
require "set"

# The gem's fork-safety guard (SQLite3::ForkSafety) closes an inherited
# writable connection after a fork and warns about it, aimed at code that
# doesn't know to reconnect. Store's #db accessor detects the pid change
# and reconnects on every access, so the warning is just noise here, and
# one that reprints per parallel test worker.
SQLite3::ForkSafety.suppress_warnings!

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
      @path = path
      FileUtils.mkdir_p(File.dirname(path)) unless path == ":memory:"
      log_file_state_before_connecting!
      connect!
      log_row_counts_immediately_after_connecting!
      delete_blob_encoded_rows!
    end

    # Persists one test's coverage. +coverage+ is { relative_path =>
    # Set<Integer> }, as produced by Collector. +blob_shas+ is
    # { relative_path => sha }, each file's git blob hash at capture time,
    # from Diff.blob_sha. Replaces whatever was recorded before for a given
    # (test, file) pair, a test's coverage of a file is a fresh snapshot
    # each time it runs, not something to merge with the last one.
    def record(class_name:, method_name:, coverage:, blob_shas:)
      db.transaction do
        test_id = upsert_test(class_name, method_name)

        coverage.each do |source_file, lines|
          next if lines.empty?

          ranges = Ranges.compress(lines)
          db.execute(<<~SQL, [test_id, source_file, blob_shas.fetch(source_file), ranges.to_json])
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
      rows = db.execute(<<~SQL, [source_file])
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
      db.execute("SELECT COUNT(*) FROM tests").first.first.zero?
    end

    # Wipes every recorded test and its dependency rows, forcing the next
    # run back into the bootstrap path. Schema stays intact, nothing needs
    # recreating.
    def reset!
      db.transaction do
        db.execute("DELETE FROM test_dependencies")
        db.execute("DELETE FROM tests")
      end
    end

    # Deletes every recorded test not in +known_tests+, an Enumerable of
    # [class_name, method_name] pairs, along with its dependency rows.
    # +known_tests+ has to be the full, current set of tests the caller can
    # see, a scoped or partial list here would prune tests that still
    # exist, just weren't in view.
    def prune_except(known_tests)
      known = known_tests.to_set

      stale_ids = db.execute("SELECT id, class_name, method_name FROM tests").filter_map do |id, class_name, method_name|
        id unless known.include?([class_name, method_name])
      end
      return if stale_ids.empty?

      db.transaction do
        stale_ids.each do |id|
          db.execute("DELETE FROM test_dependencies WHERE test_id = ?", [id])
          db.execute("DELETE FROM tests WHERE id = ?", [id])
        end
      end
    end

    private

    # Rails' test parallelization forks OS child processes after this
    # Store exists (built once at Minitest plugin init, before any
    # forking happens). A SQLite connection isn't safe to keep using across
    # a fork, so each access checks whether the pid has changed. The first
    # access after a fork goes to #connect_worker! instead of just reopening
    # the shared file: every sibling worker hits that same reconnect at
    # roughly the same moment, and reopening one shared file from all of
    # them at once, then hammering it with every test's #record for the
    # rest of the run, is worse contention than necessary.
    def db
      connect_worker! if @pid != Process.pid
      @db
    end

    # Opens the canonical file directly. Only ever called from #initialize,
    # before any forking has happened, so there's no contention to avoid
    # yet, this is the only Store in the process at this point.
    def connect!
      @db = open(@path)
      @pid = Process.pid
    end

    # TEMPORARY, remove once a real build has settled whether this
    # canonical file persists across separate CI builds or gets recreated
    # fresh each build -- that's an open question about whether the CI
    # workspace directory is actually a stable, persistent mount
    # build-to-build, not something inferrable from a database snapshot
    # pulled after the fact. #connect! creates the file if it's missing,
    # so existence/age/size have to be checked here, first, and printed
    # with a stable, greppable prefix so the answer comes straight out of
    # the real Jenkins log for this exact process.
    def log_file_state_before_connecting!
      return if @path == ":memory:"

      existed_before = File.exist?(@path)
      warn "[riptide-persistence-check] path=#{@path} existed_before_this_process=#{existed_before} " \
           "mtime=#{existed_before ? File.mtime(@path).utc.iso8601(3) : "n/a"} " \
           "size_bytes=#{existed_before ? File.size(@path) : "n/a"} " \
           "process_started_at=#{Time.now.utc.iso8601(3)}"
    end

    # Companion to the above: row counts as of the moment this process
    # connected, before anything this build's own tests do can add to
    # them. A nonzero count here, on a build whose own tests haven't run
    # yet, is direct evidence prior builds' data carried over.
    def log_row_counts_immediately_after_connecting!
      tests = db.execute("SELECT COUNT(*) FROM tests").first.first
      deps = db.execute("SELECT COUNT(*) FROM test_dependencies").first.first
      warn "[riptide-persistence-check] path=#{@path} tests_at_connect=#{tests} test_dependencies_at_connect=#{deps}"
    end

    # TEMPORARY, remove once a real build has confirmed this ran clean in
    # every stage's canonical store: a now-fixed bug in the native
    # collector (ext/riptide/riptide_native.c) built source_file as
    # ASCII-8BIT. The sqlite3 gem binds an ASCII-8BIT string as a BLOB
    # parameter, not TEXT, and SQLite never considers a TEXT value equal
    # to a BLOB of the same bytes, so every row that bug wrote is
    # permanently unreachable by dependencies_for_file's WHERE source_file
    # = ? (an ordinary, TEXT-bound Ruby string) or by record's own
    # ON CONFLICT(test_id, source_file) upsert. Pure dead weight, safe to
    # delete unconditionally: nothing can ever query these rows back out.
    # Runs once per canonical Store open, before any forking, so no
    # concurrent-writer race with worker connections.
    def delete_blob_encoded_rows!
      db.execute("DELETE FROM test_dependencies WHERE typeof(source_file) = 'blob'")
    end

    # Gives this worker a private file instead of the shared one, so
    # every #record for the rest of this process's tests only ever
    # contends with itself. Merges back into the canonical file, and
    # cleans up the worker file, exactly once, when this process exits,
    # registered fresh from inside the fork so it's tied to this process
    # specifically rather than relying on whatever hook the host app's
    # parallelization mechanism happens to offer.
    def connect_worker!
      worker_path = "#{@path}.worker-#{Process.pid}"
      @db = open(worker_path)
      @pid = Process.pid
      at_exit { merge_worker_into_canonical!(worker_path) }
    end

    def open(path)
      db = SQLite3::Database.new(path)
      db.busy_timeout = 5000
      db.execute_batch(SCHEMA)
      db
    end

    # Copies a worker's rows into the canonical file, remapping each row's
    # test_id along the way: the worker's autoincrement ids and the
    # canonical file's are independent sequences, only (class_name,
    # method_name) identifies the same test across both. Runs against
    # whatever's in the worker file at exit, a test's coverage of
    # a file is only ever recorded after that test finishes, so a run that
    # gets killed mid-test just leaves that one test's dependencies stale
    # rather than merging anything read mid-write.
    def merge_worker_into_canonical!(worker_path)
      return unless File.exist?(worker_path)

      worker_db = SQLite3::Database.new(worker_path)
      tests = worker_db.execute("SELECT id, class_name, method_name FROM tests").to_h { |id, cn, mn| [id, [cn, mn]] }
      dependencies = worker_db.execute("SELECT test_id, source_file, source_blob_sha, covered_lines FROM test_dependencies")
      worker_db.close

      canonical = open(@path)
      canonical.transaction do
        dependencies.each do |worker_test_id, source_file, source_blob_sha, covered_lines|
          class_name, method_name = tests.fetch(worker_test_id)

          canonical.execute(<<~SQL, [class_name, method_name])
            INSERT INTO tests (class_name, method_name) VALUES (?, ?)
            ON CONFLICT(class_name, method_name) DO NOTHING
          SQL
          test_id = canonical.execute(
            "SELECT id FROM tests WHERE class_name = ? AND method_name = ?", [class_name, method_name]
          ).first.first

          canonical.execute(<<~SQL, [test_id, source_file, source_blob_sha, covered_lines])
            INSERT INTO test_dependencies (test_id, source_file, source_blob_sha, covered_lines)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(test_id, source_file) DO UPDATE SET
              source_blob_sha = excluded.source_blob_sha,
              covered_lines = excluded.covered_lines
          SQL
        end
      end
      canonical.close
    ensure
      File.delete(worker_path) if File.exist?(worker_path)
    end

    def upsert_test(class_name, method_name)
      db.execute(<<~SQL, [class_name, method_name])
        INSERT INTO tests (class_name, method_name) VALUES (?, ?)
        ON CONFLICT(class_name, method_name) DO NOTHING
      SQL

      db.execute(
        "SELECT id FROM tests WHERE class_name = ? AND method_name = ?", [class_name, method_name]
      ).first.first
    end
  end
end
