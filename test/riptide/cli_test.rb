# frozen_string_literal: true

require "test_helper"

module Riptide
  class CLITest < Minitest::Test
    include GitFixture

    def test_call_returns_an_error_for_a_not_yet_implemented_command
      _, err = capture_io { assert_equal 1, CLI.new(["why"]).call }

      assert_match(/not yet implemented/, err)
    end

    def test_call_returns_an_error_for_an_unknown_command
      _, err = capture_io { assert_equal 1, CLI.new(["bogus"]).call }

      assert_match(/unknown command/, err)
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

    def test_plan_command_reports_a_decision_without_touching_runnable_methods
      in_repo do |root|
        write_and_commit(root, "test/test_helper.rb", "require 'minitest/autorun'\n", message: "base")
        write_and_commit(root, "test/models/plan_fixture_test.rb", <<~RUBY, message: "add test")
          require "test_helper"
          Object.const_set(:CLIPlanFixtureTest, Class.new(Minitest::Test) { def test_a; end })
        RUBY

        Riptide.configuration.test_glob = "test/models/**/*_test.rb"
        Riptide.configuration.store_path = File.join(root, "tmp", "riptide.db")

        out, = capture_io { CLI.new(["plan"], root: root).send(:plan_command) }

        assert_match(/No dependency map found/, out)
        assert_equal ["test_a"], CLIPlanFixtureTest.runnable_methods
      ensure
        Riptide.configuration.test_glob = "test/**/*_test.rb"
        Riptide.configuration.store_path = "tmp/riptide/riptide.db"
        if defined?(CLIPlanFixtureTest)
          Minitest::Runnable.runnables.delete(CLIPlanFixtureTest)
          Object.send(:remove_const, :CLIPlanFixtureTest)
        end
      end
    end
  end
end
