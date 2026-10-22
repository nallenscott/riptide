# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Riptide
  class RunnerTest < Minitest::Test
    def fake_runnable(name)
      Class.new { define_singleton_method(:name) { name } }
    end

    def test_a_full_decision_leaves_runnables_alone
      klass = fake_runnable("FullTest")
      klass.define_singleton_method(:runnable_methods) { %w[test_a] }
      Minitest::Runnable.stub(:runnables, [klass]) { Runner.new(decision: Selector::Decision.new(mode: :full, selected: [], total: 1)).apply }

      assert_equal %w[test_a], klass.runnable_methods
    end

    def test_a_selected_decision_narrows_each_class_to_its_selected_methods
      a = fake_runnable("ATest")
      b = fake_runnable("BTest")
      selected = [{ test: %w[ATest test_one], reason: "x" }]
      Minitest::Runnable.stub(:runnables, [a, b]) { Runner.new(decision: Selector::Decision.new(mode: :selected, selected: selected, total: 3)).apply }

      assert_equal %w[test_one], a.runnable_methods
      assert_empty b.runnable_methods
    end
  end
end
