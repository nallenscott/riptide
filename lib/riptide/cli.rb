# frozen_string_literal: true

module Riptide
  class CLI
    def initialize(argv, root: Dir.pwd)
      @argv = argv
      @root = root
    end

    # Returns nil for the normal run path, letting minitest/autorun's
    # at_exit hook decide the process exit status once tests finish, or an
    # integer for a command that doesn't get that far.
    def call
      command, = @argv

      case command
      when "run", nil
        run_command
        nil
      when "rebuild"
        rebuild_command
        nil
      when "plan"
        plan_command
        nil
      when "why"
        warn "riptide #{command}: not yet implemented"
        1
      else
        warn "riptide: unknown command #{command.inspect}"
        1
      end
    end

    private

    def run_command
      perform_run(Store.new(path: Riptide.configuration.store_path))
    end

    def rebuild_command
      store = Store.new(path: Riptide.configuration.store_path)
      puts "Rebuilding dependency map from scratch..."
      store.reset!
      perform_run(store)
    end

    # Same decision-making as run, stops before Runner ever touches
    # anything, nothing gets filtered or executed.
    def plan_command
      store = Store.new(path: Riptide.configuration.store_path)
      load_test_files
      discovered = Riptide.discovered_tests_by_file(root: @root)
      decision = store.empty? ? bootstrap_decision : compute_decision(store, discovered)
      report(decision, discovered.values.flatten(1).size)
    end

    # Loading test files first, before deciding anything, is what gives
    # discovered_tests_by_file current ground truth: Minitest discovers
    # every test class the moment its file is required, regardless of
    # what later gets filtered down to run, verified directly against
    # Minitest's -n filtering behavior.
    def perform_run(store)
      load_test_files
      discovered = Riptide.discovered_tests_by_file(root: @root)
      store.prune_except(discovered.values.flatten(1))

      decision = store.empty? ? bootstrap_decision : compute_decision(store, discovered)
      report(decision, discovered.values.flatten(1).size)

      Runner.new(decision: decision).apply
    end

    def bootstrap_decision
      puts "No dependency map found."
      puts "Running full suite and building one..."
      Selector::Decision.new(mode: :full, reason: "no dependency map yet", selected: [])
    end

    def compute_decision(store, discovered)
      base = Riptide.default_base
      puts "Comparing HEAD against #{base}"
      Selector.new(store: store, root: @root, discovered_tests_by_file: discovered).select(base: base)
    end

    def report(decision, total)
      puts "Selected: #{decision.summary(total: total)}"
    end

    # Test files, and test_helper itself, commonly require each other with a
    # bare require "test_helper" rather than require_relative, matching how
    # Rake::TestTask and bin/rails test both add the app root and test/ to
    # $LOAD_PATH before requiring anything.
    def load_test_files
      test_dir = File.join(@root, File.dirname(Riptide.configuration.test_helper_path))
      $LOAD_PATH.unshift(@root, test_dir)

      require File.join(@root, Riptide.configuration.test_helper_path)

      exclude = Riptide.configuration.test_exclude_patterns
      files = Dir.glob(File.join(@root, Riptide.configuration.test_glob)).sort
      files = files.reject { |f| exclude.any? { |pattern| f.match?(pattern) } } unless exclude.empty?
      files.each { |f| require f }
    end
  end
end
