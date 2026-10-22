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

    # A test running alongside another one in a different thread can't have
    # its lines told apart, so it runs unrecorded and gets selected next time.
    def record(test)
      return yield unless @window.try_lock

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
    # the test depends on. A skipped test didn't run, so it records nothing.
    # A failure to record leaves the test's result alone, and the test gets
    # selected next time.
    def persist(test, result, traced, window)
      absorb_load_facts
      return if result.nil? || result.skipped?

      inputs, owner_sets = @inputs.for_test(traced, window)
      sets = [@env_set] + owner_sets.values.map { |files| share(files) }
      @store.append_run(Store::Run.new(test: [test.class.name, test.name], at: Time.now.to_f, passed: result.passed?,
                                       sets: sets, inputs: inputs))
    rescue StandardError => e
      warn "[riptide] couldn't record #{test.class.name}##{test.name}: #{e.class}: #{e.message}" if @warned.add?(e.class)
    end

    def share(files)
      id = Store.set_id(files)
      @store.append_set(id, files) if @written_sets.add?(id)
      id
    end
  end
end
