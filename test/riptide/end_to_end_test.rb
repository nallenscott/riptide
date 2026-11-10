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

    # PR numbers, by branch.
    PRS = { "pr-a" => "1", "pr-b" => "2", "pr-c" => "3" }.freeze

    # Runs the suite like a CI build of the checked-out branch and returns
    # the names of the tests the plan selected. main harvests, stable
    # harvests on top of main, and everything else is a PR into +base+.
    def build(dir, mode: "dry_run", base: "main")
      branch = git(dir, "rev-parse", "--abbrev-ref", "HEAD").strip
      flags = { "main" => %w[--branch main --harvest], "stable" => %w[--branch stable --harvest --upstream main] }
              .fetch(branch) { ["--pr", PRS.fetch(branch), "--target", base] }
      sh(dir, "ruby", EXE, "fetch", *flags)
      # A failing test still publishes, the way CI does.
      @output, = Open3.capture2e({ "RIPTIDE_MODE" => mode }, "ruby", "-I", LIB, "test/suite_test.rb", chdir: dir)
      @published = sh(dir, "ruby", EXE, "publish", "--suite", "unit", *flags)
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

    # The units on the remote, by branch name, each with both its refs.
    def units(remote)
      names = PRS.invert
      keys = %w[runs stamps].map do |kind|
        prefix = "refs/riptide/#{kind}/unit/"
        git(remote, "for-each-ref", "--format=%(refname)", prefix).lines.map { |ref| ref.strip.delete_prefix(prefix) }
      end
      assert_equal(*keys, "every unit has both refs")
      keys.first.map { |key| key.start_with?("prs/") ? names.fetch(key.delete_prefix("prs/")) : key.delete_prefix("branches/") }.sort
    end

    # Merges +branch+ into main the way GitHub would, keeping the branch.
    def merge(dir, branch, style)
      git(dir, "checkout", "-q", "main")
      case style
      when :squash
        git(dir, "merge", "-q", "--squash", branch)
        git(dir, "commit", "-qm", "merge #{branch}")
      when :merge then git(dir, "merge", "-q", "--no-ff", "-m", "merge #{branch}", branch)
      when :rebase
        git(dir, "rebase", "-q", "main", branch)
        git(dir, "checkout", "-q", "main")
        git(dir, "merge", "-q", "--ff-only", branch)
      end
      git(dir, "push", "-q", "origin", "main")
    end

    %i[squash merge rebase].each do |style|
      define_method(:"test_prs_main_and_releases_only_run_what_changed_with_#{style}_merges") do
        with_project do |dir, remote|
          assert_equal %w[test_both test_other test_widget], build(dir), "the first build has nothing recorded"
          assert_empty build(dir), "an unchanged tree runs nothing"

          git(dir, "checkout", "-q", "-b", "pr-a", "main")
          write(dir, "app/widget.rb", WIDGET.sub("2", "1 + 1"))
          git(dir, "commit", "-qam", "widget")
          git(dir, "checkout", "-q", "-b", "pr-b", "main")
          write(dir, "app/other.rb", OTHER.sub("3", "1 + 2"))
          git(dir, "commit", "-qam", "other")
          git(dir, "push", "-q", "origin", "pr-a", "pr-b")

          git(dir, "checkout", "-q", "pr-a")
          assert_equal %w[test_both test_widget], build(dir), "a PR runs only what it changed"
          git(dir, "checkout", "-q", "pr-b")
          assert_equal %w[test_both test_other], build(dir), @reasons.inspect
          assert_equal %w[main pr-a pr-b], units(remote)

          merge(dir, "pr-a", style)
          assert_empty build(dir), "main reuses the PR's runs"
          assert_equal %w[main pr-b], units(remote), "main cleans up after the PR that landed"

          merge(dir, "pr-b", style)
          assert_equal %w[test_both], build(dir), "main reruns only the test both PRs changed"
          assert_equal %w[main], units(remote)
          assert_empty build(dir), "and keeps what it learned"

          git(dir, "checkout", "-q", "-b", "stable")
          git(dir, "push", "-q", "origin", "stable")
          assert_empty build(dir), "a release cut from main runs nothing"
          assert_equal %w[main], units(remote), "stable reads main's and has nothing of its own to save"
        end
      end
    end

    def test_a_pr_publishes_only_the_runs_it_affected
      with_project do |dir, remote|
        build(dir)
        git(dir, "checkout", "-q", "-b", "pr-a", "main")
        write(dir, "app/widget.rb", WIDGET.sub("2", "1 + 1"))
        git(dir, "commit", "-qam", "widget")
        git(dir, "push", "-q", "origin", "pr-a")
        build(dir)

        ref = "refs/riptide/runs/unit/prs/1"
        paths = git(remote, "ls-tree", "-r", "--name-only", ref).lines.map(&:strip)
        assert(paths.grep(%r{\Amanifest/}).any? { |path| git(remote, "show", "#{ref}:#{path}").include?("app/widget.rb") })
        listed = paths.grep(%r{\Atests/}).flat_map { |path| JSON.parse(git(remote, "show", "#{ref}:#{path}")).map { |_, name, _, _| name } }
        assert_equal %w[test_both test_widget], listed.sort
      end
    end

    # main never reads a PR that hasn't landed, so its failures stay on the
    # PR until it merges or ages out.
    def test_an_unmerged_pr_s_failures_dont_reach_main
      with_project do |dir, remote|
        build(dir)
        git(dir, "checkout", "-q", "-b", "pr-a", "main")
        write(dir, "app/widget.rb", WIDGET.sub("2", "4"))
        git(dir, "commit", "-qam", "break widget")
        git(dir, "push", "-q", "origin", "pr-a")
        build(dir)
        assert_equal %w[test_both test_widget], build(dir), "a PR reruns what failed"

        git(dir, "checkout", "-q", "main")
        assert_empty build(dir)
        assert_equal %w[main pr-a], units(remote)
      end
    end

    # pr-c is stacked on pr-a and merges into it first. pr-a's branch has
    # no unit of its own, so pr-c starts from nothing. main harvests pr-a,
    # which carries everything pr-c changed, and pr-c ages out.
    def test_stacked_prs_land_together
      with_project do |dir, remote|
        build(dir)
        git(dir, "checkout", "-q", "-b", "pr-a", "main")
        write(dir, "app/widget.rb", WIDGET.sub("2", "1 + 1"))
        git(dir, "commit", "-qam", "widget")
        git(dir, "push", "-q", "origin", "pr-a")
        assert_equal %w[test_both test_widget], build(dir)
        git(dir, "checkout", "-q", "-b", "pr-c", "pr-a")
        write(dir, "app/other.rb", OTHER.sub("3", "1 + 2"))
        git(dir, "commit", "-qam", "other")
        git(dir, "push", "-q", "origin", "pr-c")
        assert_equal %w[test_both test_other test_widget], build(dir, base: "pr-a"), "a stacked PR has no target unit to read"

        git(dir, "checkout", "-q", "pr-a")
        git(dir, "merge", "-q", "--no-ff", "-m", "merge pr-c", "pr-c")
        git(dir, "push", "-q", "origin", "pr-a")
        assert_equal %w[test_both test_other], build(dir), "a PR build doesn't harvest what merged into it"
        merge(dir, "pr-a", :merge)
        assert_empty build(dir)
        assert_equal %w[main pr-c], units(remote)
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

    # The test helper loads before riptide can trace anything, so in an app
    # that records its tests, every test depends on all of it.
    def test_editing_the_test_helper_reruns_the_suite
      with_project do |dir|
        helper = HELPER.sub('["app/**/*.rb"]', '["app/**/*.rb", "test/**/*.rb"]')
        write(dir, "test/test_helper.rb", helper)
        git(dir, "commit", "-qam", "record tests")
        build(dir)
        write(dir, "test/test_helper.rb", helper + "SETTING = 1\n")

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
        refute_includes git(remote, "ls-tree", "-r", "refs/riptide/runs/unit/branches/main"), secret
        refute_includes git(remote, "rev-list", "--objects", "--all"), secret
      end
    end
  end
end
