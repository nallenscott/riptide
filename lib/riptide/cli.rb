# frozen_string_literal: true

module Riptide
  class CLI
    def initialize(argv, root: Dir.pwd)
      @argv = argv
      @root = root
    end

    # Returns nil for the normal run path, letting minitest/autorun's own
    # at_exit hook decide the process exit status once tests finish, or an
    # integer for a command that never gets that far.
    def call
      command, = @argv

      case command
      when "run", nil
        run_command
        nil
      when "plan", "why", "rebuild"
        warn "riptide #{command}: not yet implemented"
        1
      else
        warn "riptide: unknown command #{command.inspect}"
        1
      end
    end

    private

    def run_command
      store = Store.new(path: File.join(@root, Riptide.configuration.db_path))

      # Loading test files first, before deciding anything, is what gives
      # discovered_tests_by_file real, current ground truth: Minitest
      # discovers every test class the moment its file is required,
      # regardless of what later gets filtered down to run, confirmed
      # directly against Minitest's own -n filtering behavior.
      load_test_files
      discovered = discovered_tests_by_file
      store.prune_except(discovered.values.flatten(1))

      decision = store.empty? ? bootstrap_decision : compute_decision(store, discovered)
      report(decision)

      Runner.new(decision: decision).apply
    end

    # { relative_path => [[class_name, method_name], ...] }, every test
    # method Minitest currently knows about, grouped by the file it's
    # actually defined in via Method#source_location, not a naming
    # convention. methods_matching, not runnable_methods: the latter
    # sorts/shuffles based on Minitest.seed, which isn't set yet this
    # early, before Minitest.run's own arg parsing has run, and neither
    # pruning nor selection needs run order, just the raw set of names.
    def discovered_tests_by_file
      Minitest::Runnable.runnables.each_with_object(Hash.new { |h, k| h[k] = [] }) do |klass, mapping|
        klass.methods_matching(/^test_/).each do |method|
          file = klass.instance_method(method).source_location&.first
          next unless file

          mapping[file.delete_prefix("#{@root}/")] << [klass.name, method]
        end
      end
    end

    def bootstrap_decision
      puts "No dependency map found."
      puts "Running full suite and building one..."
      Selector::Decision.new(mode: :full, reason: "no dependency map yet", selected: [])
    end

    def compute_decision(store, discovered)
      base = default_base
      puts "Comparing HEAD against #{base}"
      Selector.new(store: store, root: @root, discovered_tests_by_file: discovered).select(base: base)
    end

    # Merge-base against origin/<main_branch> when that ref exists, the
    # common ancestor a normal feature branch diverged from. Falls back to
    # main_branch itself when there's no such remote ref, e.g. no "origin"
    # configured at all.
    def default_base
      Diff.merge_base("origin/#{Riptide.configuration.main_branch}")
    rescue Error
      Riptide.configuration.main_branch
    end

    def report(decision)
      case decision.mode
      when :full
        puts "Selected: full suite (#{decision.reason})"
      when :selected
        puts "Selected: #{decision.selected.size} tests"
      end
    end

    # Test files, and test_helper itself, commonly require each other with a
    # bare require "test_helper" rather than require_relative, matching how
    # Rake::TestTask and bin/rails test both add the app root and test/ to
    # $LOAD_PATH before requiring anything.
    def load_test_files
      test_dir = File.join(@root, File.dirname(Riptide.configuration.test_helper_path))
      $LOAD_PATH.unshift(@root, test_dir)

      require File.join(@root, Riptide.configuration.test_helper_path)
      Dir.glob(File.join(@root, Riptide.configuration.test_glob)).sort.each { |f| require f }
    end
  end
end
