# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module Riptide
  class CollectorTest < Minitest::Test
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

    private

    def with_fixture(source)
      Dir.mktmpdir do |root|
        fixture = File.join(root, "fixture.rb")
        File.write(fixture, source)
        load fixture

        yield root
      end
    end
  end
end
