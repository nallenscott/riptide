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

    # +env+ is what the process's setup recorded, +setup+ what the test
    # class's did.
    def record(facets = { "methods" => ["Widget#limit"] }, test: TEST, passed: true, at: 1.0, env: {}, setup: nil)
      sets = [["process", env], (["class", setup] if setup)].compact.map do |scope, files|
        Store.set_id(files, scope).tap { |id| @store.append_set(id, files, scope: scope) }
      end
      @store.append_run(Store::Run.new(test: test, at: at, passed: passed, sets: sets,
                                       inputs: { "app/widget.rb" => { "sha" => sha }.merge(facets) }))
    end

    def edit(from, to)
      path = File.join(@root, "app/widget.rb")
      File.write(path, File.read(path).sub(from, to))
    end

    # A run of +test+ that queried +tables+, recorded the way Inputs does,
    # in the test or before it in the process.
    def record_tables(*tables, test: TEST, process: false, source_patterns: [])
      inputs = Inputs.new(layout: Layout.new(root: @root), files: Git.new(@root).files, source_patterns: source_patterns)
      if process
        env = inputs.for_process({}, Set.new(tables))
        @store.append_set(Store.set_id(env, "process"), env, scope: "process")
        @store.append_run(Store::Run.new(test: test, at: 1.0, passed: true, sets: [Store.set_id(env, "process")], inputs: {}))
      else
        window = Collectors::Window.blank.tap { |blank| blank.tables.merge(tables) }
        files, sets = inputs.for_test(Struct.new(:lines, :receivers).new({}, []), window)
        @store.append_run(Store::Run.new(test: test, at: 1.0, passed: true, sets: sets.keys, inputs: files))
      end
    end

    # +listings+ stands in for what recorded globs match now.
    def decision(tests = [TEST], listings: {}, fallback: [])
      layout = Layout.new(root: @root)
      analyzer = Analyzer.new(layout: layout, blobs: @store.method(:read_blob), load_facts: @store.method(:load_facts))
      inputs = Inputs.new(layout: layout, files: Git.new(@root).files)
      pseudo = ->(key) { listings.fetch(key) { inputs.pseudo(key) } }
      Selector.new(indexes: @store.indexes, analyzer: analyzer, root: @root, tests: tests, pseudo: pseudo, fallback: fallback).select
    end

    def reasons(tests = [TEST], **options) = decision(tests, **options).selected.map { |entry| entry[:reason] }

    # { test => [change, through] } from the plan.
    def explained(tests, **options)
      decision(tests, **options).to_h["selected"].to_h { |entry| [entry["test"], entry.values_at("change", "through")] }
    end

    BOOT = %w[WidgetTest test_boot].freeze
    SETUP = %w[WidgetTest test_setup].freeze

    def test_a_selection_says_how_a_change_reached_each_test
      with_widget do
        limit = { "app/widget.rb" => { "sha" => sha, "methods" => ["Widget#limit"] } }
        record
        record({}, test: BOOT, env: limit)
        record({}, test: SETUP, setup: limit)
        edit("    LIMIT\n", "    LIMIT + 1\n")

        code = Selector::KINDS[:code]
        assert_equal({ TEST => [code, "their own runs"], BOOT => [code, "the process's setup"], SETUP => [code, "their test class's setup"] }, explained([TEST, BOOT, SETUP]))
      end
    end

    # The test's own run is the closest way a change reaches it.
    def test_a_change_that_reaches_a_test_two_ways_counts_its_own_run
      with_widget do
        record(env: { "app/widget.rb" => { "sha" => sha, "methods" => ["Widget#limit"] } })
        edit("    LIMIT\n", "    LIMIT + 1\n")

        assert_equal({ TEST => [Selector::KINDS[:code], "their own runs"] }, explained([TEST]))
      end
    end

    def test_a_change_in_both_setups_counts_the_test_class_s
      with_widget do
        limit = { "app/widget.rb" => { "sha" => sha, "methods" => ["Widget#limit"] } }
        record({}, env: limit, setup: limit)
        edit("    LIMIT\n", "    LIMIT + 1\n")

        assert_equal({ TEST => [Selector::KINDS[:code], "their test class's setup"] }, explained([TEST]))
      end
    end

    def test_a_summary_counts_tests_by_change_and_names_the_biggest_causes
      with_widget do
        record
        record({}, test: BOOT, env: { "app/widget.rb" => { "sha" => sha, "methods" => ["Widget#limit"] } })
        record({ "constants" => ["Widget::LIMIT"] }, test: SETUP)
        record({ "methods" => ["Widget#other"] }, test: %w[WidgetTest test_other])
        edit("    LIMIT\n", "    LIMIT + 1\n")
        edit("LIMIT = 5", "LIMIT = 6")

        assert_equal <<~TEXT.chomp, decision([TEST, BOOT, SETUP, %w[WidgetTest test_new], %w[WidgetTest test_other]]).summary
          4/5 tests
            Anything inside a method or block: 2
            A constant's value: 1
            A test with no recorded run: 1
            through their own runs: 2, most from app/widget.rb changed Widget#limit (1), app/widget.rb changed Widget::LIMIT (1)
            through the process's setup: 1, most from app/widget.rb changed Widget#limit (1)
        TEXT
      end
    end

    def test_a_selection_tells_declarations_fallback_files_and_preloaded_files_apart
      with_widget do
        write_and_commit(@root, "Gemfile.lock", "old\n", message: "lock")
        write_and_commit(@root, "test/test_helper.rb", "X = 1\n", message: "helper")
        whole = ->(path) { { path => { "sha" => Diff.blob_sha(File.join(@root, path)), "whole" => true } } }
        record({ "owners" => ["Widget"] })
        record({}, test: BOOT, env: whole.("Gemfile.lock"))
        record({}, test: SETUP, env: whole.("test/test_helper.rb"))
        edit("  LIMIT = 5\n", "  LIMIT = 5\n  validates :name\n")
        File.write(File.join(@root, "Gemfile.lock"), "new\n")
        File.write(File.join(@root, "test/test_helper.rb"), "X = 2\n")

        assert_equal({ TEST => [Selector::KINDS[:declaration], "their own runs"], BOOT => [Selector::KINDS[:fallback], "the process's setup"],
                       SETUP => [Selector::KINDS[:preloaded], "the process's setup"] }, explained([TEST, BOOT, SETUP], fallback: ["Gemfile.lock"]))
      end
    end

    def test_a_test_with_no_recorded_run_is_selected
      with_widget { assert_equal ["no recorded run"], reasons }
    end

    # Two spec tests with the same describe and it text share a key, so
    # their runs can't be told apart.
    def test_tests_that_share_a_key_always_run
      with_widget do
        record({ "methods" => ["Widget#limit"] })
        record({ "methods" => ["Widget#other"] }, at: 2.0)
        edit(":other", ":changed")

        assert_equal ["shares its name with another test, so their runs can't be told apart"] * 2, reasons([TEST, TEST])
        assert_empty reasons([TEST]), "one test with that key still skips on a run that holds"
      end
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

    module SelectorPerson
      def self.table_name = "people"
    end

    module SelectorMember
      def self.table_name = "members"
    end

    PEOPLE = "_fixture:\n  model_class: Riptide::SelectorTest::SelectorPerson\n\none:\n  name: a\n"
    MEMBERS_TEST = %w[MemberTest test_it].freeze

    # The rows leave people when the file starts filling members instead.
    def test_a_fixture_moved_to_another_model_selects_tests_that_touched_its_old_table
      with_widget do
        write_and_commit(@root, "test/fixtures/people.yml", PEOPLE, message: "fixture")
        record_tables("people")
        File.write(File.join(@root, "test/fixtures/people.yml"), PEOPLE.sub("SelectorPerson", "SelectorMember"))

        assert_equal ["fixture files for people were added or removed"], reasons
      end
    end

    # A test that touched members never loaded people.yml, so only the
    # fixture files for its table can say the rows arrived.
    def test_a_fixture_moved_to_another_model_selects_tests_that_touched_its_new_table
      with_widget do
        write_and_commit(@root, "test/fixtures/people.yml", PEOPLE, message: "fixture")
        record_tables("members", test: MEMBERS_TEST)
        assert_empty reasons([MEMBERS_TEST])

        File.write(File.join(@root, "test/fixtures/people.yml"), PEOPLE.sub("SelectorPerson", "SelectorMember"))
        assert_equal ["fixture files for members were added or removed"], reasons([MEMBERS_TEST])
      end
    end

    def test_a_new_fixture_file_selects_only_tests_that_touched_its_table
      with_widget do
        write_and_commit(@root, "test/fixtures/people.yml", PEOPLE, message: "fixture")
        record_tables("cards")
        record_tables("people", test: MEMBERS_TEST)
        FileUtils.mkdir_p(File.join(@root, "test/fixtures"))
        File.write(File.join(@root, "test/fixtures/cards.yml"), "one:\n  id: 1\n")

        assert_equal ["fixture files for cards were added or removed"], reasons([TEST, MEMBERS_TEST])
      end
    end

    def test_a_new_fixture_file_selects_tests_whose_process_touched_its_table
      with_widget do
        record_tables("cards", process: true)
        assert_empty reasons

        write_and_commit(@root, "test/fixtures/cards.yml", "one:\n  id: 1\n", message: "fixture")
        assert_equal ["fixture files for cards were added or removed"], reasons
      end
    end

    # Source patterns say where code lives. Tables are recorded on the
    # schema and fixtures wherever those sit.
    def test_a_table_change_selects_the_test_when_source_patterns_leave_out_the_schema_and_fixtures
      with_widget do
        write_and_commit(@root, "db/structure.sql", "CREATE TABLE public.cards (\n    id bigint NOT NULL\n);\n", message: "schema")
        write_and_commit(@root, "test/fixtures/cards.yml", "one:\n  id: 1\n", message: "fixture")
        record_tables("cards", source_patterns: ["app/**/*.rb"])
        assert_empty reasons

        File.write(File.join(@root, "db/structure.sql"), "CREATE TABLE public.cards (\n    id bigint NOT NULL,\n    limit integer\n);\n")
        refute_empty reasons
        system("git", "-C", @root, "checkout", "-q", "db/structure.sql", exception: true)

        File.write(File.join(@root, "test/fixtures/cards.yml"), "one:\n  id: 2\n")
        refute_empty reasons
      end
    end

    def test_a_new_file_matching_a_recorded_glob_selects_the_test
      with_widget do
        record(env: { "glob:test/support/**/*.rb" => { "sha" => "before" } })

        assert_empty reasons(listings: { "glob:test/support/**/*.rb" => "before" })
        assert_equal ["files matching test/support/**/*.rb were added or removed"], reasons(listings: { "glob:test/support/**/*.rb" => "after" })
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
