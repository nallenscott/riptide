# frozen_string_literal: true

require "set"

module Riptide
  # Records one run per test. Wraps Minitest::Test#run, which every runner
  # ends up calling: Minitest 5, Minitest 6 and Rails' parallel workers, so
  # the window covers setup, the test and teardown alike.
  class Recorder
    class << self
      attr_reader :current

      def install(recorder)
        @current = recorder
        Minitest::Test.prepend(Hook) unless Minitest::Test < Hook
      end
    end

    module Hook
      def run
        recorder = Recorder.current
        recorder ? recorder.record(self) { super } : super
      end
    end

    # +env_set+ is the id of the process's env, which every run shares.
    def initialize(store:, inputs:, env_set:)
      @store = store
      @inputs = inputs
      @env_set = env_set
      @written_sets = Set.new
      @window = Mutex.new
      @warned = Set.new
    end

    # A started record goes out before every test, so a test that never
    # finishes, from a hang, a crash or a kill, counts as a failure. A test
    # running alongside another one in a different thread can't have its
    # lines told apart, so only its outcome is recorded.
    def record(test)
      started(test)
      unless @window.try_lock
        result = yield
        outcome(test, result)
        return result
      end

      begin
        Tracer.open_window
        Collectors.open
        result = nil
        begin
          result = yield
        ensure
          traced = Tracer.close_window
          window = Collectors.close
          persist(test, result, traced, window)
        end
        result
      ensure
        @window.unlock
      end
    end

    def absorb_load_facts
      facts = Tracer.drain_load_facts
      @inputs.absorb(facts)
      facts.each do |path, lines|
        @store.append_load_facts(@inputs.sha(path), lines) if @inputs.recordable?(path) && File.file?(File.join(@inputs.root, path))
      rescue Inputs::Stale, SystemCallError
        next
      end
    end

    private

    # Load facts come first: a class that loaded during this test feeds what
    # the test depends on. A skipped test closes its start with nothing. A
    # failure to trace still records the outcome, so a failure still counts.
    def persist(test, result, traced, window)
      absorb_load_facts
      return outcome(test, result) if result.nil? || result.skipped? || !result.passed?

      inputs, owner_sets = @inputs.for_test(traced, window)
      sets = [@env_set] + owner_sets.values.map { |files| share(files) }
      @store.append_run(Store::Run.new(test: key(test), at: Time.now.to_f, passed: true, sets: sets, inputs: inputs, file: file(test)))
    rescue StandardError => e
      warn "[riptide] couldn't record #{test.class.name}##{test.name}: #{e.class}: #{e.message}" if @warned.add?(e.class)
      outcome(test, result)
    end

    def started(test)
      @store.append_start(key(test))
    rescue StandardError
      nil
    end

    # Records how the test ended without what it ran. A skip is no outcome.
    def outcome(test, result)
      return if result.nil?

      run = Store::Run.new(test: key(test), at: Time.now.to_f, passed: result.passed? || result.skipped?, file: file(test))
      run.passed = nil if result.skipped?
      @store.append_run(run)
    rescue StandardError
      nil
    end

    def key(test) = [test.class.name, test.name]

    # The file that defines the test's class, relative to the root. A test
    # a library generates, like shoulda's `should`, lives in its class's
    # file too. Nil when that's outside the app.
    def file(test)
      path = Object.const_source_location(test.class.name)&.first
      root = "#{File.realpath(@inputs.root)}/"
      path = path && File.realpath(path)
      path.delete_prefix(root) if path&.start_with?(root)
    rescue StandardError
      nil
    end

    def share(files)
      id = Store.set_id(files)
      @store.append_set(id, files) if @written_sets.add?(id)
      id
    end
  end
end
