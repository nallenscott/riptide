# frozen_string_literal: true

module Riptide
  class Runner
    def initialize(decision:)
      @decision = decision
    end

    # Filters Minitest's discovered runnables down to the decision's
    # selection. A :full decision runs everything, so nothing gets
    # filtered. Does not call Minitest.run itself, that's the caller's
    # job, and doesn't wire coverage collection either, that's the
    # Minitest plugin's job (lib/minitest/riptide_plugin.rb), triggered by
    # the host app's test_helper.rb, the same way for any test run.
    #
    # +runnables+ defaults to Minitest's global list, but can be
    # overridden, filtering mutates each class's singleton runnable_methods
    # directly, and that has to be a caller-supplied list in tests, or it'd
    # mutate every loaded test class for the rest of the process.
    def apply(runnables: Minitest::Runnable.runnables)
      return if @decision.mode == :full

      allowed = Hash.new { |h, k| h[k] = [] }
      @decision.selected.each { |s| allowed[s[:class_name]] << s[:method_name] }

      runnables.each do |klass|
        methods = allowed[klass.name]
        klass.define_singleton_method(:runnable_methods) { methods }
      end
    end
  end
end
