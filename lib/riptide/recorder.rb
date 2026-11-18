# frozen_string_literal: true

require "set"

module Riptide
  # Records one run per test. Wraps Minitest::Test#run, which every runner
  # ends up calling: Minitest 5, Minitest 6 and Rails' parallel workers, so
  # the window covers setup, the test and teardown alike. The test's body
  # runs in a window per top-level statement, each recorded as a set of its
  # own, so the run is what ran around the body plus its statements. Each
  # test class gets a scope around how Minitest runs it, so what its own
  # setup runs, like a before_all, counts for its tests.
  class Recorder
    class << self
      attr_reader :current

      # Test classes are all loaded by now. Each one's hook goes ahead of
      # anything the class defines, so the scope covers its overrides too.
      def install(recorder)
        @current = recorder
        Minitest::Test.prepend(Hook) unless Minitest::Test < Hook
        ClassHook.wrap(Minitest::Runnable.respond_to?(:run_suite) ? :run_suite : :run)
        ClassHook.wrap(:with_info_handler)
        Minitest::Runnable.runnables.each do |klass|
          hooks = klass.singleton_class.ancestors.take_while { |ancestor| ancestor != klass.singleton_class }
          klass.singleton_class.prepend(ClassHook) unless hooks.include?(ClassHook)
        end
      end

      def scope(klass, &block)
        current ? current.scope(klass, &block) : yield
      end

      # Riptide's own work counts for no test: the files it reads, and the
      # app code it loads, like a class it checks for overrides, which runs
      # in a window nobody depends on.
      def aside(&block)
        Tracer.open_window
        Collectors.aside(&block)
      ensure
        Tracer.close_window
      end
    end

    module Hook
      def run
        recorder = Recorder.current
        recorder ? recorder.record(self) { super } : super
      end

      # Teardown runs around the body, not in its last statement.
      def before_teardown
        Recorder.current&.end_body
        super
      end
    end

    # Minitest runs a whole test class with run_suite in Minitest 6, which
    # gave run to single tests, and with run before that. Both run the
    # class's tests inside with_info_handler, which is also what a Rails
    # parallel worker calls around each test it's given.
    module ClassHook
      def self.wrap(name)
        return if method_defined?(name, false)

        define_method(name) { |*args, **options, &block| Recorder.scope(self) { super(*args, **options, &block) } }
      end
    end

    # +process+ turns what ran outside every test and test class into the
    # process's shared set, which every later run gets.
    def initialize(store:, inputs:, process:)
      @store = store
      @inputs = inputs
      @written_sets = Set.new
      @warned = Set.new
      @scopes = [Scope.new { |trace, window| [share(process.call(trace, window), scope: "process")] }]
      @body = nil
      @open = Set.new.compare_by_identity
      @lock = Mutex.new
      @owner = nil
      @depth = 0
      @testing = false
    end

    # A started record goes out before every test, so a test that never
    # finishes, from a hang, a crash or a kill, counts as a failure. A test
    # running alongside another one in a different thread can't have its
    # lines told apart, so only its outcome is recorded.
    def record(test)
      unless enter(test: true)
        started(test)
        result = yield
        outcome(test, result)
        return result
      end

      begin
        settle
        scopes = Recorder.aside do
          started(test)
          scope_sets
        end
        Tracer.open_window
        Collectors.open
        open_body(test)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = nil
        begin
          result = yield
        ensure
          ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
          end_body
          body, @body = @body, nil
          traced = Tracer.close_window
          window = Collectors.close
          Recorder.aside { persist(test, result, scopes, traced, window, body, ms) }
        end
        result
      ensure
        leave(test: true)
      end
    end

    # A test class's scope, open from before anything Minitest runs for it
    # to after the last of it. A class that's already open, like from an
    # override calling super, goes on in the scope it has.
    def scope(klass)
      return yield if @open.include?(klass) || !enter(test: false)

      settle
      @open << klass
      # Most classes set nothing up, and a scope that gathered nothing adds
      # no set.
      @scopes << Scope.new do |trace, window|
        next [] if trace.lines.empty? && trace.receivers.empty? && !window.gathered?

        inputs, owner_sets = @inputs.for_test(trace, window)
        [inputs, *owner_sets.values].reject(&:empty?).map { |files| share(files, scope: "class") }
      end
      Tracer.open_window
      Collectors.open
      begin
        yield
      ensure
        Collectors.close
        Tracer.close_window
        @scopes.pop
        @open.delete(klass)
        leave(test: false)
      end
    end

    # Takes in what boot ran, +trace+ and +window+, and captures it, so a
    # failure turns riptide off before any test runs instead of during each.
    def start(trace, window)
      @scopes.first.absorb(trace, window)
      @scopes.first.sets
    end

    # Ends the split of the running test's body, once, when its teardown
    # starts or the test is over.
    def end_body
      @body = [Tracer.close_body || {}, Collectors.close_body || {}, @span] if @body == :open
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

    # Splits the test's body by its top-level statements, from the source of
    # the file that defines it. A body riptide can't read, like one a library
    # generates, isn't split.
    def open_body(test)
      body = test.method(test.name)
      path, line = body.source_location
      file = path && relative(path)
      ranges = file && @inputs.source_for(file)&.statements_at(line)
      return if ranges.nil? || ranges.empty?

      Tracer.open_body(body, ranges.map(&:first))
      Collectors.open_body
      @body = :open
      # Where the body's statements are, and the line its method or block
      # starts on, which is how the audit finds it again.
      @span = [file, ranges.first.first..ranges.last.last, line]
    rescue StandardError
      Tracer.close_body
      Collectors.close_body
      @body = nil
    end

    # Load facts come first: a class that loaded during this test feeds what
    # the test depends on. A skipped test closes its start with nothing. A
    # failure to trace still records the outcome, so a failure still counts.
    def persist(test, result, scopes, traced, window, body, ms)
      return outcome(test, result) if untraced? || scopes.nil?

      absorb_load_facts
      return outcome(test, result) if result.nil? || result.skipped? || !result.passed?

      traces, collected, span = body
      traced = keep_own_lines(traced, traces, span) if body
      inputs, owners = @inputs.reached(traced, window)
      statements = body ? statements_of(traces, collected, owners) : []
      sets = scopes + @inputs.owner_sets(owners).values.map { |files| share(files) } + statements.filter_map { |statement| statement[1] }
      defined_in = file(test)
      body_file = span&.first unless span&.first == defined_in || statements.empty?
      @store.append_run(Store::Run.new(test: key(test), at: Time.now.to_f, passed: true, sets: sets, inputs: inputs, file: defined_in, body: statements,
                                       ms: ms, body_line: span&.last, body_file: body_file, inherited_from: inherited_from(test)))
    rescue StandardError => e
      warn "[riptide] couldn't record #{test.class.name}##{test.name}: #{e.class}: #{e.message}" if @warned.add?(e.class)
      outcome(test, result)
    end

    # The body's own lines are the test's, not the statements': every test's
    # are its own, so they'd keep identical statements in different tests
    # from sharing a set. They move from +traces+ to the test's +traced+
    # window, so what the run depends on stays the same.
    def keep_own_lines(traced, traces, (file, range))
      own = []
      traces.transform_values! do |statement|
        lines = statement.trace.lines
        next statement unless lines.key?(file)

        mine, rest = lines[file].partition { |line| range.cover?(line) }
        own.concat(mine)
        kept = rest.empty? ? lines.except(file) : lines.merge(file => rest)
        Tracer::Statement.new(Tracer::Trace.new(kept, statement.trace.receivers), statement.seconds)
      end
      return traced if own.empty?

      Tracer::Trace.new(traced.lines.merge(file => (traced.lines.fetch(file, []) | own).sort), traced.receivers)
    end

    # [line, set id, ms, compared, wrote, reads] per statement that ran, in
    # order. Each statement's set is what it depended on, and the classes it
    # used join +owners+, the run's. A statement reads an earlier one's
    # writes when it loaded a record that one made, or counted or loaded from
    # a table that one changed or made a record in.
    def statements_of(traces, collected, owners)
      starts = (traces.keys | collected.keys).sort
      flows = starts.map { |start| (collected[start] || [nil, Collectors::Flow.blank]).last }
      starts.each_with_index.map do |start, position|
        statement = traces[start]
        window = collected[start]&.first || Collectors::NOTHING
        files, used = @inputs.reached(statement&.trace || Tracer::Trace.new({}, []), window)
        owners.merge(used)
        flow = flows[position]
        seen = flow.counted | flow.loaded.map(&:first)
        reads = (0...position).select do |earlier|
          made = flows[earlier].made
          made.intersect?(flow.loaded) || flows[earlier].changed.intersect?(seen) || made.map(&:first).to_set.intersect?(flow.counted)
        end
        [start, files.empty? ? nil : share(files), ((statement&.seconds || 0) * 1000).round, flow.compared.sort, flow.wrote.any?, reads]
      end
    end

    def relative(path)
      root = "#{File.realpath(@inputs.root)}/"
      real = File.realpath(path)
      real.delete_prefix(root) if real.start_with?(root)
    rescue SystemCallError
      nil
    end

    # Once the tracer misses code, like a file it couldn't trace, or what
    # ran around tests got lost, nothing seen after that is complete, so
    # only outcomes get recorded.
    def untraced?
      reason = Tracer.broken || @lost
      return false unless reason

      warn "[riptide] stopped recording, #{reason}" if @warned.add?(:untraced)
      Tracer.drain_load_facts
      true
    end

    # Windows nest in one thread at a time, and a test's never holds another
    # test's. Anything else runs with no window: a test records only its
    # outcome, and a class has no scope.
    def enter(test:)
      @lock.synchronize do
        return false if @testing || (@owner && @owner != Thread.current)

        @owner = Thread.current
        @depth += 1
        @testing = test
        true
      end
    end

    def leave(test:)
      @lock.synchronize do
        @testing = false if test
        @depth -= 1
        @owner = nil if @depth.zero?
      end
    end

    # Takes in what ran in the innermost scope since the last look. Code
    # can't run in an outer one while an inner one is open.
    def settle
      @scopes.last.absorb(Tracer.drain, Collectors.drain)
    rescue StandardError => e
      @lost ||= "lost what ran around tests, #{e.class}: #{e.message}"
    end

    # Nil when they can't be captured, which records only the outcome.
    def scope_sets
      @scopes.flat_map(&:sets)
    rescue StandardError => e
      warn "[riptide] couldn't record what ran around tests: #{e.class}: #{e.message}" if @warned.add?(e.class)
      nil
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

    # The test class this one got the test from, when its superclass has
    # the same method: one it defines, or includes from a module. A class
    # that defines its own doesn't.
    def inherited_from(test)
      klass = test.class
      parent = klass.superclass if klass.is_a?(Class)
      return unless parent && parent < Minitest::Test && parent.public_method_defined?(test.name)

      parent.name if parent.instance_method(test.name) == klass.instance_method(test.name)
    end

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

    # +scope+ says which setup a set came from, nil for a class a test used.
    def share(files, scope: nil)
      id = Store.set_id(files, scope)
      @store.append_set(id, files, scope: scope) if @written_sets.add?(id)
      id
    end
  end
end
