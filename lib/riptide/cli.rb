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
      decision = store.empty? ? bootstrap_decision : compute_decision(store)

      report(decision)

      load_test_files
      Runner.new(decision: decision, store: store, root: @root).apply
    end

    def bootstrap_decision
      puts "No dependency map found."
      puts "Running full suite and building one..."
      Selector::Decision.new(mode: :full, reason: "no dependency map yet", selected: [])
    end

    def compute_decision(store)
      base = default_base
      puts "Comparing HEAD against #{base}"
      Selector.new(store: store, root: @root).select(base: base)
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
