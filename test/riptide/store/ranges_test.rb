# frozen_string_literal: true

require "test_helper"

module Riptide
  class Store
    class RangesTest < Minitest::Test
      def test_compress_empty_input
        assert_equal [], Ranges.compress([])
      end

      def test_compress_a_single_line
        assert_equal [[7, 7]], Ranges.compress([7])
      end

      def test_compress_merges_consecutive_lines_into_one_range
        assert_equal [[3, 5]], Ranges.compress([3, 4, 5])
      end

      def test_compress_keeps_disjoint_lines_as_separate_ranges
        assert_equal [[3, 5], [10, 11], [20, 20]], Ranges.compress([3, 4, 5, 10, 11, 20])
      end

      def test_compress_sorts_unordered_input_first
        assert_equal [[3, 5], [10, 11]], Ranges.compress([11, 4, 10, 3, 5])
      end

      def test_compress_accepts_a_set
        assert_equal [[3, 5]], Ranges.compress(Set[5, 3, 4])
      end
    end
  end
end
