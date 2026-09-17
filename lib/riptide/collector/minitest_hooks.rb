# frozen_string_literal: true

module Riptide
  class Collector
    # Wraps each Minitest test method in a Collector window. Extend
    # Minitest::Test with this module, then set +on_capture+ to receive
    # (test_class_name, test_method_name, coverage) as each test finishes.
    #
    # The window runs from after_setup to before_teardown, so it covers the
    # test method body itself but not a shared setup/teardown block. Code
    # that only ever runs in setup, never touched again by the test method,
    # won't show up in that test's coverage.
    module MinitestHooks
      class << self
        attr_accessor :on_capture, :root
      end

      def after_setup
        super
        @riptide_collector = Collector.new(root: MinitestHooks.root || Dir.pwd)
        @riptide_collector.start
      end

      def before_teardown
        coverage = @riptide_collector.stop
        MinitestHooks.on_capture&.call(self.class.name, name, coverage)
        super
      end
    end
  end
end
