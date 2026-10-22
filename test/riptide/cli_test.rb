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

        writer = Store.new(root: a, suite: "unit", log_dir: File.join(a, "tmp/riptide/unit"))
        writer.append_run(Store::Run.new(test: %w[ATest test_a], at: 1.0, passed: true, sets: [], inputs: {}))

        out = StringIO.new
        assert_equal 0, CLI.new(["publish", "--suite", "unit", "--root", a], out: out).call
        assert_match %r{published refs/riptide/unit}, out.string
        assert_equal 0, CLI.new(["fetch", "--suite", "unit", "--root", b]).call

        reader = Store.new(root: b, suite: "unit", log_dir: File.join(b, "tmp/riptide/unit"))
        assert_equal [%w[ATest test_a]], reader.runs([%w[ATest test_a]]).keys
      end
    end

    def test_a_missing_suite_is_an_error
      err = StringIO.new

      assert_equal 1, CLI.new(["publish"], err: err).call
      assert_match(/--suite/, err.string)
    end

    def test_an_unknown_command_prints_usage
      err = StringIO.new

      assert_equal 1, CLI.new(["nope", "--suite", "unit"], err: err).call
      assert_match(/usage/, err.string)
    end
  end
end
