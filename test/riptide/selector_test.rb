# frozen_string_literal: true

require "test_helper"

module Riptide
  class SelectorTest < Minitest::Test
    include GitFixture

    WIDGET = <<~RUBY
      class Widget
        LIMIT = 5

        def limit
          LIMIT
        end

        def other
          :other
        end
      end
    RUBY

    TEST = %w[WidgetTest test_limit].freeze

    # A repository with widget.rb committed, a local store, and a helper to
    # record a run against whatever widget.rb is right now.
    def with_widget
      in_repo do |root|
        write_and_commit(root, "app/widget.rb", WIDGET, message: "widget")
        @root = root
        @store = Store.new(root: root, suite: "unit", log_dir: File.join(root, "tmp/riptide"))
        yield
      end
    end

    def sha = Diff.blob_sha(File.join(@root, "app/widget.rb"))

    def record(facets = { "methods" => ["Widget#limit"] }, test: TEST, passed: true, at: 1.0, env: {})
      env_set = Store.set_id(env)
      @store.append_set(env_set, env)
      @store.append_run(Store::Run.new(test: test, at: at, passed: passed, sets: [env_set],
                                       inputs: { "app/widget.rb" => { "sha" => sha }.merge(facets) }))
    end

    def edit(from, to)
      path = File.join(@root, "app/widget.rb")
      File.write(path, File.read(path).sub(from, to))
    end

    def reasons(tests = [TEST], listings: {})
      layout = Layout.new(root: @root)
      analyzer = Analyzer.new(layout: layout, blobs: @store.method(:read_blob), load_facts: @store.method(:load_facts))
      Selector.new(indexes: @store.indexes, analyzer: analyzer, root: @root, tests: tests, listing: ->(pattern) { listings[pattern] }).select.selected.map { |entry| entry[:reason] }
    end

    def test_a_test_with_no_recorded_run_is_selected
      with_widget { assert_equal ["no recorded run"], reasons }
    end

    def test_an_unchanged_tree_selects_nothing
      with_widget do
        record
        assert_empty reasons
      end
    end

    def test_a_test_that_failed_last_time_runs_again
      with_widget do
        record(passed: false)
        assert_equal ["failed and hasn't passed since"], reasons
      end
    end

    def test_editing_a_method_the_test_ran_selects_it
      with_widget do
        record
        edit("    LIMIT\n", "    LIMIT + 1\n")
        assert_equal ["app/widget.rb changed Widget#limit"], reasons
      end
    end

    def test_editing_a_method_the_test_never_ran_selects_nothing
      with_widget do
        record
        edit(":other", ":changed")
        assert_empty reasons
      end
    end

    def test_changing_a_method_header_selects_tests_that_ran_it
      with_widget do
        record
        edit("def limit", "def limit(scale = 1)")
        assert_equal ["app/widget.rb changed Widget#limit"], reasons
      end
    end

    def test_changing_a_constant_selects_tests_that_referenced_it
      with_widget do
        record({ "constants" => ["Widget::LIMIT"] })
        record({ "methods" => ["Widget#other"] }, test: %w[WidgetTest test_other])
        edit("LIMIT = 5", "LIMIT = 6")

        assert_equal ["app/widget.rb changed Widget::LIMIT"], reasons([TEST, %w[WidgetTest test_other]])
      end
    end

    def test_a_declaration_selects_tests_that_used_the_class
      with_widget do
        record({ "owners" => ["Widget"] })
        edit("  LIMIT = 5\n", "  LIMIT = 5\n  validates :name\n")
        assert_equal ["app/widget.rb changed Widget"], reasons
      end
    end

    def test_a_line_shift_alone_selects_nothing
      with_widget do
        record
        edit("class Widget\n", "# widgets\n\nclass Widget\n")
        assert_empty reasons
      end
    end

    def test_a_changed_fallback_file_selects_the_test
      with_widget do
        write_and_commit(@root, "Gemfile.lock", "old\n", message: "lock")
        record(env: { "Gemfile.lock" => { "sha" => Diff.blob_sha(File.join(@root, "Gemfile.lock")), "whole" => true } })
        File.write(File.join(@root, "Gemfile.lock"), "new\n")

        assert_equal ["Gemfile.lock changed as a whole"], reasons
      end
    end

    def test_a_deleted_dependency_selects_the_test
      with_widget do
        record
        File.delete(File.join(@root, "app/widget.rb"))
        assert_equal ["app/widget.rb was deleted"], reasons
      end
    end

    def test_a_recorded_version_the_repository_lacks_selects_the_test
      with_widget do
        @store.append_run(Store::Run.new(test: TEST, at: 1.0, passed: true, sets: [],
                                         inputs: { "app/widget.rb" => { "sha" => "f" * 40, "methods" => ["Widget#limit"] } }))
        assert_match(/isn't in this repository/, reasons.first)
      end
    end

    def test_an_older_run_that_matches_the_tree_exactly_skips_the_test
      with_widget do
        record(at: 1.0)
        edit("LIMIT = 5", "LIMIT = 10")
        record(at: 2.0)
        edit("LIMIT = 10", "LIMIT = 5")

        assert_empty reasons
      end
    end

    def test_a_top_level_change_selects_the_whole_suite
      with_widget do
        write_and_commit(@root, "test/test_helper.rb", "require 'minitest'\n", message: "helper")
        helper_sha = Diff.blob_sha(File.join(@root, "test/test_helper.rb"))
        record(env: { "test/test_helper.rb" => { "sha" => helper_sha } })
        record({ "methods" => ["Widget#other"] }, test: %w[WidgetTest test_other], env: {})
        File.write(File.join(@root, "test/test_helper.rb"), "require 'minitest/autorun'\n")

        assert_equal ["test/test_helper.rb changed top-level code"] * 2, reasons([TEST, %w[WidgetTest test_other]])
      end
    end

    # Rails sets default_internal to UTF-8, which makes writing raw bytes to a
    # text file convert them.
    def test_files_with_non_ascii_content_are_compared_as_text
      internal = Encoding.default_internal
      quietly { Encoding.default_internal = Encoding::UTF_8 }
      with_widget do
        write_and_commit(@root, "app/widget.rb", WIDGET.sub("class Widget", "# Widgets – the café kind\nclass Widget"), message: "accents")
        record
        edit("    LIMIT\n", "    LIMIT + 1 # “more”\n")

        assert_equal ["app/widget.rb changed Widget#limit"], reasons
      end
    ensure
      quietly { Encoding.default_internal = internal }
    end

    # Ruby warns about setting default_internal, which is the point here.
    def quietly
      verbose = $VERBOSE
      $VERBOSE = nil
      yield
    ensure
      $VERBOSE = verbose
    end

    def test_a_run_whose_shared_set_is_missing_counts_as_unrecorded
      with_widget do
        @store.append_run(Store::Run.new(test: TEST, at: 1.0, passed: true, sets: ["0" * 16],
                                         inputs: { "app/widget.rb" => { "sha" => sha, "methods" => ["Widget#limit"] } }))
        assert_equal ["no recorded run"], reasons
      end
    end

    def test_a_new_file_matching_a_recorded_glob_selects_the_test
      with_widget do
        record(env: { "glob:test/support/**/*.rb" => { "sha" => "before" } })

        assert_empty reasons(listings: { "test/support/**/*.rb" => "before" })
        assert_equal ["files matching test/support/**/*.rb were added or removed"], reasons(listings: { "test/support/**/*.rb" => "after" })
      end
    end

    def test_a_file_that_no_longer_parses_selects_its_dependents
      with_widget do
        record
        edit("def other", "def other(")
        assert_equal ["app/widget.rb changed as a whole"], reasons
      end
    end
  end
end
