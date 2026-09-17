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
  end
end
