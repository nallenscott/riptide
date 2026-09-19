# frozen_string_literal: true

require "test_helper"

module Riptide
  class Selector
    class DecisionTest < Minitest::Test
      def test_summary_for_a_full_suite_decision_states_the_reason
        decision = Decision.new(mode: :full, reason: "no dependency map yet", selected: [])

        assert_equal "full suite (no dependency map yet)", decision.summary
      end

      def test_summary_for_a_selected_decision_lists_every_test_and_why
        decision = Decision.new(mode: :selected, reason: nil, selected: [
          { class_name: "ProviderTest", method_name: "test_a", reasons: ["app/models/provider.rb changed within a covered range"] }
        ])

        assert_equal(
          "1 tests\n  ProviderTest#test_a: app/models/provider.rb changed within a covered range",
          decision.summary
        )
      end

      def test_summary_includes_every_reason_when_a_test_was_selected_more_than_once
        decision = Decision.new(mode: :selected, reason: nil, selected: [
          { class_name: "ProviderTest", method_name: "test_a", reasons: ["reason one", "reason two"] }
        ])

        assert_equal "1 tests\n  ProviderTest#test_a: reason one, reason two", decision.summary
      end

      def test_summary_adds_a_total_when_given_one
        decision = Decision.new(mode: :selected, reason: nil, selected: [
          { class_name: "ProviderTest", method_name: "test_a", reasons: ["some reason"] }
        ])

        assert_equal "1/50 tests\n  ProviderTest#test_a: some reason", decision.summary(total: 50)
      end

      def test_summary_for_an_empty_selection_has_no_trailing_list
        decision = Decision.new(mode: :selected, reason: nil, selected: [])

        assert_equal "0 tests", decision.summary
      end
    end
  end
end
