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
      # +should_record+, when given, decides whether a given (class_name,
      # method_name)'s coverage actually gets written - nil records
      # everything, matching a real run where every test that executes
      # should have its coverage refreshed. The dry_run plugin path passes
      # +decision.method(:runs?)+ so a test riptide wouldn't have selected
      # doesn't have its record refreshed just because dry_run let it
      # execute anyway (see Riptide::Selector::Decision#runs?).
      #
      # Deliberately does not include this module into Minitest::Test.
      # This method also gets called directly from riptide's unit
      # tests to check the wiring itself, and Minitest::Test.include is a
      # global, irreversible mutation for the rest of the process, doing
      # it here once broke every other test in this gem's suite that
      # ran afterward. The plugin is the only place that calls include.
      def self.wire(store:, root:, should_record: nil)
        self.root = root
        # A file's blob sha can't change mid-run, the working tree is fixed
        # for the whole build, so a file every test in this process touches
        # (test_helper.rb, a shared concern) only needs hashing once here,
        # not once per test that happens to cover it.
        blob_sha_cache = {}
        self.on_capture = lambda do |class_name, method_name, coverage|
          next if coverage.empty?
          next if should_record && !should_record.call(class_name, method_name)

          blob_shas = coverage.keys.to_h do |file|
            [file, blob_sha_cache[file] ||= Diff.blob_sha(File.join(root, file))]
          end
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
