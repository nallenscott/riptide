# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Riptide
  class CollectorTest < Minitest::Test
    include RubyFixture

    def test_capture_records_lines_touched_within_root
      with_fixture(<<~RUBY) do |root|
        class CollectorFixtureA
          def touch_a
            1 + 1
          end

          def touch_b
            2 + 2
          end
        end
      RUBY
        result = Collector.new(root: root).capture { CollectorFixtureA.new.touch_a }

        assert_equal Set[3], result["fixture.rb"]
      end
    end

    def test_capture_excludes_lines_outside_root
      Dir.mktmpdir do |root|
        Dir.mktmpdir do |outside|
          fixture = File.join(outside, "outside_fixture.rb")
          File.write(fixture, "def collector_outside_call\n  1 + 1\nend\n")
          load fixture

          result = Collector.new(root: root).capture { collector_outside_call }

          assert_empty result
        end
      end
    end

    def test_successive_captures_do_not_leak_state_across_calls
      with_fixture(<<~RUBY) do |root|
        class CollectorFixtureB
          def a
            1
          end

          def b
            2
          end
        end
      RUBY
        collector = Collector.new(root: root)
        first = collector.capture { CollectorFixtureB.new.a }
        second = collector.capture { CollectorFixtureB.new.b }

        assert_equal Set[3], first["fixture.rb"]
        assert_equal Set[7], second["fixture.rb"]
      end
    end

    def test_start_twice_without_stop_raises
      with_fixture("class CollectorFixtureC; end\n") do |root|
        collector = Collector.new(root: root)
        collector.start

        assert_raises(RuntimeError) { collector.start }
      ensure
        collector.stop
      end
    end

    def test_stop_without_start_raises
      Dir.mktmpdir do |root|
        assert_raises(RuntimeError) { Collector.new(root: root).stop }
      end
    end

    def test_repeated_lines_within_a_loop_are_deduplicated
      with_fixture(<<~RUBY) do |root|
        class CollectorFixtureD
          def loop_body
            total = 0
            3.times { total += 1 }
            total
          end
        end
      RUBY
        result = Collector.new(root: root).capture { CollectorFixtureD.new.loop_body }

        assert_equal Set[3, 4, 5], result["fixture.rb"]
      end
    end

    # Scope classification is cached process-wide, keyed by root
    # (ext/riptide/riptide_native.c's root_scope_caches), specifically so two
    # roots active in the same process -- exactly what direct usage in this file
    # does -- can't have a file at the same relative path bleed classification or
    # touched lines from one root into the other.
    def test_the_same_relative_path_under_different_roots_is_tracked_independently
      Dir.mktmpdir do |root_a|
        Dir.mktmpdir do |root_b|
          write_fixture(root_a, "class CollectorRootFixtureA\n  def touch\n    1 + 1\n  end\nend\n")
          write_fixture(root_b, "class CollectorRootFixtureB\n  def touch\n    x = 1\n    x + 1\n  end\nend\n")

          collector_a = Collector.new(root: root_a)
          collector_b = Collector.new(root: root_b)

          result_a = collector_a.capture { CollectorRootFixtureA.new.touch }
          result_b = collector_b.capture { CollectorRootFixtureB.new.touch }

          assert_equal Set[3], result_a["fixture.rb"]
          assert_equal Set[3, 4], result_b["fixture.rb"]
        end
      end
    end

    def test_a_hook_registered_before_fork_still_reports_correctly_in_the_child
      skip "fork not supported on this platform" unless Process.respond_to?(:fork)

      with_fixture(<<~RUBY) do |root|
        class CollectorForkFixtureA
          def touch
            1 + 1
          end
        end
      RUBY
        collector = Collector.new(root: root)
        collector.start

        result_path = File.join(root, "result.marshal")
        pid = fork do
          CollectorForkFixtureA.new.touch
          result = collector.stop
          File.binwrite(result_path, Marshal.dump(result))
        end
        _, status = Process.wait2(pid)

        assert_predicate status, :success?
        result = Marshal.load(File.binread(result_path))
        assert_equal Set[3], result["fixture.rb"]
      end
    end

    def test_many_concurrent_forked_workers_each_collect_independently
      skip "fork not supported on this platform" unless Process.respond_to?(:fork)

      with_fixture(<<~RUBY) do |root|
        class CollectorForkFixtureB
          def touch_a
            1
          end

          def touch_b
            x = 2
            x + 3
          end
        end
      RUBY
        worker_count = 8

        pids = worker_count.times.map do |i|
          result_path = File.join(root, "result-#{i}.marshal")
          fork do
            result = Collector.new(root: root).capture do
              i.even? ? CollectorForkFixtureB.new.touch_a : CollectorForkFixtureB.new.touch_b
            end
            File.binwrite(result_path, Marshal.dump(result))
          end
        end
        statuses = pids.map { |pid| Process.wait2(pid).last }

        assert(statuses.all?(&:success?), "a worker failed: #{statuses.map(&:to_s)}")

        worker_count.times do |i|
          result = Marshal.load(File.binread(File.join(root, "result-#{i}.marshal")))
          expected = i.even? ? Set[3] : Set[7, 8]
          assert_equal expected, result["fixture.rb"]
        end
      end
    end
  end
end
