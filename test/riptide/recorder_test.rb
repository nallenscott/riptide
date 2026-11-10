# frozen_string_literal: true

require "test_helper"
require "tempfile"

module Riptide
  class RecorderTest < Minitest::Test
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

    # Loaded once, so the classes aren't redefined for every test.
    def self.fixtures
      @fixtures ||= Object.new.extend(TracedFixture).then do |loader|
        [loader.load_traced("recorder/audited.rb", CONCERN), loader.load_traced("recorder/card.rb", MODEL)]
      end
    end

    def setup
      @concern, @model = self.class.fixtures
      @dir = Dir.mktmpdir
      @store = Store.new(root: TRACE_ROOT, suite: "unit", log_dir: @dir)
      @inputs = Inputs.new(layout: Layout.new(root: TRACE_ROOT), files: Git.new(TRACE_ROOT).files)
      @recorder = Recorder.new(store: @store, inputs: @inputs, env_set: "env1")
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
      assert_equal "env1", run.sets.first
      concern = run.sets.drop(1).map { |id| logged_set(id) }.find { |files| files.key?(@concern) }
      assert_includes concern.fetch(@concern)["owners"], "RecorderCard"
      refute run.inputs.key?(@concern), "what a class's loading ran lives in its shared set, not the run"
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

    def test_a_file_git_ignores_is_never_recorded
      File.write(File.join(TRACE_ROOT, ".gitignore"), "*.key\n")
      key = File.join(TRACE_ROOT, "recorder/master.key")
      File.write(key, "SECRET")
      inputs = Inputs.new(layout: Layout.new(root: TRACE_ROOT), files: Git.new(TRACE_ROOT).files)
      recorder = Recorder.new(store: @store, inputs: inputs, env_set: "env1")
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
      recorder = Recorder.new(store: @store, inputs: inputs, env_set: "env1")
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
      recorder = Recorder.new(store: broken, inputs: @inputs, env_set: "env1")
      test = fixture_test { assert true }

      result = nil
      _, err = capture_io { result = recorder.record(test) { test.run } }

      assert result.passed?
      assert_match(/couldn't record RecorderCardTest#test_go: RuntimeError: disk full/, err)
    end
  end
end
