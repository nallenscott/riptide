# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Riptide
  class GitTest < Minitest::Test
    # A git that reads what it's sent and never answers.
    def with_stalled_git
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "git"), "#!/bin/sh\ncat > /dev/null\nsleep 30\n")
        File.chmod(0o755, File.join(dir, "git"))
        path = ENV.fetch("PATH")
        ENV["PATH"] = "#{dir}:#{path}"
        yield dir
      ensure
        ENV["PATH"] = path
      end
    end

    def test_a_command_that_stalls_fails_at_its_deadline
      with_stalled_git do |dir|
        error = assert_raises(Error) { Git.new(dir, deadline: 1).run("fetch", input: "") }
        assert_match "timed out after 1s", error.message
      end
    end

    def test_a_read_that_stalls_fails_at_its_deadline
      with_stalled_git do |dir|
        git = Git.new(dir, deadline: 1)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        error = assert_raises(Error) { git.read("0" * 40) }

        assert_match "timed out after 1s", error.message
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
      end
    end

    def test_a_reader_that_died_starts_over_on_the_next_read
      Dir.mktmpdir do |dir|
        system("git", "init", "-q", dir, exception: true)
        sha = IO.popen(["git", "-C", dir, "hash-object", "-w", "--stdin"], "r+") { |io| io.write("hi\n"); io.close_write; io.read.strip }
        git = Git.new(dir)
        assert_equal "hi\n", git.read(sha)

        Process.kill("KILL", git.send(:batch).last.pid)
        git.send(:batch).last.join
        assert_raises(Error) { git.read(sha) }
        assert_equal "hi\n", git.read(sha)
      end
    end
  end
end
