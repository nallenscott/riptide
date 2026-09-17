# frozen_string_literal: true

require "test_helper"

module Riptide
  class StoreTest < Minitest::Test
    def setup
      @store = Store.new(path: ":memory:")
    end

    def test_record_and_read_back_a_single_file
      @store.record(
        class_name: "ProviderTest",
        method_name: "test_updates_profile",
        coverage: { "app/models/provider.rb" => Set[12, 13, 14, 27, 28] },
        blob_shas: { "app/models/provider.rb" => "abc123" }
      )

      deps = @store.dependencies_for_file("app/models/provider.rb")

      assert_equal 1, deps.size
      assert_equal "ProviderTest", deps.first[:class_name]
      assert_equal "test_updates_profile", deps.first[:method_name]
      assert_equal "abc123", deps.first[:source_blob_sha]
      assert_equal [[12, 14], [27, 28]], deps.first[:ranges]
    end

    def test_record_across_multiple_files_in_one_call
      @store.record(
        class_name: "ProviderTest",
        method_name: "test_updates_profile",
        coverage: {
          "app/models/provider.rb" => Set[12],
          "app/services/provider_enrichment.rb" => Set[9, 10]
        },
        blob_shas: {
          "app/models/provider.rb" => "sha-a",
          "app/services/provider_enrichment.rb" => "sha-b"
        }
      )

      assert_equal [[12, 12]], @store.dependencies_for_file("app/models/provider.rb").first[:ranges]
      assert_equal [[9, 10]], @store.dependencies_for_file("app/services/provider_enrichment.rb").first[:ranges]
    end

    def test_re_recording_the_same_test_and_file_replaces_rather_than_duplicates
      @store.record(
        class_name: "ProviderTest",
        method_name: "test_updates_profile",
        coverage: { "app/models/provider.rb" => Set[12, 13] },
        blob_shas: { "app/models/provider.rb" => "sha-old" }
      )
      @store.record(
        class_name: "ProviderTest",
        method_name: "test_updates_profile",
        coverage: { "app/models/provider.rb" => Set[40, 41, 42] },
        blob_shas: { "app/models/provider.rb" => "sha-new" }
      )

      deps = @store.dependencies_for_file("app/models/provider.rb")

      assert_equal 1, deps.size
      assert_equal "sha-new", deps.first[:source_blob_sha]
      assert_equal [[40, 42]], deps.first[:ranges]
    end

    def test_multiple_tests_covering_the_same_file_are_all_returned
      @store.record(
        class_name: "ProviderTest",
        method_name: "test_updates_profile",
        coverage: { "app/models/provider.rb" => Set[12] },
        blob_shas: { "app/models/provider.rb" => "sha-a" }
      )
      @store.record(
        class_name: "ProviderEnrichmentTest",
        method_name: "test_enriches",
        coverage: { "app/models/provider.rb" => Set[40] },
        blob_shas: { "app/models/provider.rb" => "sha-a" }
      )

      deps = @store.dependencies_for_file("app/models/provider.rb")

      assert_equal %w[ProviderTest ProviderEnrichmentTest].sort, deps.map { |d| d[:class_name] }.sort
    end

    def test_a_file_with_no_touched_lines_records_no_row
      @store.record(
        class_name: "ProviderTest",
        method_name: "test_updates_profile",
        coverage: { "app/models/provider.rb" => Set.new },
        blob_shas: { "app/models/provider.rb" => "sha-a" }
      )

      assert_empty @store.dependencies_for_file("app/models/provider.rb")
    end

    def test_dependencies_for_an_unknown_file_is_empty
      assert_empty @store.dependencies_for_file("app/models/nonexistent.rb")
    end

    def test_empty_is_true_until_the_first_test_is_recorded
      assert @store.empty?

      @store.record(
        class_name: "ProviderTest",
        method_name: "test_updates_profile",
        coverage: { "app/models/provider.rb" => Set[1] },
        blob_shas: { "app/models/provider.rb" => "sha-a" }
      )

      refute @store.empty?
    end

    def test_prune_except_removes_tests_not_in_the_known_set
      @store.record(
        class_name: "ProviderTest", method_name: "test_a",
        coverage: { "app/models/provider.rb" => Set[1] },
        blob_shas: { "app/models/provider.rb" => "sha-a" }
      )
      @store.record(
        class_name: "ProviderTest", method_name: "test_b",
        coverage: { "app/models/provider.rb" => Set[2] },
        blob_shas: { "app/models/provider.rb" => "sha-a" }
      )

      @store.prune_except([["ProviderTest", "test_a"]])

      deps = @store.dependencies_for_file("app/models/provider.rb")
      assert_equal [["ProviderTest", "test_a"]], deps.map { |d| [d[:class_name], d[:method_name]] }
    end

    def test_prune_except_also_removes_the_pruned_tests_dependency_rows
      @store.record(
        class_name: "ProviderTest", method_name: "test_a",
        coverage: { "app/models/provider.rb" => Set[1], "app/models/other.rb" => Set[5] },
        blob_shas: { "app/models/provider.rb" => "sha-a", "app/models/other.rb" => "sha-b" }
      )

      @store.prune_except([])

      assert_empty @store.dependencies_for_file("app/models/provider.rb")
      assert_empty @store.dependencies_for_file("app/models/other.rb")
    end

    def test_prune_except_keeps_everything_when_nothing_is_stale
      @store.record(
        class_name: "ProviderTest", method_name: "test_a",
        coverage: { "app/models/provider.rb" => Set[1] },
        blob_shas: { "app/models/provider.rb" => "sha-a" }
      )

      @store.prune_except([["ProviderTest", "test_a"]])

      assert_equal 1, @store.dependencies_for_file("app/models/provider.rb").size
    end
  end
end
