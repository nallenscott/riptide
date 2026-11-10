# frozen_string_literal: true

require "test_helper"

module Riptide
  class TracerTest < Minitest::Test
    include TracedFixture

    def setup
      Tracer.drain_load_facts
      Tracer.drain_boot_lines
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
      lines = traced { [3, 1, 2].sort }

      assert_empty lines
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
      assert_equal({ 1 => true }, Tracer.drain_boot_lines.fetch(path))
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

    def test_top_level_code_outside_a_window_is_boot_lines
      path = load_traced("boot/setup.rb", "TRACER_BOOT_SETTING = :on\n")

      assert_equal({ 1 => true }, Tracer.drain_boot_lines.fetch(path))
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

    def test_opening_a_window_twice_raises
      Tracer.open_window
      assert_raises(RuntimeError) { Tracer.open_window }
    ensure
      Tracer.close_window
    end

    def test_closing_without_a_window_raises
      assert_raises(RuntimeError) { Tracer.close_window }
    end
  end
end
