# frozen_string_literal: true

require "test_helper"

module Riptide
  class CLITest < Minitest::Test
    include GitFixture

    def test_call_returns_an_error_for_a_not_yet_implemented_command
      _, err = capture_io { assert_equal 1, CLI.new(["plan"]).call }

      assert_match(/not yet implemented/, err)
    end

    def test_call_returns_an_error_for_an_unknown_command
      _, err = capture_io { assert_equal 1, CLI.new(["bogus"]).call }

      assert_match(/unknown command/, err)
    end

    def test_default_base_uses_merge_base_when_the_remote_ref_exists
      in_repo do |root|
        write_and_commit(root, "a.txt", "1\n", message: "base")
        base_sha = `git rev-parse HEAD`.strip
        system("git", "update-ref", "refs/remotes/origin/main", base_sha, exception: true)

        write_and_commit(root, "a.txt", "2\n", message: "feature work")

        assert_equal base_sha, CLI.new([], root: root).send(:default_base)
      end
    end

    def test_default_base_falls_back_to_main_branch_name_when_no_remote_ref_exists
      in_repo do |root|
        write_and_commit(root, "a.txt", "1\n", message: "base")

        assert_equal "main", CLI.new([], root: root).send(:default_base)
      end
    end

    def test_store_path_joins_a_relative_db_path_to_root
      Riptide.configuration.db_path = "tmp/riptide/riptide.db"

      assert_equal "/app/tmp/riptide/riptide.db", CLI.new([], root: "/app").send(:store_path)
    ensure
      Riptide.configuration.db_path = "tmp/riptide/riptide.db"
    end

    def test_store_path_leaves_an_absolute_db_path_untouched
      Riptide.configuration.db_path = "/workspace/riptide.db"

      assert_equal "/workspace/riptide.db", CLI.new([], root: "/app").send(:store_path)
    ensure
      Riptide.configuration.db_path = "tmp/riptide/riptide.db"
    end

    def test_load_test_files_skips_files_matching_test_exclude_patterns
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "test/controllers"))
        FileUtils.mkdir_p(File.join(root, "test/models"))
        File.write(File.join(root, "test/test_helper.rb"), "require 'minitest/autorun'\n")
        File.write(File.join(root, "test/controllers/widget_controller_test.rb"), <<~RUBY)
          Object.const_set(:CLIFixtureControllerTest, Class.new(Minitest::Test) { def test_a; end })
        RUBY
        File.write(File.join(root, "test/models/widget_test.rb"), <<~RUBY)
          Object.const_set(:CLIFixtureModelTest, Class.new(Minitest::Test) { def test_a; end })
        RUBY

        Riptide.configuration.test_exclude_patterns = [%r{test/controllers}]

        CLI.new([], root: root).send(:load_test_files)

        assert defined?(CLIFixtureModelTest)
        refute defined?(CLIFixtureControllerTest)
      ensure
        Riptide.configuration.test_exclude_patterns = []
        [:CLIFixtureModelTest, :CLIFixtureControllerTest].each do |const|
          next unless Object.const_defined?(const)

          Minitest::Runnable.runnables.delete(Object.const_get(const))
          Object.send(:remove_const, const)
        end
      end
    end
  end
end
