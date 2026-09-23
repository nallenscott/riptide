# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Riptide
  class Collector
    class MinitestHooksTest < Minitest::Test
      include GitFixture
      include RubyFixture

      def teardown
        MinitestHooks.root = nil
        MinitestHooks.on_capture = nil
      end

      def test_wire_persists_coverage_with_the_files_current_blob_sha
        in_repo do |root|
          write_and_commit(root, "app/models/widget.rb", "class Widget\nend\n", message: "base")
          store = Store.new(path: ":memory:")

          MinitestHooks.wire(store: store, root: root)
          MinitestHooks.on_capture.call("WidgetTest", "test_a", { "app/models/widget.rb" => Set[1] })

          deps = store.dependencies_for_file("app/models/widget.rb")

          assert_equal 1, deps.size
          assert_equal Diff.blob_sha(File.join(root, "app/models/widget.rb")), deps.first[:source_blob_sha]
        end
      end

      # Collector's relative-path keys come from the native extension (C
      # string slicing), not a Ruby String method, and previously came out
      # ASCII-8BIT: byte-identical to an ordinary Ruby string but a
      # different SQLite storage class (BLOB, not TEXT), which SQLite never
      # considers equal to TEXT even for identical bytes. That silently
      # broke the UNIQUE(test_id, source_file) upsert (a second capture of
      # the same file produced a second row instead of updating the first)
      # and broke every later `dependencies_for_file` lookup, permanently,
      # since those pass an ordinary Ruby string. Recording twice for the
      # same real Collector-produced key and asserting exactly one row
      # catches a regression at the actual boundary where it broke, not
      # just a Ruby-level String#encoding check.
      def test_recording_the_same_real_collector_key_twice_updates_one_row_not_two
        with_fixture(<<~RUBY) do |root|
          class MinitestHooksEncodingFixture
            def touch
              1 + 1
            end
          end
        RUBY
          store = Store.new(path: ":memory:")
          MinitestHooks.wire(store: store, root: root)

          coverage = Collector.new(root: root).capture { MinitestHooksEncodingFixture.new.touch }
          MinitestHooks.on_capture.call("WidgetTest", "test_a", coverage)
          MinitestHooks.on_capture.call("WidgetTest", "test_a", coverage)

          deps = store.dependencies_for_file(coverage.keys.first)

          assert_equal 1, deps.size
        end
      end

      def test_wire_hashes_a_shared_file_only_once_across_multiple_tests
        in_repo do |root|
          write_and_commit(root, "test/test_helper.rb", "require 'minitest/autorun'\n", message: "base")
          store = Store.new(path: ":memory:")

          call_count = 0
          Diff.stub(:blob_sha, ->(_path) { call_count += 1; "stub-sha" }) do
            MinitestHooks.wire(store: store, root: root)
            MinitestHooks.on_capture.call("ATest", "test_a", { "test/test_helper.rb" => Set[1] })
            MinitestHooks.on_capture.call("BTest", "test_b", { "test/test_helper.rb" => Set[2] })
          end

          assert_equal 1, call_count
        end
      end

      def test_wire_skips_recording_when_should_record_returns_false
        in_repo do |root|
          write_and_commit(root, "app/models/widget.rb", "class Widget\nend\n", message: "base")
          store = Store.new(path: ":memory:")

          MinitestHooks.wire(store: store, root: root, should_record: ->(_class_name, _method_name) { false })
          MinitestHooks.on_capture.call("WidgetTest", "test_a", { "app/models/widget.rb" => Set[1] })

          assert_empty store.dependencies_for_file("app/models/widget.rb")
        end
      end

      def test_wire_records_only_the_tests_should_record_allows
        in_repo do |root|
          write_and_commit(root, "app/models/widget.rb", "class Widget\nend\n", message: "base")
          store = Store.new(path: ":memory:")

          MinitestHooks.wire(store: store, root: root, should_record: ->(class_name, _method_name) { class_name == "WidgetTest" })
          MinitestHooks.on_capture.call("WidgetTest", "test_a", { "app/models/widget.rb" => Set[1] })
          MinitestHooks.on_capture.call("GadgetTest", "test_a", { "app/models/widget.rb" => Set[1] })

          deps = store.dependencies_for_file("app/models/widget.rb")

          assert_equal ["WidgetTest"], deps.map { |d| d[:class_name] }
        end
      end

      def test_wire_skips_tests_with_empty_coverage
        store = Store.new(path: ":memory:")
        MinitestHooks.wire(store: store, root: Dir.pwd)

        MinitestHooks.on_capture.call("EmptyTest", "test_a", {})

        assert_empty store.dependencies_for_file("anything.rb")
      end

      def test_captures_only_the_lines_touched_by_each_tests_own_body
        Dir.mktmpdir do |root|
          fixture = File.join(root, "widget.rb")
          File.write(fixture, <<~RUBY)
            class MinitestHooksFixtureWidget
              def a
                1
              end

              def b
                2
              end
            end
          RUBY
          load fixture

          captured = []
          MinitestHooks.root = root
          MinitestHooks.on_capture = ->(klass, method, coverage) { captured << [klass, method, coverage] }

          fixture_class = build_fixture_test_class

          # Minitest invocation always passes string method names (see
          # Runnable.run in the minitest source); using a string here too,
          # rather than a symbol, is what caught this the first time around.
          fixture_class.new("test_touches_a").run
          fixture_class.new("test_touches_b").run

          coverage_a = captured.find { |_, method, _| method == "test_touches_a" }&.last
          coverage_b = captured.find { |_, method, _| method == "test_touches_b" }&.last

          assert_equal Set[3], coverage_a["widget.rb"]
          assert_equal Set[7], coverage_b["widget.rb"]
        ensure
          Minitest::Runnable.runnables.delete(fixture_class)
          Object.send(:remove_const, :MinitestHooksFixtureTest) if defined?(MinitestHooksFixtureTest)
        end
      end

      private

      # Subclassing Minitest::Test registers the class in
      # Minitest::Runnable.runnables, the global list rake test's runner
      # discovers and runs. We remove it again in the caller's ensure block
      # so the rest of the suite doesn't pick this fixture up as a test.
      # It's also assigned to a named constant, not left anonymous, so
      # self.class.name in before_teardown resolves the same way it would
      # for an ordinary test class.
      def build_fixture_test_class
        klass = Class.new(Minitest::Test) do
          include Riptide::Collector::MinitestHooks

          def test_touches_a
            MinitestHooksFixtureWidget.new.a
          end

          def test_touches_b
            MinitestHooksFixtureWidget.new.b
          end
        end
        Object.const_set(:MinitestHooksFixtureTest, klass)
      end
    end
  end
end
