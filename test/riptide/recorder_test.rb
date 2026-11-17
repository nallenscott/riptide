# frozen_string_literal: true

require "test_helper"
require "tempfile"

module Riptide
  class RecorderTest < Minitest::Test
    include NeedsTracer
    include TracedFixture

    CONCERN = <<~RUBY
      module RecorderAudited
        def self.included(base)
          base.instance_variable_set(:@audited, true)
        end
      end
    RUBY

    MODEL = <<~RUBY
      class RecorderCard
        include RecorderAudited
        LIMIT = 5

        def self.prepare
          @ready = true
        end

        def go
          LIMIT
        end
      end
    RUBY

    # The process's set, whatever ran outside the tests.
    PROCESS = ->(*) { { "config/boot.rb" => { "sha" => "boot", "whole" => true } } }

    # Loaded once, so the classes aren't redefined for every test.
    def self.fixtures
      @fixtures ||= Object.new.extend(TracedFixture).then do |loader|
        [loader.load_traced("recorder/audited.rb", CONCERN), loader.load_traced("recorder/card.rb", MODEL)]
      end
    end

    def self.scoped
      @scoped ||= Object.new.extend(TracedFixture).load_traced("recorder/scoped.rb", SCOPED)
    end

    def setup
      @concern, @model = self.class.fixtures
      @dir = Dir.mktmpdir
      @store = Store.new(root: TRACE_ROOT, suite: "unit", log_dir: @dir)
      @inputs = Inputs.new(layout: Layout.new(root: TRACE_ROOT), files: Git.new(TRACE_ROOT).files)
      @recorder = Recorder.new(store: @store, inputs: @inputs, process: PROCESS)
      @recorder.absorb_load_facts
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    def fixture_test(&body)
      Class.new(Minitest::Test) do
        def self.name = "RecorderCardTest"
        def setup = RecorderCard.prepare
        define_method(:test_go, &body)
      end.new("test_go")
    end

    # What the recorder logged, newest first.
    def logged(type)
      Dir.glob(File.join(@dir, "*.jsonl")).flat_map { |path| File.readlines(path).map { |line| JSON.parse(line) } }.select { |record| record["type"] == type }
    end

    def recorded(test = %w[RecorderCardTest test_go])
      logged("run").select { |run| run["test"] == test }.reverse.map { |run| Store::Run.new(**run.except("type").transform_keys(&:to_sym)) }
    end

    def logged_set(id) = logged("set").find { |set| set["id"] == id }&.fetch("files")

    def test_a_run_covers_setup_the_test_and_what_it_used
      test = fixture_test { assert_equal 5, RecorderCard.new.go }
      @recorder.record(test) { test.run }

      run = recorded.first
      card = run.inputs.fetch(@model)
      assert_equal %w[RecorderCard#go RecorderCard.prepare], card["methods"].sort
      assert_includes card["constants"], "RecorderCard::LIMIT"
      assert run.passed
      assert_equal Store.set_id(PROCESS.call, "process"), run.sets.first
      concern = run.sets.drop(1).map { |id| logged_set(id) }.find { |files| files.key?(@concern) }
      assert_includes concern.fetch(@concern)["owners"], "RecorderCard"
      refute run.inputs.key?(@concern), "what a class's loading ran lives in its shared set, not the run"
    end

    FLOW = <<~RUBY
      RecorderShop = Struct.new(:id) do
        def self.table_name = "shops"
      end

      class RecorderFlowTest < Minitest::Test
        def test_flow
          Riptide::Collectors.creating { Riptide::Collectors.flowed(%(INSERT INTO "shops" ("name") VALUES ('a'))).then { Riptide::Collectors.made(RecorderShop.new(1)) } }
          Riptide::Collectors.flowed(%(UPDATE "orders" SET "paid" = TRUE))
          Riptide::Collectors.flowed(%(SELECT COUNT(*) FROM "orders"))
          Riptide::Collectors.flowed(%(SELECT "shops".* FROM "shops" WHERE "id" = 1)).then { Riptide::Collectors.loaded(RecorderShop.new(1)) }
          Riptide::Collectors.flowed(%(SELECT "shops".* FROM "shops" WHERE "id" = 9)).then { Riptide::Collectors.loaded(RecorderShop.new(9)) }
        end
      end
    RUBY

    def test_a_statement_reads_the_writes_of_the_ones_whose_records_or_tables_it_used
      load_traced("recorder/flow_test.rb", FLOW) unless defined?(RecorderFlowTest)
      test = RecorderFlowTest.new("test_flow")
      @recorder.record(test) { test.run }

      body = recorded(%w[RecorderFlowTest test_flow]).first.body
      assert_equal [7, 8, 9, 10, 11], body.map(&:first)
      assert_equal [true, true, false, false, false], body.map { _1[4] }
      assert_equal [[], [], [1], [0], []], body.map(&:last),
                   "a count reads the update before it, a load reads the record made before it, and a load of a record nobody made reads nothing"
    end

    # A file that loaded mid-test and couldn't be traced leaves every run
    # after it missing what that file ran.
    def test_once_the_tracer_misses_code_only_outcomes_are_recorded
      test = fixture_test do
        Tracer.instance_variable_set(:@broken, "couldn't trace app/late.rb: boom")
        assert_equal 5, RecorderCard.new.go
      end
      _, warnings = capture_io do
        @recorder.record(test) { test.run }
        @recorder.record(test) { test.run }
      end

      assert_equal [true, true], recorded.map(&:passed)
      assert_equal [nil, nil], recorded.map(&:inputs)
      assert_equal "[riptide] stopped recording, couldn't trace app/late.rb: boom\n", warnings
    ensure
      Tracer.instance_variable_set(:@broken, nil)
    end

    def test_a_failing_test_is_recorded_as_failed
      test = fixture_test { flunk "nope" }
      result = @recorder.record(test) { test.run }

      refute result.passed?
      refute recorded.first.passed
    end

    def test_a_skipped_test_records_no_outcome
      test = fixture_test { skip "later" }
      @recorder.record(test) { test.run }

      assert_equal [[nil, nil]], recorded.map { |run| [run.passed, run.inputs] }
      assert_equal [%w[RecorderCardTest test_go]], logged("start").map { |start| start["test"] }
    end

    # The method comes from somewhere else, like shoulda's generated tests,
    # and the class's file is what counts.
    def test_a_pass_records_the_file_that_defines_the_test_s_class
      path = Object.new.extend(TracedFixture).load_traced("recorder/defined_test.rb", "class RecorderDefinedTest < Minitest::Test\nend\n")
      Tempfile.create(["gem", ".rb"]) do |gem|
        RecorderDefinedTest.class_eval("def test_generated = assert(true)", gem.path, 1)
        test = RecorderDefinedTest.new("test_generated")
        @recorder.record(test) { test.run }

        assert_equal path, recorded(%w[RecorderDefinedTest test_generated]).first.file
      end
    end

    def test_a_test_class_outside_the_app_has_no_file
      test = fixture_test { assert true }
      @recorder.record(test) { test.run }

      assert_nil recorded.first.file, "an anonymous class has no file"
    end

    def test_a_test_running_alongside_another_thread_records_only_its_outcome
      outer = fixture_test { assert true }
      inner = Class.new(Minitest::Test) do
        def self.name = "RecorderInnerTest"
        define_method(:test_inner) { assert true }
      end.new("test_inner")
      inner_result = nil
      @recorder.record(outer) do
        Thread.new { inner_result = @recorder.record(inner) { inner.run } }.join
        outer.run
      end

      assert inner_result.passed?
      assert_equal [[true, nil]], recorded(%w[RecorderInnerTest test_inner]).map { |run| [run.passed, run.inputs] }, "only its outcome"
      refute_nil recorded.first.inputs
    end

    SCOPED = <<~RUBY
      module RecorderScoped
        def self.worker = :worker
        def self.entry = :entry
        def self.before = :before
        def self.during = :during
        def self.after = :after
      end

      class RecorderScopedThing
        def ping = :ping
      end

      class RecorderScopedOther < RecorderScopedThing
      end
    RUBY

    # A test class that sets up around its tests the ways suites do: an
    # override of how Minitest runs the class, and a before_all and
    # after_all around with_info_handler, the way minitest-hooks does it.
    def scoped_class
      entry = Minitest::Runnable.respond_to?(:run_suite) ? :run_suite : :run
      Class.new(Minitest::Test) do
        def self.name = "RecorderScopedTest"
        def self.runnable_methods = %w[test_a test_b]
        define_singleton_method(entry) do |*args, **options, &block|
          RecorderScoped.entry
          super(*args, **options, &block)
        end
        def self.with_info_handler(*)
          RecorderScoped.before
          super.tap { RecorderScoped.after }
        end
        def test_a = Dir.glob("recorder/*.rb", base: TRACE_ROOT).then { RecorderScoped.during }
        def test_b = RecorderScoped.during
      end
    end

    def plain_class
      Class.new(Minitest::Test) do
        def self.name = "RecorderPlainTest"
        def test_c = RecorderScoped.during
      end
    end

    # Every method a run depends on, across its own inputs and its sets.
    def methods_of(test)
      run = recorded(test).first
      [run.inputs, *run.sets.map { |id| logged_set(id) }].compact.flat_map { |files| files.values.flat_map { |facets| facets["methods"] || [] } }
    end

    def scoped_recorder
      self.class.scoped
      Collectors.install(TRACE_ROOT)
      inputs = Inputs.new(layout: Layout.new(root: TRACE_ROOT), files: Git.new(TRACE_ROOT).files)
      Recorder.new(store: @store, inputs: inputs, process: ->(trace, window) { inputs.for_process(trace.lines, window.tables) })
    end

    def installed(recorder)
      Recorder.install(recorder)
      yield
    ensure
      Recorder.instance_variable_set(:@current, nil)
    end

    def run_class(klass)
      reporter = Minitest::CompositeReporter.new(Minitest::StatisticsReporter.new(StringIO.new))
      Minitest::Runnable.respond_to?(:run_suite) ? klass.run_suite(reporter, {}) : klass.run(reporter, {})
    end

    def test_a_test_depends_on_its_class_setup_and_not_its_teardown
      recorder = scoped_recorder
      scoped = scoped_class
      plain = plain_class
      installed(recorder) do
        run_class(scoped)
        run_class(plain)
      end

      %w[test_a test_b].each do |name|
        methods = methods_of(["RecorderScopedTest", name])
        assert_includes methods, "RecorderScoped.entry", "setup in the class's own run counts for #{name}"
        assert_includes methods, "RecorderScoped.before", "a before_all counts for #{name}"
        assert_includes methods, "RecorderScoped.during"
        refute_includes methods, "RecorderScoped.after", "an after_all runs after every test"
      end
      class_set = recorded(%w[RecorderScopedTest test_a]).first.sets.map { |id| logged_set(id) }.find { |files| files.dig("recorder/scoped.rb", "methods")&.include?("RecorderScoped.entry") }
      assert_includes class_set.dig("recorder/scoped.rb", "methods"), "RecorderScoped.before", "one scope for the class, however many of its hooks it went through"
      scopes = recorded(%w[RecorderScopedTest test_a]).first.sets.map { |id| logged("set").find { |set| set["id"] == id }["scope"] }
      assert_equal "process", scopes.first
      assert_includes scopes.drop(1), "class"
      refute recorded(%w[RecorderPlainTest test_c]).first.sets.drop(1).map { |id| logged_set(id) }.any?(&:empty?), "a class that set nothing up adds no set"
      later = methods_of(%w[RecorderPlainTest test_c])
      assert_includes later, "RecorderScoped.during"
      refute_includes later, "RecorderScoped.entry", "another class's setup isn't this one's"
      refute_includes later, "RecorderScoped.before", "another class's before_all isn't this one's"
      assert recorded(%w[RecorderScopedTest test_a]).first.inputs.key?("glob:recorder/*.rb")
      sets = recorded(%w[RecorderScopedTest test_b]).first.sets.map { |id| logged_set(id) }
      refute sets.any? { |files| files.key?("glob:recorder/*.rb") }, "riptide listing the glob to record test_a isn't the class's"
    end

    # The way a Rails parallel worker runs each test it's given. Its
    # parallelize_setup runs outside any class, before the jobs.
    def test_worker_jobs_get_their_class_scope_and_setup_that_ran_before_them
      recorder = scoped_recorder
      job = ->(klass, name) { klass.with_info_handler(nil) { Minitest.respond_to?(:run_one_method) ? Minitest.run_one_method(klass, name) : klass.new(name).run } }
      scoped = scoped_class
      plain = plain_class
      installed(recorder) do
        job.call(scoped, "test_a")
        RecorderScoped.worker
        job.call(scoped, "test_b")
        job.call(plain, "test_c")
      end

      first = methods_of(%w[RecorderScopedTest test_a])
      refute_includes first, "RecorderScoped.worker", "it ran after test_a"
      assert_includes methods_of(%w[RecorderScopedTest test_b]), "RecorderScoped.worker", "code outside every class counts for later tests"
      assert_includes first, "RecorderScoped.before"
      refute_includes first, "RecorderScoped.entry", "the job never ran the class's own run"
      refute_includes methods_of(%w[RecorderPlainTest test_c]), "RecorderScoped.before", "another class's job isn't this one's"
    end

    # Runs test_a and test_b in one class scope, with +between+ in between,
    # and returns the sets each one got.
    def sets_around(recorder)
      klass = scoped_class
      first = klass.new("test_a")
      second = klass.new("test_b")
      recorder.scope(klass) do
        RecorderScopedThing.new.ping
        recorder.record(first) { first.run }
        yield
        recorder.record(second) { second.run }
      end
      %w[test_a test_b].map { |name| recorded(["RecorderScopedTest", name]).first.sets.map { |id| logged_set(id) } }
    end

    def test_a_file_read_between_tests_counts_for_the_next_one
      data = File.join(TRACE_ROOT, "recorder/scoped.yml")
      File.write(data, "a: 1")
      before, after = sets_around(scoped_recorder) { File.read(data) }

      refute before.any? { |files| files.key?("recorder/scoped.yml") }
      assert after.any? { |files| files.dig("recorder/scoped.yml", "whole") }
    end

    # The same line on another receiver runs nothing new, but its class's
    # set comes with it.
    def test_a_receiver_between_tests_counts_for_the_next_one
      before, after = sets_around(scoped_recorder) { RecorderScopedOther.new.ping }

      assert_equal before.size + 1, after.size
    end

    def test_a_class_scope_doesnt_open_inside_a_test
      recorder = scoped_recorder
      klass = scoped_class
      test = fixture_test { klass.with_info_handler(nil) { RecorderScoped.during } }
      installed(recorder) { recorder.record(test) { test.run } }

      assert_includes methods_of(%w[RecorderCardTest test_go]), "RecorderScoped.before", "it's the test's own code"
    end

    def test_a_file_git_ignores_is_never_recorded
      File.write(File.join(TRACE_ROOT, ".gitignore"), "*.key\n")
      key = File.join(TRACE_ROOT, "recorder/master.key")
      File.write(key, "SECRET")
      inputs = Inputs.new(layout: Layout.new(root: TRACE_ROOT), files: Git.new(TRACE_ROOT).files)
      recorder = Recorder.new(store: @store, inputs: inputs, process: PROCESS)
      test = fixture_test { File.read(key) }
      recorder.record(test) { test.run }

      refute recorded.first.inputs.key?("recorder/master.key")
      assert recorded.first.inputs.key?(@model)
    ensure
      File.delete(File.join(TRACE_ROOT, ".gitignore"))
    end

    def test_a_file_edited_after_it_loaded_leaves_the_test_unrecorded
      path = Object.new.extend(TracedFixture).load_traced("recorder/stale.rb", "class RecorderStale\n  def self.go = 1\nend\n")
      Tracer.drain_load_facts
      File.write(File.join(TRACE_ROOT, path), "class RecorderStale\n  def self.go = 22\nend\n")
      inputs = Inputs.new(layout: Layout.new(root: TRACE_ROOT), files: Git.new(TRACE_ROOT).files)
      recorder = Recorder.new(store: @store, inputs: inputs, process: PROCESS)
      test = fixture_test { RecorderStale.go }

      _, err = capture_io { recorder.record(test) { test.run } }

      assert_nil recorded.first.inputs, "only its outcome"
      assert_match(/recorder\/stale.rb changed after it loaded/, err)
    end

    def test_a_recording_failure_leaves_the_result_alone
      broken = Object.new
      def broken.append_run(*) = raise("disk full")
      def broken.append_load_facts(*) = nil
      def broken.append_set(*) = nil
      recorder = Recorder.new(store: broken, inputs: @inputs, process: PROCESS)
      test = fixture_test { assert true }

      result = nil
      _, err = capture_io { result = recorder.record(test) { test.run } }

      assert result.passed?
      assert_match(/couldn't record RecorderCardTest#test_go: RuntimeError: disk full/, err)
    end
  end
end
