# frozen_string_literal: true

module Riptide
  class Collector
    # Wraps each Minitest test method in a Collector window. Extend
    # Minitest::Test with this module, then set +on_capture+ to receive
    # (test_class_name, test_method_name, coverage) as each test finishes.
    #
    # The window runs from after_setup to before_teardown, so it covers the
    # test method body itself but not a shared setup/teardown block. Code
    # that only runs in setup, not touched again by the test method,
    # won't show up in that test's coverage.
    module MinitestHooks
      class << self
        attr_accessor :on_capture, :root
      end

      # Configures capture to persist into +store+, rooted at +root+.
      # Called by the Minitest plugin (lib/minitest/riptide_plugin.rb),
      # the one place this gets wired outside this gem's test suite.
      #
      # Deliberately does not include this module into Minitest::Test.
      # This method also gets called directly from riptide's unit
      # tests to check the wiring itself, and Minitest::Test.include is a
      # global, irreversible mutation for the rest of the process, doing
      # it here once broke every other test in this gem's suite that
      # ran afterward. The plugin is the only place that calls include.
      def self.wire(store:, root:)
        self.root = root
        self.on_capture = lambda do |class_name, method_name, coverage|
          next if coverage.empty?

          blob_shas = coverage.keys.to_h { |file| [file, Diff.blob_sha(File.join(root, file))] }
          store.record(class_name: class_name, method_name: method_name, coverage: coverage, blob_shas: blob_shas)
        end
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
