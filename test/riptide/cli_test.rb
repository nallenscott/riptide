# frozen_string_literal: true

require "test_helper"
require "stringio"
require "riptide/cli"

module Riptide
  class CLITest < Minitest::Test
    TEST = %w[ATest test_a].freeze

    # Two clones of one remote, with a commit pushed to main. Yields the
    # writing clone, the reading one and the sha of a file in the commit.
    def with_clones
      Dir.mktmpdir do |dir|
        remote = File.join(dir, "remote.git")
        system("git", "init", "-q", "--bare", remote, exception: true)
        a = File.join(dir, "a")
        b = File.join(dir, "b")
        [a, b].each { |clone| system("git", "clone", "-q", remote, clone, exception: true, err: File::NULL) }
        File.write(File.join(a, "widget.rb"), "x = 1\n")
        system("git", "-C", a, "add", "widget.rb", exception: true)
        system("git", "-C", a, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "start", exception: true)
        system("git", "-C", a, "push", "-q", "origin", "HEAD:main", exception: true, err: File::NULL)
        yield a, b, IO.popen(["git", "-C", a, "rev-parse", "HEAD:widget.rb"], &:read).strip
      end
    end

    def run_at(sha, at)
      Store::Run.new(test: TEST, at: at, passed: true, sets: [], inputs: { "widget.rb" => { "sha" => sha, "methods" => ["m#{at}"] } })
    end

    # The passing runs of TEST the reading clone gets from main, newest first.
    def fetched_ats(clone)
      assert_equal 0, CLI.new(["fetch", "--pr", "4", "--target", "main", "--root", clone]).call
      reader = Store.new(root: clone, suite: "unit", log_dir: File.join(clone, "tmp/riptide/unit"))
      reader.indexes.flat_map { |index| index.runs.fetch(TEST, []) }.map(&:at).sort.reverse
    end

    def test_publish_then_fetch_through_a_remote
      with_clones do |a, b, sha|
        Store.new(root: a, suite: "unit", log_dir: File.join(a, "tmp/riptide/unit")).append_run(run_at(sha, 1.0))

        out = StringIO.new
        assert_equal 0, CLI.new(["publish", "--suite", "unit", "--branch", "main", "--harvest", "--root", a], out: out).call
        assert_match %r{published refs/riptide/runs/unit/branches/main: 1 new runs, 0 harvested}, out.string
        assert_equal [1.0], fetched_ats(b)
      end
    end

    def test_publish_reads_the_logs_in_the_log_dir_it_gets
      with_clones do |a, b, sha|
        Store.new(root: a, suite: "unit", log_dir: File.join(a, "elsewhere")).append_run(run_at(sha, 1.0))

        assert_equal 0, CLI.new(["publish", "--suite", "unit", "--branch", "main", "--log-dir", "elsewhere", "--root", a], out: StringIO.new).call
        assert_equal [1.0], fetched_ats(b)
      end
    end

    def test_publish_keeps_as_many_runs_per_test_as_it_is_told
      with_clones do |a, b, sha|
        store = Store.new(root: a, suite: "unit", log_dir: File.join(a, "tmp/riptide/unit"))
        [1.0, 2.0, 3.0].each { |at| store.append_run(run_at(sha, at)) }

        assert_equal 0, CLI.new(["publish", "--suite", "unit", "--branch", "main", "--retained-runs", "2", "--root", a], out: StringIO.new).call
        assert_equal [3.0, 2.0], fetched_ats(b)
      end
    end

    def test_retained_runs_has_to_be_a_positive_number
      Dir.mktmpdir do |dir|
        %w[0 -1 two].each do |value|
          err = StringIO.new

          assert_equal 1, CLI.new(["publish", "--suite", "unit", "--branch", "main", "--retained-runs", value, "--root", dir], err: err).call
          assert_match(/--retained-runs/, err.string)
        end
      end
    end

    # A problem in riptide never fails the build.
    def test_a_fetch_that_goes_wrong_warns_and_exits_zero
      Dir.mktmpdir do |dir|
        system("git", "init", "-q", dir, exception: true)
        err = StringIO.new

        assert_equal 0, CLI.new(["fetch", "--branch", "main", "--harvest", "--root", dir], err: err).call
        assert_match(/fetch didn't finish/, err.string)
      end
    end

    def test_audit_reads_the_suite_s_runs_and_prints_what_to_remove
      with_clones do |a, _, _|
        out = StringIO.new

        assert_equal 0, CLI.new(["audit", "--suite", "unit", "--root", a], out: out).call
        assert_match(/\A0 tests read$/, out.string)
        assert_match(/^Inherited \(0, /, out.string)
        assert_match(/^Duplicates \(0, /, out.string)
      end
    end

    def test_audit_needs_a_suite
      err = StringIO.new

      assert_equal 1, CLI.new(["audit"], err: err).call
      assert_match(/--suite/, err.string)
    end

    def test_a_missing_suite_is_an_error
      err = StringIO.new

      assert_equal 1, CLI.new(["publish", "--branch", "main"], err: err).call
      assert_match(/--suite/, err.string)
    end

    def test_a_missing_identity_is_an_error
      err = StringIO.new

      assert_equal 1, CLI.new(["fetch"], err: err).call
      assert_match(/--pr or --branch/, err.string)
    end

    def test_a_pr_needs_its_target
      err = StringIO.new

      assert_equal 1, CLI.new(["fetch", "--pr", "4"], err: err).call
      assert_match(/--target/, err.string)
    end

    def test_an_unknown_command_prints_usage
      err = StringIO.new

      assert_equal 1, CLI.new(["nope", "--suite", "unit"], err: err).call
      assert_match(/usage/, err.string)
    end
  end
end
