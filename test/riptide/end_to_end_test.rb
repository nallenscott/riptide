# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"

module Riptide
  # Separate Minitest processes against a repository with a remote, the way
  # CI runs them: fetch, run, publish, across a PR, merges to main, and a
  # release branch.
  class EndToEndTest < Minitest::Test
    LIB = File.expand_path("../../lib", __dir__)
    EXE = File.expand_path("../../exe/riptide", __dir__)

    WIDGET = "class Widget\n  def size\n    2\n  end\nend\n"
    OTHER = "class Other\n  def size\n    3\n  end\nend\n"

    HELPER = <<~RUBY
      require "riptide"
      Riptide.configure do |c|
        c.suite = "unit"
        c.mode = ENV.fetch("RIPTIDE_MODE", "dry_run").to_sym
        c.plan_path = "tmp/plan.json"
        c.fallback_patterns = []
        c.source_patterns = ["app/**/*.rb"]
      end
      require "minitest/autorun"
      require "minitest/riptide_plugin"
      require_relative "../app/widget"
      require_relative "../app/other"
      Dir[File.join(__dir__, "support/*.rb")].each { |file| require file }
    RUBY

    TESTS = <<~RUBY
      require_relative "test_helper"
      class SuiteTest < Minitest::Test
        def test_widget = assert_equal(2, Widget.new.size)
        def test_other = assert_equal(3, Other.new.size)
        def test_both = assert_equal(5, Widget.new.size + Other.new.size)
      end
    RUBY

    def sh(dir, *args)
      env = args.first.is_a?(Hash) ? args.shift : {}
      out, status = Open3.capture2e(env, *args, chdir: dir)
      assert status.success?, "#{args.join(" ")} failed:\n#{out}"
      out
    end

    def git(dir, *args) = sh(dir, "git", *args)

    # Runs the suite like a CI build and returns the names of the tests the
    # plan selected.
    def build(dir, mode: "dry_run")
      sh(dir, "ruby", EXE, "fetch", "--suite", "unit")
      @output = sh(dir, { "RIPTIDE_MODE" => mode }, "ruby", "-I", LIB, "test/suite_test.rb")
      sh(dir, "ruby", EXE, "publish", "--suite", "unit")
      @reasons = JSON.parse(File.read(File.join(dir, "tmp/plan.json")))["selected"].map { |entry| "#{entry["test"][1]}: #{entry["reason"]}" }
      @reasons.map { |reason| reason.split(":").first }.sort
    end

    def write(dir, path, content)
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.write(File.join(dir, path), content)
    end

    # A clone of a fresh remote holding the app and its suite, on main.
    def with_project
      Dir.mktmpdir do |base|
        remote = File.join(base, "remote.git")
        dir = File.join(base, "work")
        git(base, "init", "-q", "--bare", "-b", "main", remote)
        git(base, "clone", "-q", remote, dir)
        git(dir, "config", "user.email", "t@t")
        git(dir, "config", "user.name", "t")
        git(dir, "checkout", "-q", "-b", "main")
        write(dir, "app/widget.rb", WIDGET)
        write(dir, "app/other.rb", OTHER)
        write(dir, "test/test_helper.rb", HELPER)
        write(dir, "test/suite_test.rb", TESTS)
        write(dir, ".gitignore", "tmp/\n")
        git(dir, "add", "-A")
        git(dir, "commit", "-qm", "start")
        git(dir, "push", "-q", "origin", "main")
        yield dir, remote
      end
    end

    def test_prs_main_and_releases_only_run_what_changed
      with_project do |dir|
        assert_equal %w[test_both test_other test_widget], build(dir), "the first build has nothing recorded"
        assert_empty build(dir), "an unchanged tree runs nothing"

        git(dir, "checkout", "-q", "-b", "pr-a", "main")
        write(dir, "app/widget.rb", WIDGET.sub("2", "1 + 1"))
        git(dir, "commit", "-qam", "widget")
        git(dir, "checkout", "-q", "-b", "pr-b", "main")
        write(dir, "app/other.rb", OTHER.sub("3", "1 + 2"))
        git(dir, "commit", "-qam", "other")

        git(dir, "checkout", "-q", "pr-a")
        assert_equal %w[test_both test_widget], build(dir), "a PR runs only what it changed"
        git(dir, "checkout", "-q", "pr-b")
        assert_equal %w[test_both test_other], build(dir), @reasons.inspect

        git(dir, "checkout", "-q", "main")
        git(dir, "merge", "-q", "--squash", "pr-a")
        git(dir, "commit", "-qm", "merge a")
        assert_empty build(dir), "main reuses the PR's runs"

        git(dir, "merge", "-q", "--squash", "pr-b")
        git(dir, "commit", "-qm", "merge b")
        assert_equal %w[test_both], build(dir), "main runs only where the two merges collided"

        git(dir, "checkout", "-q", "-b", "stable")
        assert_empty build(dir), "a release cut from main runs nothing"
      end
    end

    def test_enforce_runs_only_the_selected_tests
      with_project do |dir|
        build(dir, mode: "enforce")
        assert_match(/3 runs/, @output)

        write(dir, "app/widget.rb", WIDGET.sub("2", "1 + 1"))
        assert_equal %w[test_both test_widget], build(dir, mode: "enforce")
        assert_match(/2 runs/, @output)
      end
    end

    def test_a_new_file_a_boot_glob_requires_reruns_the_suite
      with_project do |dir|
        build(dir)
        write(dir, "test/support/patch.rb", "class Widget\n  def extra = 1\nend\n")

        assert_equal %w[test_both test_other test_widget], build(dir), @reasons.inspect
      end
    end

    def test_a_file_git_ignores_is_never_recorded_or_pushed
      with_project do |dir, remote|
        write(dir, ".gitignore", "tmp/\nconfig/master.key\n")
        write(dir, "config/master.key", "SECRET\n")
        write(dir, "app/widget.rb", WIDGET.sub("    2\n", "    File.read(File.expand_path('../config/master.key', __dir__)).size - 5\n"))
        git(dir, "commit", "-qam", "read the key")
        git(dir, "push", "-q", "origin", "main")
        build(dir)

        secret = Diff.blob_sha(File.join(dir, "config/master.key"))
        refute_includes git(remote, "ls-tree", "-r", "refs/riptide/unit"), secret
        refute_includes git(remote, "rev-list", "--objects", "--all"), secret
      end
    end
  end
end
