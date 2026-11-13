# frozen_string_literal: true

require "test_helper"

module Riptide
  class TracerTest < Minitest::Test
    include NeedsTracer
    include TracedFixture

    def setup
      Tracer.drain_load_facts
      Tracer.drain
    end

    def test_a_window_records_lines_run_under_the_root
      path = load_traced("window/adder.rb", <<~RUBY)
        module TracerAdder
          def self.add(a, b)
            sum = a + b
            sum
          end
        end
      RUBY

      lines = traced { TracerAdder.add(1, 2) }

      assert_equal [2, 3, 4], lines.fetch(path), "the def line is the method being called"
    end

    # Ruby has nothing to hook in a file with no code, like an initializer
    # that's all comments, and loading it must still work.
    def test_a_file_with_no_code_loads
      load_traced("empty/comments.rb", "# nothing to run here\n")

      assert_nil Tracer.broken
    end

    def test_a_window_ignores_code_outside_the_root
      inside = load_traced("window/inside.rb", "module TracerInside\n  def self.go = :in\nend\n")
      Dir.mktmpdir do |outside|
        File.write(File.join(outside, "outside.rb"), "module TracerOutside\n  def self.go\n    :out\n  end\nend\n")
        load File.join(outside, "outside.rb")

        lines = traced { [TracerInside.go, TracerOutside.go] }

        assert_equal [inside], lines.keys
      end
    end

    def test_lines_run_while_a_class_loads_are_load_facts_for_that_class
      path = load_traced("loading/widget.rb", <<~RUBY)
        class TracerWidget
          LIMIT = 5
          def limit = LIMIT
        end
      RUBY

      statement = { "owners" => ["TracerWidget"], "called" => false }
      assert_equal({ 2 => statement, 3 => statement }, Tracer.drain_load_facts.fetch(path))
    end

    def test_a_block_run_from_a_class_body_is_called_code_and_a_lambda_left_uncalled_is_not
      path = load_traced("loading/blocks.rb", <<~RUBY)
        class TracerBlocks
          LATER = -> { :later }
          [1].each { |n| @seen = n }
        end
      RUBY

      facts = Tracer.drain_load_facts.fetch(path)
      assert_equal false, facts.fetch(2)["called"]
      assert_equal true, facts.fetch(3)["called"]
    end

    def test_a_concern_included_block_belongs_to_the_including_class
      concern = load_traced("loading/concern.rb", <<~RUBY)
        module TracerConcern
          def self.included(base)
            base.instance_variable_set(:@included, true)
          end
        end
      RUBY
      Tracer.drain_load_facts
      load_traced("loading/model.rb", <<~RUBY)
        class TracerModel
          include TracerConcern
        end
      RUBY

      assert_equal({ "owners" => ["TracerModel"], "called" => true }, Tracer.drain_load_facts.fetch(concern).fetch(3))
      assert_includes Tracer.files_for(TracerModel), concern
    end

    def test_a_macro_called_from_a_class_body_belongs_to_the_class
      macros = load_traced("loading/macros.rb", <<~RUBY)
        module TracerMacros
          def has_flag(name)
            define_method(name) { true }
          end
        end
      RUBY
      Tracer.drain_load_facts
      load_traced("loading/flagged.rb", <<~RUBY)
        class TracerFlagged
          extend TracerMacros
          has_flag :ready
        end
      RUBY

      assert_equal({ "owners" => ["TracerFlagged"], "called" => true }, Tracer.drain_load_facts.fetch(macros).fetch(3))
    end

    def test_code_called_after_loading_goes_to_the_window_not_load_facts
      path = load_traced("loading/later.rb", <<~RUBY)
        class TracerLater
          def go
            :went
          end
        end
      RUBY
      Tracer.drain_load_facts

      lines = traced { TracerLater.new.go }

      assert_equal [2, 3], lines.fetch(path)
      assert_empty Tracer.drain_load_facts
    end

    def test_a_singleton_class_body_belongs_to_its_class
      path = load_traced("loading/singleton.rb", <<~RUBY)
        class TracerSingleton
          class << self
            attr_accessor :setting
          end
        end
      RUBY

      assert_equal({ "owners" => ["TracerSingleton"], "called" => false }, Tracer.drain_load_facts.fetch(path).fetch(3))
    end

    def test_a_class_body_that_raises_stops_loading_once_the_error_is_rescued
      assert_raises(RuntimeError) do
        load_traced("loading/broken.rb", <<~RUBY)
          class TracerBroken
            raise "boom"
          end
        RUBY
      end
      Tracer.drain_load_facts
      path = load_traced("loading/after_broken.rb", "TRACER_AFTER_BROKEN = 1\n")

      refute Tracer.drain_load_facts.key?(path)
      assert_equal [1], Tracer.drain.lines.fetch(path)
    end

    def test_an_error_rescued_inside_a_class_body_keeps_it_loading
      path = load_traced("loading/rescuing.rb", <<~RUBY)
        class TracerRescuing
          begin
            raise "boom"
          rescue RuntimeError
            nil
          end
          AFTER = 1
        end
      RUBY

      assert_equal ["TracerRescuing"], Tracer.drain_load_facts.fetch(path).fetch(7)["owners"]
    end

    def test_a_raising_class_body_nested_in_another_unwinds_only_itself
      path = load_traced("loading/nested_raise.rb", <<~RUBY)
        class TracerOuter
          begin
            class Inner
              raise "boom"
            end
          rescue RuntimeError
            nil
          end
          AFTER = 1
        end
      RUBY

      assert_equal ["TracerOuter"], Tracer.drain_load_facts.fetch(path).fetch(9)["owners"]
    end

    # A throw leaves a class body with no end and no rescue to say so,
    # whether what runs next sits shallower than the body did or deeper.
    def test_a_class_body_thrown_out_of_stops_loading
      shallow = load_traced("loading/thrown.rb", <<~RUBY)
        catch(:tracer_out) do
          class TracerThrown
            throw :tracer_out
          end
        end
        TRACER_AFTER_THROWN = 1
      RUBY
      catch(:tracer_out) do
        load_traced("loading/thrown_again.rb", <<~RUBY)
          class TracerThrownAgain
            throw :tracer_out
          end
        RUBY
      end
      deep = 1.then { 1.then { 1.then { load_traced("loading/after_deep.rb", "TRACER_AFTER_DEEP = 1\n") } } }

      facts = Tracer.drain_load_facts
      lines = Tracer.drain.lines
      refute facts.fetch(shallow).key?(6), "after the body, shallower"
      assert_includes lines.fetch(shallow), 6
      refute facts.key?(deep), "after the body, deeper"
      assert_equal [1], lines.fetch(deep)
    end

    # A thread that dies from an error is cleaned up without a rescue, so
    # the class bodies it was in never say they're done.
    def test_a_thread_that_dies_inside_a_class_body_stops_loading
      helper = load_traced("dead/helper.rb", <<~RUBY)
        module TracerDeadHelper
          def self.setting
            value = :on
            value
          end
        end
      RUBY
      Thread.new do
        Thread.current.report_on_exception = false
        load_traced("dead/broken.rb", <<~RUBY)
          class TracerDeadBroken
            raise "boom"
          end
        RUBY
      end.join rescue RuntimeError
      Tracer.drain_load_facts

      Tracer.open_window
      TracerDeadHelper.setting
      load_traced("dead/user.rb", <<~RUBY)
        class TracerDeadUser
          SETTING = TracerDeadHelper.setting
        end
      RUBY
      Tracer.close_window

      assert_equal [2, 3, 4], Tracer.drain_load_facts.fetch(helper).keys.sort, "lines the window turned off come back for the class body"
    end

    # A class body can't see locals, so the loader reaches its queues
    # through constants.
    TracerGate = Queue.new
    TracerRelease = Queue.new

    def test_another_thread_is_not_treated_as_loading
      path = load_traced("threads/worker.rb", <<~RUBY)
        module TracerWorker
          def self.work
            :worked
          end
        end
      RUBY
      Tracer.drain_load_facts
      loader = Thread.new do
        Class.new do
          class << self
            TracerTest::TracerGate.push(:loading)
            TracerTest::TracerRelease.pop
          end
        end
      end
      TracerGate.pop

      lines = traced { Thread.new { TracerWorker.work }.join }
      TracerRelease.push(:go)
      loader.join

      assert_equal [2, 3], lines.fetch(path)
    end

    def test_code_outside_every_window_goes_to_the_processs
      path = load_traced("boot/setup.rb", "TRACER_BOOT_SETTING = :on\n")

      assert_equal [1], Tracer.drain.lines.fetch(path)
    end

    def test_every_window_hears_a_line_however_often_the_last_one_ran_it
      path = load_traced("repeat/counter.rb", <<~RUBY)
        module TracerCounter
          def self.count(n)
            total = 0
            n.times { |i| total += i }
            total
          end
        end
      RUBY

      first = traced { TracerCounter.count(500) }
      second = traced { TracerCounter.count(3) }

      assert_equal [2, 3, 4, 5], first.fetch(path)
      assert_equal [2, 3, 4, 5], second.fetch(path)
    end

    def test_a_branch_a_window_skips_is_left_out
      path = load_traced("repeat/branch.rb", <<~RUBY)
        module TracerBranch
          def self.pick(n)
            if n.even?
              :even
            else
              :odd
            end
          end
        end
      RUBY

      assert_equal [2, 3, 4], traced { TracerBranch.pick(2) }.fetch(path)
      assert_equal [2, 3, 6], traced { TracerBranch.pick(3) }.fetch(path)
    end

    def test_code_a_window_ran_is_a_load_fact_when_a_class_body_runs_it_again
      helper = load_traced("repeat/helper.rb", <<~RUBY)
        module TracerSharedHelper
          def self.setting
            value = :on
            value
          end
        end
      RUBY
      Tracer.drain_load_facts

      Tracer.open_window
      TracerSharedHelper.setting
      load_traced("repeat/user.rb", <<~RUBY)
        class TracerHelperUser
          SETTING = TracerSharedHelper.setting
        end
      RUBY
      lines = Tracer.close_window.lines

      assert_equal [2, 3, 4], lines.fetch(helper)
      assert_equal({ "owners" => ["TracerHelperUser"], "called" => true }, Tracer.drain_load_facts.fetch(helper).fetch(4))
    end

    def test_a_line_tracepoint_still_hears_lines_the_tracer_turned_off
      path = load_traced("repeat/watched.rb", <<~RUBY)
        module TracerWatched
          def self.go
            value = :went
            value
          end
        end
      RUBY
      Tracer.open_window
      TracerWatched.go
      heard = []
      watcher = TracePoint.new(:line) { |tp| heard << tp.lineno if tp.path.end_with?(path) }
      watcher.enable { 2.times { TracerWatched.go } }
      lines = Tracer.close_window.lines

      assert_equal [3, 4, 3, 4], heard
      assert_equal [2, 3, 4], lines.fetch(path)
      assert_equal [2, 3, 4], traced { TracerWatched.go }.fetch(path)
    end

    # The VM's own trace hooks only show what YJIT would skip in a process
    # where YJIT compiles everything it can, from the first call.
    def test_yjit_compiling_the_callers_never_hides_a_line
      skip "this Ruby has no YJIT" unless defined?(RubyVM::YJIT)

      result = in_yjit(<<~RUBY)
        File.write("\#{root}/hot.rb", <<~APP)
          module Hot
            def self.pick(n)
              if n.even?
                :even
              else
                :odd
              end
            end
          end
        APP
        load "\#{root}/hot.rb"
        windows = [0, 1, 0, 1].map do |odd|
          Riptide::Tracer.open_window
          200.times { |n| Hot.pick(n * 2 + odd) }
          Riptide::Tracer.close_window.lines.fetch("hot.rb")
        end
        { windows: windows, compiled: RubyVM::YJIT.runtime_stats[:compiled_iseq_count] }
      RUBY

      assert_equal [[2, 3, 4], [2, 3, 6], [2, 3, 4], [2, 3, 6]], result[:windows]
      assert_operator result[:compiled], :>, 0, "YJIT compiled the callers"
    end

    def test_loading_app_files_leaves_yjit_s_compiled_code_alone
      skip "this Ruby has no YJIT" unless defined?(RubyVM::YJIT)

      result = in_yjit(<<~RUBY)
        3.times { |i| File.write("\#{root}/warm_\#{i}.rb", "module Warm\#{i}; def self.go = \#{i}; end\\n") }
        before = RubyVM::YJIT.runtime_stats[:invalidation_count]
        3.times { |i| load "\#{root}/warm_\#{i}.rb" }
        { invalidations: RubyVM::YJIT.runtime_stats[:invalidation_count] - before }
      RUBY

      assert_equal 0, result[:invalidations]
    end

    def test_line_coverage_counts_every_run_alongside_the_tracer
      result = in_subprocess(<<~RUBY)
        require "coverage"
        Coverage.start(lines: true)
        File.write("\#{root}/covered.rb", "module Covered\\n  def self.go\\n    :went\\n  end\\nend\\n")
        load "\#{root}/covered.rb"
        windows = 2.times.map do
          Riptide::Tracer.open_window
          3.times { Covered.go }
          Riptide::Tracer.close_window.lines.fetch("covered.rb")
        end
        { windows: windows, coverage: Coverage.result.fetch("\#{root}/covered.rb")[:lines] }
      RUBY

      assert_equal [[2, 3], [2, 3]], result[:windows]
      assert_equal [1, 1, 6, nil, nil], result[:coverage]
    end

    def test_code_eval_d_before_line_one_records_only_the_lines_in_the_file
      lines = in_subprocess(<<~RUBY)
        Riptide::Tracer.open_window
        eval("a = 1\\nb = 2\\nc = 3\\n", binding, "\#{root}/eval.rb", -1)
        Riptide::Tracer.close_window.lines
      RUBY

      assert_equal({ "eval.rb" => [1] }, lines)
    end

    def test_oneshot_coverage_started_before_riptide_turns_it_off
      broken = in_subprocess(<<~RUBY)
        require "coverage"
        Coverage.start(oneshot_lines: true)
        File.write("\#{root}/early.rb", "module Early\\nend\\n")
        load "\#{root}/early.rb"
        Riptide::Tracer.watch_coverage
        Riptide::Tracer.broken
      RUBY

      assert_equal "oneshot line coverage is on, and it turns off riptide's line tracing", broken
    end

    def test_oneshot_coverage_started_after_riptide_turns_it_off
      broken = in_subprocess(<<~RUBY)
        require "coverage"
        Riptide::Tracer.watch_coverage
        Coverage.setup(oneshot_lines: true)
        Riptide::Tracer.broken
      RUBY

      assert_equal "oneshot line coverage is on, and it turns off riptide's line tracing", broken
    end

    def test_line_coverage_leaves_riptide_on
      broken = in_subprocess(<<~RUBY)
        require "coverage"
        Coverage.start(lines: true)
        File.write("\#{root}/early.rb", "module Early\\nend\\n")
        load "\#{root}/early.rb"
        Riptide::Tracer.watch_coverage
        Coverage.result
        Coverage.start(:all)
        Riptide::Tracer.broken
      RUBY

      assert_nil broken
    end

    def test_a_forked_child_keeps_its_window
      path = load_traced("fork/work.rb", <<~RUBY)
        module TracerForkWork
          def self.go
            :went
          end
        end
      RUBY
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        writer.write(Marshal.dump(traced { TracerForkWork.go }))
        exit!(0)
      end
      writer.close
      lines = Marshal.load(reader.read)
      Process.wait(pid)

      assert_equal [2, 3], lines.fetch(path)
    end

    # A method's first line shares its entry and never turns off, so each
    # has a second line that does.
    NESTED = <<~RUBY
      class TracerNested
        def outer
          a = 1
          a + 1
        end

        def inner
          b = 2
          b + 2
        end

        def after
          c = 3
          c + 3
        end
      end
    RUBY

    # Lines stop turning off in a process that ever had a global line
    # TracePoint, so these run where none ever did.
    def test_windows_nest_and_each_keeps_what_ran_while_it_was_innermost
      result = in_subprocess(<<~RUBY)
        File.write("\#{root}/nested.rb", #{NESTED.dump})
        load "\#{root}/nested.rb"
        nested = TracerNested.new
        Riptide::Tracer.drain
        Riptide::Tracer.open_window
        nested.outer
        Riptide::Tracer.open_window
        nested.inner
        inner = Riptide::Tracer.close_window
        nested.after
        outer = Riptide::Tracer.close_window
        nested.after
        process = Riptide::Tracer.drain
        [inner, outer, process].map { |trace| [trace.lines["nested.rb"], trace.receivers.map(&:name)] }
      RUBY
      inner, outer, process = result

      assert_equal [[7, 8, 9], ["TracerNested"]], inner
      assert_equal [[2, 3, 4, 12, 13, 14], ["TracerNested"]], outer, "a line the inner window ran isn't the outer one's"
      assert_equal [[12, 13, 14], []], process, "a line comes back for the process once a window closes, and it keeps no receivers"
    end

    def test_a_window_hears_a_line_the_window_around_it_just_ran
      lines = in_subprocess(<<~RUBY)
        File.write("\#{root}/around.rb", #{NESTED.dump})
        load "\#{root}/around.rb"
        around = TracerNested.new
        around.outer
        Riptide::Tracer.drain
        Riptide::Tracer.open_window
        around.outer
        Riptide::Tracer.close_window.lines["around.rb"]
      RUBY

      assert_equal [2, 3, 4], lines
    end

    def test_draining_leaves_the_window_open
      load_traced("window/drained.rb", NESTED.gsub("TracerNested", "TracerDrained"))
      drained = TracerDrained.new
      Tracer.open_window
      drained.outer
      first = Tracer.drain
      drained.inner

      assert_equal [2, 3, 4], first.lines.fetch("window/drained.rb")
      assert_equal [7, 8, 9], Tracer.close_window.lines.fetch("window/drained.rb")
    end

    def test_closing_without_a_window_raises
      assert_raises(RuntimeError) { Tracer.close_window }
    end

    private

    # Runs +body+ in a fresh Ruby with the tracer rooted at an empty `root`,
    # and returns what the body returns.
    def in_subprocess(body, *flags)
      script = <<~RUBY
        $LOAD_PATH.unshift(#{File.expand_path("../../lib", __dir__).dump})
        require "riptide/tracer"
        require "tmpdir"
        root = File.realpath(Dir.mktmpdir)
        Riptide::Tracer.install(root)
        result = begin
        #{body}
        end
        STDOUT.write(Marshal.dump(result))
      RUBY
      # A tracer that corrupts memory can hang instead of crashing.
      output = IO.popen([RbConfig.ruby, *flags, "-e", script]) do |io|
        Process.kill("KILL", io.pid) unless io.wait_readable(60)
        io.read
      end
      assert $?.success?, "the subprocess failed"
      Marshal.load(output)
    end

    def in_yjit(body)
      in_subprocess(body, "--yjit", "--yjit-call-threshold=1")
    end
  end
end
