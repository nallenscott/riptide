# frozen_string_literal: true

require "test_helper"

module Riptide
  class StoreTest < Minitest::Test
    include GitFixture

    TEST = %w[WidgetTest test_a].freeze

    # A repository with a bare remote, and a store per writer.
    def with_remote
      Dir.mktmpdir do |dir|
        remote = File.join(dir, "remote.git")
        system("git", "init", "-q", "--bare", remote, exception: true)
        clone = ->(name) do
          path = File.join(dir, name)
          system("git", "clone", "-q", remote, path, exception: true, err: File::NULL)
          system("git", "-C", path, "config", "user.email", "t@t", exception: true)
          system("git", "-C", path, "config", "user.name", "t", exception: true)
          path
        end
        yield dir, clone
      end
    end

    def store_for(root, suite: "unit", **options)
      Store.new(root: root, suite: suite, log_dir: File.join(root, "tmp/riptide"), remote: "origin", **options)
    end

    def commit_file(root, path, content)
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), content)
      system("git", "-C", root, "add", path, exception: true)
      system("git", "-C", root, "commit", "-qm", "add #{path}", exception: true)
      Diff.blob_sha(File.join(root, path))
    end

    def run_for(sha, at: 1.0, passed: true, test: TEST, sets: ["e1"])
      Store::Run.new(test: test, at: at, passed: passed, sets: sets, inputs: { "app/widget.rb" => { "sha" => sha, "methods" => ["Widget#a"] } })
    end

    def test_runs_appended_by_a_process_are_readable_before_publishing
      with_remote do |_, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "class Widget\nend\n")
        store = store_for(root)
        store.append_run(run_for(sha))

        assert_equal sha, store.runs([TEST]).fetch(TEST).first.inputs.dig("app/widget.rb", "sha")
      end
    end

    def test_published_runs_are_readable_from_another_clone_after_a_fetch
      with_remote do |_, clone|
        a = clone.("a")
        sha = commit_file(a, "app/widget.rb", "class Widget\nend\n")
        system("git", "-C", a, "push", "-q", "origin", "HEAD", exception: true, err: File::NULL)
        writer = store_for(a)
        writer.append_set("e1", { "Gemfile.lock" => { "sha" => "g1", "whole" => true } })
        writer.append_load_facts(sha, { "1" => { "owners" => ["Widget"], "called" => false } })
        writer.append_run(run_for(sha))
        writer.publish

        b = clone.("b")
        reader = store_for(b)
        reader.fetch

        assert_equal [TEST], reader.runs([TEST]).keys
        assert_equal({ "Gemfile.lock" => { "sha" => "g1", "whole" => true } }, reader.set("e1"))
        assert_equal({ 1 => { "owners" => ["Widget"], "called" => false } }, reader.load_facts(sha))
        assert_equal "class Widget\nend\n", reader.read_blob(sha)
      end
    end

    def test_publishing_removes_the_logs_it_folded_in
      with_remote do |_, clone|
        root = clone.("a")
        store = store_for(root)
        store.append_run(run_for(commit_file(root, "app/widget.rb", "x = 1\n")))
        store.publish

        assert_empty Dir.glob(File.join(root, "tmp/riptide/log-*.jsonl"))
        assert_equal 1, store.runs([TEST]).fetch(TEST).size
      end
    end

    def test_two_writers_merge_by_union
      with_remote do |_, clone|
        a = clone.("a")
        b = clone.("b")
        sha = commit_file(a, "app/widget.rb", "x = 1\n")
        system("git", "-C", a, "push", "-q", "origin", "HEAD", exception: true, err: File::NULL)
        system("git", "-C", b, "pull", "-q", exception: true, err: File::NULL)

        first = store_for(a)
        first.append_run(run_for(sha, at: 1.0))
        first.append_run(run_for(sha, at: 1.0, test: %w[OtherTest test_b]))
        first.publish
        second = store_for(b)
        second.append_run(run_for(sha, at: 2.0))
        second.publish

        reader = store_for(a)
        reader.fetch
        runs = reader.runs([TEST, %w[OtherTest test_b]])
        assert_equal [2.0, 1.0], runs.fetch(TEST).map(&:at)
        assert_equal [1.0], runs.fetch(%w[OtherTest test_b]).map(&:at)
      end
    end

    def test_each_test_keeps_only_its_newest_retained_runs
      with_remote do |_, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n")
        store = store_for(root, retained_runs: 2)
        [1.0, 2.0, 3.0].each { |at| store.append_run(run_for(sha, at: at)) }
        store.publish

        assert_equal [3.0, 2.0], store.runs([TEST]).fetch(TEST).map(&:at)
      end
    end

    def test_pruning_drops_tests_no_process_discovered_and_nothing_ran_lately
      with_remote do |_, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n")
        store = store_for(root)
        store.append_run(run_for(sha, test: %w[GoneTest test_old]))
        store.publish
        store.append_discovered([TEST])
        store.append_run(run_for(sha))
        store.publish(prune: true)

        assert_equal [TEST], store.runs([TEST, %w[GoneTest test_old]]).keys
      end
    end

    # A test added on a branch hasn't reached main yet, so main's build
    # doesn't discover it. Its runs stay until the grace period passes.
    def test_pruning_keeps_a_test_that_ran_recently_on_another_branch
      with_remote do |_, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n")
        now = Time.now.to_f
        branch = store_for(root)
        branch.append_run(run_for(sha, at: now - 86_400, test: %w[BranchTest test_new]))
        branch.publish
        main = store_for(root)
        main.append_discovered([TEST])
        main.append_run(run_for(sha, at: now))
        main.publish(prune: true, now: now)

        assert_equal [%w[BranchTest test_new], TEST].sort, main.runs([TEST, %w[BranchTest test_new]]).keys.sort
        main.append_discovered([TEST])
        main.publish(prune: true, now: now + Store::PRUNE_GRACE)
        assert_equal [TEST], main.runs([TEST, %w[BranchTest test_new]]).keys
      end
    end

    # A build that discovered nothing, like one that crashed while loading,
    # says nothing about which tests exist.
    def test_pruning_without_any_discovered_tests_keeps_everything
      with_remote do |_, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n")
        store = store_for(root)
        store.append_run(run_for(sha))
        store.publish
        store.publish(prune: true)

        assert_equal [TEST], store.runs([TEST]).keys
      end
    end

    def test_an_unknown_set_is_nil
      with_remote { |_, clone| assert_nil store_for(clone.("a")).set("0" * 16) }
    end

    # Only what's already in git's history gets pushed, so a file that was
    # never committed, like a local key, can't leak through the ref.
    def test_a_version_that_was_never_committed_is_not_pinned
      with_remote do |_, clone|
        root = clone.("a")
        File.write(File.join(root, "draft.rb"), "draft = true\n")
        sha = Diff.blob_sha(File.join(root, "draft.rb"))
        store = store_for(root)
        store.append_run(Store::Run.new(test: TEST, at: 1.0, passed: true, sets: [], inputs: { "draft.rb" => { "sha" => sha } }))
        store.publish

        reader = store_for(clone.("b"))
        reader.fetch
        assert_nil reader.read_blob(sha)
      end
    end

    def test_a_version_staged_but_never_committed_is_not_pinned
      with_remote do |_, clone|
        root = clone.("a")
        commit_file(root, "README", "x\n")
        File.write(File.join(root, "widget.rb"), "KEY = :secret\n")
        system("git", "-C", root, "add", "widget.rb", exception: true)
        sha = Diff.blob_sha(File.join(root, "widget.rb"))
        store = store_for(root)
        store.append_run(Store::Run.new(test: TEST, at: 1.0, passed: true, sets: [], inputs: { "widget.rb" => { "sha" => sha } }))
        store.publish

        reader = store_for(clone.("b"))
        reader.fetch
        assert_nil reader.read_blob(sha)
      end
    end

    def test_a_writer_that_lost_the_race_retries_and_keeps_both
      with_remote do |_, clone|
        a = clone.("a")
        b = clone.("b")
        sha = commit_file(a, "app/widget.rb", "x = 1\n")
        stale = store_for(b)
        stale.fetch
        winner = store_for(a)
        winner.append_run(run_for(sha, at: 1.0, test: %w[WinnerTest test_w]))
        winner.publish
        stale.append_run(run_for(sha, at: 2.0, test: %w[LateTest test_l]))
        stale.publish

        reader = store_for(a)
        reader.fetch
        assert_equal [%w[LateTest test_l], %w[WinnerTest test_w]], reader.runs([%w[WinnerTest test_w], %w[LateTest test_l]]).keys.sort
      end
    end

    def test_a_long_history_is_squashed_into_one_commit
      with_remote do |_, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n")
        store = store_for(root)
        stub_const(Store, :SQUASH_AFTER, 3) do
          4.times do |i|
            store.append_run(run_for(sha, at: i.to_f))
            store.publish
          end
        end

        assert_equal 1, `git -C #{root} rev-list --count #{store.ref}`.to_i
        assert_equal 4, store.runs([TEST]).fetch(TEST).size
      end
    end

    def test_publishing_needs_no_git_identity
      with_remote do |_, clone|
        root = clone.("a")
        system("git", "-C", root, "config", "--unset", "user.email", exception: true)
        system("git", "-C", root, "config", "--unset", "user.name", exception: true)
        store = Store.new(root: root, suite: "unit", log_dir: File.join(root, "tmp/riptide"), remote: "origin")
        store.append_run(run_for("s1"))
        store.publish

        assert_equal "riptide", `git -C #{root} log -1 --format=%an #{store.ref}`.strip
      end
    end

    def test_a_truncated_log_line_is_skipped
      with_remote do |_, clone|
        root = clone.("a")
        store = store_for(root)
        store.append_run(run_for("s1"))
        File.open(Dir.glob(File.join(root, "tmp/riptide/log-*.jsonl")).first, "a") { |f| f.write('{"type":"run","te') }

        assert_equal [TEST], store_for(root).runs([TEST]).keys
      end
    end

    def test_forked_processes_each_write_their_own_log
      with_remote do |_, clone|
        root = clone.("a")
        store = store_for(root)
        store.append_run(run_for("s1"))
        pids = 2.times.map do |i|
          fork do
            store.append_run(run_for("s1", test: ["ForkTest", "test_#{i}"]))
            exit!(0)
          end
        end
        pids.each { |pid| Process.wait(pid) }

        assert_equal 3, Dir.glob(File.join(root, "tmp/riptide/log-*.jsonl")).size
      end
    end

    private

    def stub_const(mod, name, value)
      original = mod.const_get(name)
      mod.send(:remove_const, name)
      mod.const_set(name, value)
      yield
    ensure
      mod.send(:remove_const, name)
      mod.const_set(name, original)
    end
  end
end
