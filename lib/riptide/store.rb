# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "securerandom"
require "set"
require "tempfile"

module Riptide
  # Recorded runs, kept in git under refs/riptide/<suite>:
  #
  #   runs/<ab>/<test key>   the newest runs of one test
  #   sets/<id>              files a group of tests depends on together: one
  #                          process's env, or what one class's loading ran
  #   loads/<blob sha>       which classes each line of a file version ran for
  #   blobs/<blob sha>       a pin that keeps a recorded file version fetchable
  #
  # Test processes read the ref and append to their own log file, so a
  # read-only .git is enough while tests run. #publish folds the logs into
  # a new commit and pushes it. Runs describe immutable file versions, so
  # merging two writers' runs is a union.
  class Store
    # +sets+ are the ids of the shared sets the run depends on, +inputs+ the
    # files it depended on directly.
    Run = Struct.new(:test, :at, :passed, :sets, :inputs, keyword_init: true)

    SQUASH_AFTER = 100
    PUBLISH_ATTEMPTS = 10
    # How long pruning keeps runs of a test the pruning build didn't
    # discover: one that exists on a branch and not yet on main.
    PRUNE_GRACE = 14 * 86_400
    ZERO = "0" * 40

    # Commits on the ref are riptide's, and a CI container has no git
    # identity of its own.
    IDENTITY = %w[AUTHOR COMMITTER].each_with_object({}) do |role, env|
      env["GIT_#{role}_NAME"] = "riptide"
      env["GIT_#{role}_EMAIL"] = "riptide@users.noreply.github.com"
    end.freeze

    attr_reader :ref

    # A set's id comes from its content, so tests sharing a class share one.
    def self.set_id(files) = Digest::SHA1.hexdigest(JSON.generate(files.sort.to_h))[0, 16]

    def initialize(root:, suite:, log_dir:, remote: nil, retained_runs: 4)
      @git = Git.new(root)
      @ref = "refs/riptide/#{suite}"
      @log_dir = log_dir
      @remote = remote
      @retained_runs = retained_runs
      @log = nil
      @log_pid = nil
    end

    # Reading

    # { [class_name, method_name] => [Run, ...] }, newest first.
    def runs(tests)
      wanted = tests.to_h { |test| [key_for(test), test] }
      result = Hash.new { |h, k| h[k] = [] }
      tree.each do |path, sha|
        test = wanted[path.split("/").last] if path.start_with?("runs/")
        JSON.parse(@git.read(sha)).each { |run| result[test] << run_from(run) } if test
      end
      log_records("run").each { |run| result[run["test"]] << run_from(run) if wanted.key?(key_for(run["test"])) }
      result.transform_values { |test_runs| newest(test_runs) }
    end

    # { path => facets } of a shared set, or nil for one the store doesn't
    # have.
    def set(id)
      @sets ||= {}
      return @sets[id] if @sets.key?(id)

      @sets[id] = if (sha = tree["sets/#{id}"])
                    JSON.parse(@git.read(sha))
                  else
                    log_records("set").find { |set| set["id"] == id }&.fetch("files")
                  end
    end

    # { line => { "owners" => [class name, ...], "called" => bool } } for a
    # file version, or nil when no recorded process loaded it.
    def load_facts(sha)
      facts = nil
      if (blob = tree["loads/#{sha}"])
        facts = parse_lines(JSON.parse(@git.read(blob)))
      end
      log_records("load").each do |record|
        next unless record["sha"] == sha

        facts = merge_lines(facts || {}, parse_lines(record["lines"]))
      end
      facts
    end

    def read_blob(sha) = @git.read(sha)

    # Writing, from test processes

    def append_run(run) = write_record({ "type" => "run" }.merge(run.to_h.transform_keys(&:to_s)))
    def append_set(id, files) = write_record({ "type" => "set", "id" => id, "files" => files })
    def append_load_facts(sha, lines) = write_record({ "type" => "load", "sha" => sha, "lines" => lines })
    def append_discovered(tests) = write_record({ "type" => "discovered", "tests" => tests })

    # Publishing

    # Folds every log into a new commit on the ref and, with a remote,
    # pushes it. +prune+ drops runs of tests no process in these logs
    # discovered and nothing ran lately, which only makes sense for a build
    # that discovers the whole suite, like main.
    def publish(prune: false, now: Time.now.to_f)
      logs = Dir.glob(File.join(@log_dir, "log-*.jsonl")).sort
      records = logs.flat_map { |path| read_log(path) }

      PUBLISH_ATTEMPTS.times do
        fetch
        base = @git.resolve(@ref)
        commit, squash = commit_for(base, records, prune: prune && now)
        if push(commit, base, squash: squash)
          close_log
          logs.each { |path| File.delete(path) }
          @tree = nil
          return commit
        end
      end
      raise Error, "riptide couldn't publish #{@ref} after #{PUBLISH_ATTEMPTS} attempts"
    end

    def fetch
      return unless @remote

      @git.run("fetch", "--quiet", @remote, "+#{@ref}:#{@ref}", allow: [0, 1, 128])
      @tree = nil
    end

    private

    def tree
      @tree ||= @git.tree(@git.resolve(@ref))
    end

    def key_for(test) = Digest::SHA1.hexdigest(JSON.generate(test))

    def run_path(test)
      key = key_for(test)
      "runs/#{key[0, 2]}/#{key}"
    end

    def run_from(record)
      Run.new(test: record["test"], at: record["at"], passed: record["passed"], sets: record["sets"], inputs: record["inputs"])
    end

    def newest(test_runs)
      test_runs.uniq { |run| [run.at, run.sets] }.sort_by { |run| -run.at }.first(@retained_runs)
    end

    def parse_lines(lines) = lines.to_h { |line, fact| [line.to_i, fact] }

    def merge_lines(into, lines)
      lines.each do |line, fact|
        known = into[line]
        into[line] = known ? { "owners" => known["owners"] | fact["owners"], "called" => known["called"] || fact["called"] } : fact
      end
      into
    end

    def write_record(record)
      reopen_log unless @log_pid == Process.pid
      @log.write("#{JSON.generate(record)}\n")
      @log_records = nil
    end

    # Publishing deletes the logs it folded in, so the next record starts a
    # new one.
    def close_log
      @log&.close
      @log = nil
      @log_pid = nil
      @log_records = nil
    end

    def reopen_log
      FileUtils.mkdir_p(@log_dir)
      @log = File.open(File.join(@log_dir, "log-#{Process.pid}-#{SecureRandom.hex(4)}.jsonl"), "a")
      @log.sync = true
      @log_pid = Process.pid
    end

    def log_records(type)
      @log_records ||= Dir.glob(File.join(@log_dir, "log-*.jsonl")).flat_map { |path| read_log(path) }
      @log_records.select { |record| record["type"] == type }
    end

    # A line cut short by a process killed mid-write is skipped.
    def read_log(path)
      File.foreach(path).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end

    # +prune+ is the time pruning runs from, or false.
    def commit_for(base, records, prune:)
      files = @git.tree(base)
      merge_runs(files, records, prune: prune)
      merge_sets(files, records)
      merge_loads(files, records)
      pin_blobs(files)

      squash = base && @git.output("rev-list", "--count", base).to_i >= SQUASH_AFTER
      tree = @git.write_tree(files)
      parents = base && !squash ? ["-p", base] : []
      [@git.output("commit-tree", tree, *parents, "-m", "riptide #{@ref.delete_prefix("refs/riptide/")}", env: IDENTITY).strip, squash]
    end

    def merge_runs(files, records, prune:)
      records.select { |record| record["type"] == "run" }.group_by { |record| record["test"] }.each do |test, new_runs|
        path = run_path(test)
        existing = files[path] ? JSON.parse(@git.read(files[path])) : []
        kept = (new_runs + existing).uniq { |run| [run["at"], run["sets"]] }.sort_by { |run| -run["at"] }.first(@retained_runs)
        files[path] = @git.write_blob(JSON.generate(kept))
      end
      return unless prune

      discovered = records.select { |record| record["type"] == "discovered" }.flat_map { |record| record["tests"] }
      return if discovered.empty?

      keep = discovered.to_set { |test| run_path(test) }
      files.reject! do |path, sha|
        path.start_with?("runs/") && !keep.include?(path) && JSON.parse(@git.read(sha)).all? { |run| run["at"] < prune - PRUNE_GRACE }
      end
    end

    def merge_sets(files, records)
      records.select { |record| record["type"] == "set" }.each do |record|
        files["sets/#{record["id"]}"] ||= @git.write_blob(JSON.generate(record["files"]))
      end
    end

    def merge_loads(files, records)
      records.select { |record| record["type"] == "load" }.group_by { |record| record["sha"] }.each do |sha, loads|
        path = "loads/#{sha}"
        lines = files[path] ? parse_lines(JSON.parse(@git.read(files[path]))) : {}
        loads.each { |record| merge_lines(lines, parse_lines(record["lines"])) }
        files[path] = @git.write_blob(JSON.generate(lines.sort.to_h))
      end
    end

    # Keeps sets, load facts and pins only for file versions a retained run
    # still refers to. New pins come from the commit the build checked out,
    # so a staged or stashed file never gets pushed. A version that was
    # never committed stays unpinned, and selection treats it as unavailable.
    def pin_blobs(files)
      runs = files.select { |path, _| path.start_with?("runs/") }.values.flat_map { |sha| JSON.parse(@git.read(sha)) }
      set_ids = runs.flat_map { |run| run["sets"] }.to_set
      files.reject! { |path, _| path.start_with?("sets/") && !set_ids.include?(path.delete_prefix("sets/")) }

      versions = Set.new
      runs.each { |run| run["inputs"].each_value { |facets| versions << facets["sha"] } }
      set_ids.each do |id|
        sha = files["sets/#{id}"]
        JSON.parse(@git.read(sha)).each_value { |facets| versions << facets["sha"] } if sha
      end

      files.reject! { |path, _| path.start_with?("loads/") && !versions.include?(path.delete_prefix("loads/")) }
      pinned = files.keys.grep(%r{\Ablobs/}).to_set { |path| path.delete_prefix("blobs/") }
      files.reject! { |path, _| path.start_with?("blobs/") }
      committed = @git.tree(@git.resolve("HEAD")).values.to_set
      versions.each { |sha| files["blobs/#{sha}"] = sha if pinned.include?(sha) || committed.include?(sha) }
    end

    def push(commit, base, squash:)
      unless @remote
        _, status = @git.run("update-ref", @ref, commit, base || ZERO, allow: [0, 128])
        return status.zero?
      end

      lease = base ? "--force-with-lease=#{@ref}:#{base}" : "--force-with-lease=#{@ref}:"
      args = squash ? [lease] : []
      _, status = @git.run("push", "--quiet", *args, @remote, "#{commit}:#{@ref}", allow: [0, 1])
      return false unless status.zero?

      @git.run("update-ref", @ref, commit)
      true
    end
  end
end
