# frozen_string_literal: true

module Riptide
  # Narrows Minitest's runnables to a decision's selection.
  class Runner
    def initialize(decision:)
      @decision = decision
    end

    def apply
      return if @decision.mode == :full

      allowed = Hash.new { |h, k| h[k] = [] }
      @decision.selected.each { |entry| allowed[entry[:test][0]] << entry[:test][1] }
      Minitest::Runnable.runnables.each do |klass|
        methods = allowed[klass.name]
        klass.define_singleton_method(:runnable_methods) { methods }
      end
    end
  end
end
