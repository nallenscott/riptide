# frozen_string_literal: true

require "test_helper"

class TestRiptide < Minitest::Test
  include GitFixture

  def test_that_it_has_a_version_number
    refute_nil ::Riptide::VERSION
  end

  def test_default_base_uses_merge_base_when_the_remote_ref_exists
    in_repo do |root|
      write_and_commit(root, "a.txt", "1\n", message: "base")
      base_sha = `git rev-parse HEAD`.strip
      system("git", "update-ref", "refs/remotes/origin/main", base_sha, exception: true)

      write_and_commit(root, "a.txt", "2\n", message: "feature work")

      assert_equal base_sha, Riptide.default_base
    end
  end

  def test_default_base_falls_back_to_the_ref_itself_when_it_has_no_local_history
    in_repo do |root|
      write_and_commit(root, "a.txt", "1\n", message: "base")

      assert_equal "origin/main", Riptide.default_base
    end
  end
end
