# frozen_string_literal: true

require "test_helper"

module Riptide
  class RunnerTest < Minitest::Test
    include GitFixture

    def setup
      @store = Store.new(path: ":memory:")
    end

    def teardown
      Collector::MinitestHooks.root = nil
      Collector::MinitestHooks.on_capture = nil
    end

    def test_apply_filters_runnables_down_to_the_selected_tests
      fixture_a = build_fixture_class(:RunnerFixtureA, %i[test_x test_y])
      fixture_b = build_fixture_class(:RunnerFixtureB, %i[test_z])

      decision = Selector::Decision.new(
        mode: :selected, reason: nil,
        selected: [{ class_name: fixture_a.name, method_name: "test_x", reasons: [] }]
      )

      Runner.new(decision: decision, store: @store).apply(runnables: [fixture_a, fixture_b])

      assert_equal ["test_x"], fixture_a.runnable_methods
      assert_equal [], fixture_b.runnable_methods
    ensure
      cleanup_fixture(:RunnerFixtureA)
      cleanup_fixture(:RunnerFixtureB)
    end

    def test_apply_leaves_runnables_untouched_in_full_mode
      fixture = build_fixture_class(:RunnerFixtureFull, %i[test_x test_y])

      decision = Selector::Decision.new(mode: :full, reason: "Gemfile changed", selected: [])

      Runner.new(decision: decision, store: @store).apply(runnables: [fixture])

      assert_equal %w[test_x test_y], fixture.runnable_methods.sort
    ensure
      cleanup_fixture(:RunnerFixtureFull)
    end

    def test_apply_wires_the_collector_root
      decision = Selector::Decision.new(mode: :full, reason: nil, selected: [])

      Runner.new(decision: decision, store: @store, root: "/tmp/example").apply(runnables: [])

      assert_equal "/tmp/example", Collector::MinitestHooks.root
    end

    def test_on_capture_persists_coverage_with_the_files_current_blob_sha
      in_repo do |root|
        write_and_commit(root, "app/models/widget.rb", "class Widget\nend\n", message: "base")
        decision = Selector::Decision.new(mode: :full, reason: nil, selected: [])

        Runner.new(decision: decision, store: @store, root: root).apply(runnables: [])
        Collector::MinitestHooks.on_capture.call("WidgetTest", "test_a", { "app/models/widget.rb" => Set[1] })

        deps = @store.dependencies_for_file("app/models/widget.rb")

        assert_equal 1, deps.size
        assert_equal Diff.blob_sha(File.join(root, "app/models/widget.rb")), deps.first[:source_blob_sha]
      end
    end

    def test_on_capture_skips_tests_with_empty_coverage
      decision = Selector::Decision.new(mode: :full, reason: nil, selected: [])
      Runner.new(decision: decision, store: @store).apply(runnables: [])

      Collector::MinitestHooks.on_capture.call("EmptyTest", "test_a", {})

      assert_empty @store.dependencies_for_file("anything.rb")
    end

    private

    def build_fixture_class(const_name, method_names)
      klass = Class.new(Minitest::Test) do
        method_names.each { |m| define_method(m) {} }
      end
      Object.const_set(const_name, klass)
    end

    def cleanup_fixture(const_name)
      klass = Object.const_get(const_name)
      Minitest::Runnable.runnables.delete(klass)
      Object.send(:remove_const, const_name)
    end
  end
end
