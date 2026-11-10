# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "securerandom"
require "set"

module Riptide
  # Recorded runs and open failures, kept in git. A unit is one suite's
  # record for one build: a branch, keyed branches/<branch>, or a PR, keyed
  # prs/<number>. It's two refs, written and deleted together:
  #
  #   refs/riptide/runs/<suite>/<key>     a tag wrapping the Index's tree
  #   refs/riptide/stamps/<suite>/<key>   a tag wrapping a small tree:
  #     format                            the index's format
  #     runs                              the runs tag it pairs with
  #     marks/<ab>                        per test, its open failures' ids
  #     landing/target                    for a PR, the branch it merges into
  #     landing/base/..., landing/tested/... the paths it changed, at the
  #                                       merge base and as tested
  #
  # The refs point at tags, not commits, so a push uploads only the objects
  # the host doesn't already have. The stamp lets a build read every PR's
  # open failures and landing record without downloading its runs, and its
  # date is when the unit was last written.
  #
  # `Store.fetch` leaves exactly the units a build reads as local refs, so
  # test processes read every local unit of their suite from a read-only
  # .git and append to their own log. #publish folds the logs into the
  # build's unit and pushes it.
  class Store
    # A test process's outcome for a test. +sets+ and +inputs+ are nil when
    # riptide couldn't trace what the test ran. +file+ is where the test is
    # defined.
    Run = Struct.new(:test, :at, :passed, :sets, :inputs, :file, keyword_init: true)

    # Who a build is. +key+ names its unit, +upstream+ the branch whose unit
    # it also reads, and for a PR, the branch it merges into. A harvesting
    # build reads the PRs that landed in +branch+.
    Build = Struct.new(:key, :upstream, :branch, :pr, :harvest, keyword_init: true) do
      def self.pr(number, target:) = new(key: "prs/#{number}", upstream: target, pr: true, harvest: false)
      def self.branch(name, upstream: nil, harvest: false) = new(key: "branches/#{Store.escape(name)}", upstream: upstream, branch: name, harvest: harvest)

      def upstream_key = upstream && "branches/#{Store.escape(upstream)}"
    end

    Published = Struct.new(:ref, :runs, :harvested, :deleted, keyword_init: true)

    ROOT = "refs/riptide/"
    RUNS = "#{ROOT}runs/".freeze
    STAMPS = "#{ROOT}stamps/".freeze
    TARGET = "#{ROOT}target".freeze
    RETRY = "refs/riptide-retry/"

    # A unit nobody wrote for this long gets deleted, like a PR closed
    # without merging.
    EXPIRY = 30 * 24 * 60 * 60

    # How long a publish keeps retrying a lost race.
    BUDGET = 120

    # A set's id in the logs comes from its content, so tests sharing a
    # class share one.
    def self.set_id(files) = Digest::SHA1.hexdigest(JSON.generate(files.sort.to_h))[0, 16]

    # One ref segment per name, so feature/a can't nest under feature.
    def self.escape(name) = name.gsub("%", "%25").gsub("/", "%2F")

    # Brings in the units +build+ reads, for every suite, and nothing else:
    # every local riptide ref goes first. A harvesting build also ages out
    # idle units and checks which PRs landed in HEAD. Riptide only reads,
    # so anything going wrong here means reading less.
    def self.fetch(root:, build:, remote: "origin")
      git = Git.new(root)
      git.delete_refs(git.refs(ROOT).keys + git.refs(RETRY).keys)
      keys = [build.key, build.upstream_key].compact.uniq
      specs = keys.flat_map { |key| %W[+#{RUNS}*/#{key}:#{RUNS}*/#{key} +#{STAMPS}*/#{key}:#{STAMPS}*/#{key}] }
      specs << "+#{STAMPS}*:#{STAMPS}*" if build.harvest
      specs << "+refs/heads/#{build.upstream}:#{TARGET}" if build.pr
      git.run("fetch", "--quiet", "--atomic", "--no-tags", "--refmap=", "--no-write-fetch-head", remote, *specs)
      Harvest.new(git, build, remote).run if build.harvest
    end

    def initialize(root:, suite:, log_dir:, remote: "origin", retained_runs: 4)
      @root = root
      @git = Git.new(root)
      @suite = Store.escape(suite)
      @log_dir = log_dir
      @remote = remote
      @retained_runs = retained_runs
      @log = nil
      @log_pid = nil
    end

    def runs_ref(key) = "#{RUNS}#{@suite}/#{key}"
    def stamp_ref(key) = "#{STAMPS}#{@suite}/#{key}"

    # Reading

    # Every unit of the suite fetch left, then the logs not yet published,
    # as they were the first time anything asked.
    def indexes
      @indexes ||= local_units.map { |key, (runs, stamp)| unit(key, runs, stamp) } << logs
    end

    # { line => { "owners" => [class name, ...], "called" => bool } } for a
    # file version, or nil when no recorded process loaded it.
    def load_facts(sha)
      found = indexes.filter_map { |index| index.load_facts(sha) }
      return nil if found.empty?

      model = Index::Model.new
      found.each { |lines| model.merge_loads(sha, lines) }
      model.loads[sha].to_h { |line, fact| [line.to_i, fact] }
    end

    def read_blob(sha) = @git.read(sha)

    # Writing, from test processes

    def append_start(test) = write_record({ "type" => "start", "test" => test, "at" => Time.now.to_f })
    def append_run(run) = write_record({ "type" => "run" }.merge(run.to_h.transform_keys(&:to_s)))
    def append_set(id, files) = write_record({ "type" => "set", "id" => id, "files" => files })
    def append_load_facts(sha, lines) = write_record({ "type" => "load", "sha" => sha, "lines" => lines })

    # The tests this process's selection picked. A test it skipped already
    # has a run that holds, so a new pass adds nothing.
    def append_selected(tests) = write_record({ "type" => "selected", "tests" => tests })

    # The runs of +index+ this process's tree no longer matches. The rest
    # held here, and they're what harvesting copies.
    def append_hits(index, ids) = write_record({ "type" => "hits", "ref" => index.ref, "runs" => ids.sort })

    # Publishing

    # Folds every log into +build+'s unit and pushes it. A harvesting build
    # first copies the passing runs and open failures of the PRs that
    # landed, and afterwards deletes their units.
    #
    # The logs go either way, so a later build never folds in this one's.
    def publish(build:)
      logs = Dir.glob(File.join(@log_dir, "log-*.jsonl")).sort
      records = logs.flat_map { |path| read_log(path) }
      seen = local_units.values.flat_map { |_, stamp| stamp ? marks_at(stamp).values.flat_map(&:to_a) : [] }.to_set
      landed = build.harvest ? landed_units(build) : {}
      runs, stamp = @git.resolve(runs_ref(build.key)), @git.resolve(stamp_ref(build.key))
      landing = build.pr ? landing_record(build.upstream, stamp) : nil
      head = @git.tree("HEAD").keys.to_set
      deadline = Time.now + BUDGET

      loop do
        model, marks, files = start_from(runs, stamp)
        harvested, pins = harvest(model, marks, files, landed, records)
        added = fold(model, marks, files, records, seen)
        trim(model, marks, files, head)
        return Published.new(ref: runs_ref(build.key), runs: 0, harvested: 0, deleted: []) if runs.nil? && model.runs.empty? && marks.empty?

        pushed = push(build, model, marks, files, pins, landing, runs, stamp)
        if pushed
          @git.delete_refs(landed.flat_map { |key, _| [runs_ref(key), stamp_ref(key)] })
          @git.run("update-ref", runs_ref(build.key), pushed.first)
          @git.run("update-ref", stamp_ref(build.key), pushed.last)
          deleted = landed.empty? ? [] : delete_units(landed)
          return Published.new(ref: runs_ref(build.key), runs: added, harvested: harvested, deleted: deleted)
        end
        raise Error, "riptide couldn't publish #{runs_ref(build.key)} before its deadline" if Time.now > deadline

        runs, stamp = refetch(build.key)
      end
    ensure
      close_log
      logs&.each { |path| FileUtils.rm_f(path) }
    end

    private

    # { key => [runs tag, stamp tag] } for the suite's local units.
    def local_units
      units = Hash.new { |h, k| h[k] = [nil, nil] }
      @git.refs("#{RUNS}#{@suite}/").each { |ref, tag| units[ref.delete_prefix("#{RUNS}#{@suite}/")][0] = tag }
      @git.refs("#{STAMPS}#{@suite}/").each { |ref, tag| units[ref.delete_prefix("#{STAMPS}#{@suite}/")][1] = tag }
      units
    end

    # A unit's index. One whose runs are in another format, or missing,
    # still brings its open failures.
    def unit(key, runs, stamp)
      marks = stamp ? marks_at(stamp) : {}
      return Index.empty(ref: runs_ref(key), marks: marks) unless runs && stamp && format_at(stamp) == Index::FORMAT

      tree = @git.tree(runs)
      Index.new(blobs: ->(path) { (sha = tree[path]) && JSON.parse(@git.read(sha)) }, paths: tree.keys, ref: runs_ref(key), marks: marks)
    end

    def format_at(stamp) = @git.read("#{stamp}:format")&.to_i

    # { test => Set of mark ids } from a stamp, with each test's file in
    # +files+. A stamp with no open failures has no marks/ at all.
    def marks_at(stamp, files = {})
      tree = @git.resolve("#{stamp}:marks")
      return {} unless tree

      @git.tree(tree).each_with_object({}) do |(_, sha), marks|
        JSON.parse(@git.read(sha)).each do |key, mark|
          test = JSON.parse(key)
          files[test] = mark["file"] if mark["file"]
          marks[test] = mark["ids"].to_set
        end
      end
    end

    def logs
      model = Index::Model.new
      marks = {}
      fold(model, marks, {}, log_records, Set.new)
      model.retain(@retained_runs)
      Index.of(model.encode, marks: marks)
    end

    # The model and open failures a publish starts from.
    def start_from(runs, stamp)
      files = {}
      marks = stamp ? marks_at(stamp, files) : {}
      index = runs && stamp && unit(nil, runs, stamp)
      [index && !index.runs.empty? ? index.model : Index::Model.new, marks, files]
    end

    # The units of PRs that landed in this build's branch: the ones fetch
    # brought runs for. { key => [runs tag, stamp tag] }
    def landed_units(build)
      local_units.select do |key, (runs, stamp)|
        key.start_with?("prs/") && key != build.key && runs && stamp && @git.read("#{stamp}:runs") == runs
      end
    end

    # Copies the passing runs that held here from the landed PRs, with their
    # load facts, pins and open failures. Returns how many runs, and the
    # pins.
    def harvest(model, marks, files, landed, records)
      hits = Hash.new { |h, k| h[k] = Set.new }
      read = Set.new
      records.each do |record|
        next unless record["type"] == "hits"

        read << record["ref"]
        hits[record["ref"]].merge(record["runs"])
      end
      pins = Set.new
      count = landed.sum do |key, (runs, stamp)|
        marks_at(stamp, files).each { |test, ids| (marks[test] ||= Set.new).merge(ids) }
        source = unit(key, runs, stamp)
        next 0 if source.runs.empty?

        source = source.model
        pins.merge(source.pins)
        source.loads.each { |sha, lines| model.merge_loads(sha, lines) }
        hit = hits[runs_ref(key)]
        held = source.runs.values.flatten(1).reject { |id, _| read.include?(runs_ref(key)) && hit.include?(id) }
        held.sort_by { |_, run| run.at }.count do |_, run|
          sets = run.sets.map { |id| model.add_set(source.set(id).files, source.set(id).constants) }
          model.add_run(test: run.test, at: run.at, sets: sets, files: run.files, constants: run.constants, file: source.test_files[run.test])
        end
      end
      [count, pins]
    end

    # Adds the logs to +model+ and +marks+. A pass of a test selection
    # picked is evidence, and any pass closes the open failures this build
    # saw at fetch. A failure, or a test that
    # started and never finished, opens one. Returns how many runs it added.
    def fold(model, marks, files, records, seen)
      sets = records.select { |record| record["type"] == "set" }.to_h { |record| [record["id"], record["files"]] }
      decided = records.select { |record| record["type"] == "selected" }
      picked = decided.flat_map { |record| record["tests"] }.to_set
      ids = {}
      unfinished = Hash.new(0)
      added = 0
      records.select { |record| %w[start run].include?(record["type"]) }.sort_by { |record| record["at"] }.each do |record|
        test = record["test"]
        if record["type"] == "start"
          unfinished[test] += 1
          next
        end
        unfinished[test] -= 1
        files[test] = record["file"] if record["file"]
        next if record["passed"].nil?

        unless record["passed"]
          (marks[test] ||= Set.new) << SecureRandom.hex(16)
          next
        end
        marks[test]&.subtract(seen)
        marks.delete(test) if marks[test]&.empty?
        next unless record["inputs"]
        next if decided.any? && !picked.include?(test)

        set_ids = record["sets"].map { |id| ids[id] ||= sets[id] && model.add_set(*Index::Model.split(sets[id])) }
        # A run whose shared set the logs lost can't be checked against anything.
        next if set_ids.include?(nil)

        files, constants = Index::Model.split(record["inputs"])
        added += 1 if model.add_run(test: test, at: record["at"], sets: set_ids, files: files, constants: constants, file: record["file"])
      end
      unfinished.each { |test, count| (marks[test] ||= Set.new) << SecureRandom.hex(16) if count.positive? }
      records.select { |record| record["type"] == "load" }.each { |record| model.merge_loads(record["sha"], record["lines"]) }
      added
    end

    # Keeps each test's newest runs, and drops tests whose file is gone,
    # runs and open failures alike.
    def trim(model, marks, files, head)
      gone = ->(test) { (file = model.test_files[test] || files[test]) && !head.include?(file) }
      model.retain(@retained_runs, tests: model.runs.keys.reject(&gone))
      marks.reject! { |test, _| gone.call(test) }
    end

    # Pushes the unit's runs and a new stamp in one atomic push, leased at
    # what the fold started from. The two tags, or nil when another build got
    # there first.
    def push(build, model, marks, files, pins, landing, runs, stamp)
      runs_tag = @git.tag_tree(runs_tree(model, pins, runs), "runs")
      stamp_tag = @git.tag_tree(stamp_tree(marks, files, runs_tag, landing), "stamp")
      leases = { runs_ref(build.key) => runs, stamp_ref(build.key) => stamp }.map { |ref, old| "--force-with-lease=#{ref}:#{old}" }
      _, status = @git.run("push", "--quiet", "--atomic", *leases, @remote, "#{runs_tag}:#{runs_ref(build.key)}", "#{stamp_tag}:#{stamp_ref(build.key)}",
                           allow: [0, 1])
      [runs_tag, stamp_tag] if status.zero?
    end

    # Pins keep each recorded file version fetchable. New ones come only
    # from the commit the build checked out, so a staged or stashed file
    # never gets pushed. A version that was never committed stays unpinned,
    # and selection treats it as unavailable.
    def runs_tree(model, pins, runs)
      known = runs ? @git.tree(runs).values.to_set : Set.new
      shas = @git.write_blobs(model.encode.transform_values { |value| JSON.generate(value) }, known: known)
      pinned = model.pins | pins
      committed = @git.tree("HEAD").values.to_set
      model.versions.each { |sha| shas["blobs/#{sha[0, 2]}/#{sha}"] = sha if pinned.include?(sha) || committed.include?(sha) }
      @git.write_tree(shas)
    end

    def stamp_tree(marks, files, runs_tag, landing)
      shards = Hash.new { |h, k| h[k] = {} }
      marks.each do |test, ids|
        shards[Index.shard(Index.test_key(test))][Index.test_key(test)] = { "file" => files[test], "ids" => ids.sort }.compact unless ids.empty?
      end
      content = { "format" => Index::FORMAT.to_s, "runs" => runs_tag }
      shards.each { |shard, by_test| content["marks/#{shard}"] = JSON.generate(by_test.sort.to_h) }
      entries = @git.write_blobs(content).transform_values { |sha| ["100644", sha] }
      landing&.each { |path, entry| entries["landing/#{path}"] = entry }
      @git.write_tree(entries)
    end

    # { path => [mode, object] } for the stamp's landing/ tree: the target,
    # and the paths this PR changed at its merge base with the target and
    # as tested. When this build can't work that out, the last stamp's
    # record stands, so the PR doesn't drop out of main's harvest.
    def landing_record(target, stamp)
      base = @git.resolve(TARGET) && @git.merge_base("HEAD", TARGET)
      unless base
        warn "[riptide] couldn't find where this PR left #{target}, so its landing record stays as it was"
        return stamp && @git.entries("#{stamp}:landing")
      end

      record = { "target" => ["100644", @git.write_blobs({ "target" => target })["target"]] }
      @git.output("diff-tree", "-r", "-z", "--no-renames", base, "HEAD").split("\0").each_slice(2) do |meta, path|
        old_mode, new_mode, old_sha, new_sha = meta.delete_prefix(":").split
        record["base/#{path}"] = [old_mode, old_sha] unless old_mode == "000000"
        record["tested/#{path}"] = [new_mode, new_sha] unless new_mode == "000000"
      end
      record
    end

    # Deletes the harvested units in one atomic push, leased at what this
    # build read, so a PR that republished keeps everything.
    def delete_units(landed)
      refs = landed.flat_map { |key, (runs, stamp)| [[runs_ref(key), runs], [stamp_ref(key), stamp]] }
      leases = refs.map { |ref, old| "--force-with-lease=#{ref}:#{old}" }
      _, status = @git.run("push", "--quiet", "--atomic", *leases, @remote, *refs.map { |ref, _| ":#{ref}" }, allow: [0, 1])
      status.zero? ? refs.map(&:first) : []
    end

    # The unit as the remote has it now, in a namespace of its own so no
    # other suite's local refs move.
    def refetch(key)
      unit = "#{@suite}/#{key}"
      @git.delete_refs(%w[runs stamps].map { |kind| "#{RETRY}#{kind}/#{unit}" }.select { |ref| @git.resolve(ref) })
      @git.run("fetch", "--quiet", "--no-tags", "--refmap=", "--no-write-fetch-head", @remote, "+#{ROOT}*/#{unit}:#{RETRY}*/#{unit}")
      [@git.resolve("#{RETRY}runs/#{unit}"), @git.resolve("#{RETRY}stamps/#{unit}")]
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

    def log_records
      @log_records ||= Dir.glob(File.join(@log_dir, "log-*.jsonl")).sort.flat_map { |path| read_log(path) }
    end

    # A line cut short by a process killed mid-write is skipped, and its
    # test counts as started and never finished.
    def read_log(path)
      File.foreach(path).filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
