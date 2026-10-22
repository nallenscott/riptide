# frozen_string_literal: true

require "test_helper"

module Riptide
  class DiffTest < Minitest::Test
    include GitFixture

    def test_blob_sha_matches_git_hash_object
      in_repo do |root|
        File.write("a.rb", "puts 1\n")

        assert_equal `git hash-object a.rb`.strip, Diff.blob_sha(File.join(root, "a.rb"))
      end
    end

    def test_hunks_describe_rewrites_insertions_and_deletions
      hunks = Diff.hunks("a\nb\nc\nd\n", "a\nB\nc\nnew\nd\n")

      assert_equal [Diff::Hunk.new(2, 1, 2, 1), Diff::Hunk.new(3, 0, 4, 1)], hunks
    end

    def test_hunks_is_empty_for_identical_text
      assert_empty Diff.hunks("same\n", "same\n")
    end
  end
end
