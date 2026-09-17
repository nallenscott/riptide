# frozen_string_literal: true

module Riptide
  class Runner
    def initialize(decision:, store:, root: Dir.pwd)
      @decision = decision
      @store = store
      @root = root
    end

    # Prepares the process for Minitest.run: filters discovered runnables
    # down to the decision's selection (a :full decision runs everything,
    # so nothing gets filtered), and wires the collector so every test that
    # actually runs gets its coverage persisted back to Store. Does not call
    # Minitest.run itself, that's the caller's job.
    #
    # +runnables+ defaults to Minitest's real global list, but can be
    # overridden, filtering mutates each class's singleton runnable_methods
    # directly, and that has to be a caller-supplied list in tests, or it'd
    # mutate every already-loaded test class for the rest of the process.
    def apply(runnables: Minitest::Runnable.runnables)
      filter_runnables(runnables) unless @decision.mode == :full
      wire_collector
    end

    private

    def filter_runnables(runnables)
      allowed = Hash.new { |h, k| h[k] = [] }
      @decision.selected.each { |s| allowed[s[:class_name]] << s[:method_name] }

      runnables.each do |klass|
        methods = allowed[klass.name]
        klass.define_singleton_method(:runnable_methods) { methods }
      end
    end

    def wire_collector
      store = @store
      root = @root

      Collector::MinitestHooks.root = root
      Collector::MinitestHooks.on_capture = lambda do |class_name, method_name, coverage|
        next if coverage.empty?

        blob_shas = coverage.keys.to_h { |file| [file, Diff.blob_sha(File.join(root, file))] }
        store.record(class_name: class_name, method_name: method_name, coverage: coverage, blob_shas: blob_shas)
      end
    end
  end
end
