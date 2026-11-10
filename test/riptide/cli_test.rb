# frozen_string_literal: true

require "test_helper"
require "stringio"
require "riptide/cli"

module Riptide
  class CLITest < Minitest::Test
    def test_publish_then_fetch_through_a_remote
      Dir.mktmpdir do |dir|
        remote = File.join(dir, "remote.git")
        system("git", "init", "-q", "--bare", remote, exception: true)
        a = File.join(dir, "a")
        b = File.join(dir, "b")
        [a, b].each { |clone| system("git", "clone", "-q", remote, clone, exception: true, err: File::NULL) }
        system("git", "-C", a, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "start", exception: true)
        system("git", "-C", a, "push", "-q", "origin", "HEAD:main", exception: true, err: File::NULL)

        writer = Store.new(root: a, suite: "unit", log_dir: File.join(a, "tmp/riptide/unit"))
        writer.append_run(Store::Run.new(test: %w[ATest test_a], at: 1.0, passed: true, sets: [], inputs: {}))

        out = StringIO.new
        assert_equal 0, CLI.new(["publish", "--suite", "unit", "--branch", "main", "--harvest", "--root", a], out: out).call
        assert_match %r{published refs/riptide/runs/unit/branches/main: 1 new runs, 0 harvested}, out.string
        assert_equal 0, CLI.new(["fetch", "--pr", "4", "--target", "main", "--root", b]).call

        reader = Store.new(root: b, suite: "unit", log_dir: File.join(b, "tmp/riptide/unit"))
        assert_equal [[%w[ATest test_a]]], reader.indexes.map { |index| index.runs.keys }.reject(&:empty?)
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
