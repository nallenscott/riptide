# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Riptide
  class DiffTest < Minitest::Test
    def test_hunks_parses_a_multi_line_change_with_explicit_counts
      text = <<~DIFF
        @@ -5,0 +6 @@ l5
        +NEW
      DIFF

      hunk = Diff.hunks(text).first

      assert_equal 5, hunk.old_start
      assert_equal 0, hunk.old_count
      assert_equal 6, hunk.new_start
      assert_equal 1, hunk.new_count
    end

    def test_hunks_defaults_count_to_one_when_omitted
      text = <<~DIFF
        @@ -5 +8 @@ l4
        -line5
        +CHANGED_LINE5
      DIFF

      hunk = Diff.hunks(text).first

      assert_equal 5, hunk.old_start
      assert_equal 1, hunk.old_count
      assert_equal 8, hunk.new_start
      assert_equal 1, hunk.new_count
    end

    def test_hunks_are_ordered_by_old_start_even_if_input_is_not
      text = <<~DIFF
        @@ -20 +23 @@
        -x
        +y
        @@ -5,0 +6 @@
        +z
      DIFF

      old_starts = Diff.hunks(text).map(&:old_start)

      assert_equal [5, 20], old_starts
    end

    def test_translate_range_shifts_a_range_below_a_pure_insertion
      hunks = [Diff::Hunk.new(0, 0, 1, 3)] # insert 3 lines at the very top

      assert_equal [7, 13], Diff.translate_range(hunks, 4, 10)
    end

    def test_translate_range_leaves_a_range_above_the_hunk_untouched
      hunks = [Diff::Hunk.new(50, 0, 51, 5)] # insertion well after the range

      assert_equal [4, 10], Diff.translate_range(hunks, 4, 10)
    end

    def test_translate_range_returns_nil_when_a_modification_overlaps_the_range
      hunks = [
        Diff::Hunk.new(0, 0, 1, 3),  # unrelated insertion above, pure shift
        Diff::Hunk.new(5, 1, 8, 1)   # real change at old line 5, inside [4,10]
      ]

      assert_nil Diff.translate_range(hunks, 4, 10)
    end

    def test_translate_range_treats_an_insertion_inside_the_range_as_overlapping
      hunks = [Diff::Hunk.new(6, 0, 7, 1)] # new line inserted after old line 6

      assert_nil Diff.translate_range(hunks, 4, 10)
    end

    def test_translate_range_treats_a_deletion_that_touches_the_range_edge_as_overlapping
      hunks = [Diff::Hunk.new(10, 1, 10, 0)] # old line 10 deleted, right at the range's edge

      assert_nil Diff.translate_range(hunks, 4, 10)
    end

    def test_translate_range_handles_a_block_moved_within_the_file_as_two_overlaps
      # git has no move-detection for intra-file line ranges: a block moved
      # verbatim shows up as a delete at the old location plus an insert at
      # the new one. A test covering either location should be treated as
      # touched, a safe false positive rather than a silently stale range.
      hunks = [
        Diff::Hunk.new(1, 4, 0, 0),  # method_a deleted from the top
        Diff::Hunk.new(11, 0, 8, 4)  # method_a re-inserted at the bottom
      ]

      assert_nil Diff.translate_range(hunks, 1, 4)
    end

    def test_unified_and_hunks_against_real_git_blobs
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          system("git", "init", "-q", ".", exception: true)

          File.write("v1.txt", (1..10).map { |n| "l#{n}\n" }.join)
          File.write("v2.txt", (1..10).map { |n| n == 5 ? "l5\nNEW\n" : "l#{n}\n" }.join)

          blob1 = `git hash-object -w v1.txt`.strip
          blob2 = `git hash-object -w v2.txt`.strip

          hunks = Diff.hunks(Diff.unified(blob1, blob2))

          assert_equal 1, hunks.size
          assert_equal 5, hunks.first.old_start
          assert_equal 0, hunks.first.old_count
        end
      end
    end

    def test_translate_range_raises_on_a_failed_git_invocation
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          system("git", "init", "-q", ".", exception: true)

          assert_raises(Riptide::Error) { Diff.unified("not-a-real-blob", "also-not-real") }
        end
      end
    end
  end
end
