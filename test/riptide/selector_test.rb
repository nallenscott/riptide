# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module Riptide
  class SelectorTest < Minitest::Test
    include GitFixture

    def setup
      @store = Store.new(path: ":memory:")
    end

    def test_selects_only_the_test_whose_covered_range_was_actually_touched
      in_repo do |root|
        write_and_commit(root, "app/models/provider.rb", provider_source, message: "base")
        base_sha = Diff.blob_sha(File.join(root, "app/models/provider.rb"))

        @store.record(
          class_name: "ProviderTest", method_name: "test_a",
          coverage: { "app/models/provider.rb" => Set[2, 3, 4] },
          blob_shas: { "app/models/provider.rb" => base_sha }
        )
        @store.record(
          class_name: "ProviderTest", method_name: "test_b",
          coverage: { "app/models/provider.rb" => Set[7, 8, 9] },
          blob_shas: { "app/models/provider.rb" => base_sha }
        )

        write_and_commit(root, "app/models/provider.rb", provider_source_with_method_b_changed, message: "edit")

        decision = Selector.new(store: @store, root: root).select(base: "HEAD~1", head: "HEAD")

        assert_equal :selected, decision.mode
        assert_equal [["ProviderTest", "test_b"]], decision.selected.map { |s| [s[:class_name], s[:method_name]] }
      end
    end

    def test_a_file_with_zero_historical_coverage_forces_a_full_run
      in_repo do |root|
        write_and_commit(root, "app/models/untracked.rb", "class Untracked\n  def a\n    1\n  end\nend\n", message: "base")
        write_and_commit(root, "app/models/untracked.rb", "class Untracked\n  def a\n    2\n  end\nend\n", message: "edit")

        decision = Selector.new(store: @store, root: root).select(base: "HEAD~1", head: "HEAD")

        assert_equal :full, decision.mode
        assert_match(/no historical coverage/, decision.reason)
      end
    end

    def test_a_global_fallback_file_forces_a_full_run_even_with_no_store_data
      in_repo do |root|
        write_and_commit(root, "Gemfile", "source 'https://rubygems.org'\n", message: "base")
        write_and_commit(root, "Gemfile", "source 'https://rubygems.org'\ngem 'rails'\n", message: "edit")

        decision = Selector.new(store: @store, root: root).select(base: "HEAD~1", head: "HEAD")

        assert_equal :full, decision.mode
        assert_match(/global fallback pattern/, decision.reason)
      end
    end

    def test_a_brand_new_file_does_not_force_a_full_run
      in_repo do |root|
        write_and_commit(root, "app/models/provider.rb", provider_source, message: "base")
        base_sha = Diff.blob_sha(File.join(root, "app/models/provider.rb"))
        @store.record(
          class_name: "ProviderTest", method_name: "test_a",
          coverage: { "app/models/provider.rb" => Set[2, 3, 4] },
          blob_shas: { "app/models/provider.rb" => base_sha }
        )

        write_and_commit(root, "app/models/brand_new.rb", "class BrandNew\nend\n", message: "add")

        decision = Selector.new(store: @store, root: root).select(base: "HEAD~1", head: "HEAD")

        assert_equal :selected, decision.mode
        assert_empty decision.selected
      end
    end

    def test_a_deleted_file_selects_its_known_tests_without_forcing_a_full_run
      in_repo do |root|
        write_and_commit(root, "app/models/provider.rb", provider_source, message: "base 1")
        base_sha = Diff.blob_sha(File.join(root, "app/models/provider.rb"))
        @store.record(
          class_name: "ProviderTest", method_name: "test_a",
          coverage: { "app/models/provider.rb" => Set[2, 3, 4] },
          blob_shas: { "app/models/provider.rb" => base_sha }
        )
        # An unrelated already-tracked file, so this diff has something else
        # to anchor "base" against besides the file being deleted.
        write_and_commit(root, "app/models/other.rb", "class Other\nend\n", message: "base 2")

        FileUtils.rm(File.join(root, "app/models/provider.rb"))
        commit(root, "delete provider")

        decision = Selector.new(store: @store, root: root).select(base: "HEAD~1", head: "HEAD")

        assert_equal :selected, decision.mode
        assert_equal [["ProviderTest", "test_a"]], decision.selected.map { |s| [s[:class_name], s[:method_name]] }
      end
    end

    def test_a_new_test_method_in_a_modified_file_gets_selected_even_with_no_history
      in_repo do |root|
        write_and_commit(root, "test/models/provider_test.rb", provider_test_source, message: "base")
        base_sha = Diff.blob_sha(File.join(root, "test/models/provider_test.rb"))
        @store.record(
          class_name: "ProviderTest", method_name: "test_a",
          coverage: { "test/models/provider_test.rb" => Set[2, 3, 4] },
          blob_shas: { "test/models/provider_test.rb" => base_sha }
        )

        write_and_commit(root, "test/models/provider_test.rb", provider_test_source_with_new_method, message: "add test_b")

        discovered = { "test/models/provider_test.rb" => [%w[ProviderTest test_a], %w[ProviderTest test_b]] }
        decision = Selector.new(store: @store, root: root, discovered_tests_by_file: discovered)
                            .select(base: "HEAD~1", head: "HEAD")

        assert_equal :selected, decision.mode
        assert_includes decision.selected.map { |s| [s[:class_name], s[:method_name]] }, ["ProviderTest", "test_b"]
      end
    end

    def test_an_already_known_test_does_not_get_redundantly_selected_by_discovery
      in_repo do |root|
        write_and_commit(root, "app/models/provider.rb", provider_source, message: "base")
        base_sha = Diff.blob_sha(File.join(root, "app/models/provider.rb"))
        @store.record(
          class_name: "ProviderTest", method_name: "test_a",
          coverage: { "app/models/provider.rb" => Set[2, 3, 4] },
          blob_shas: { "app/models/provider.rb" => base_sha }
        )
        write_and_commit(root, "app/models/other.rb", "class Other\nend\n", message: "unrelated")

        discovered = { "app/models/provider.rb" => [%w[ProviderTest test_a]] }
        decision = Selector.new(store: @store, root: root, discovered_tests_by_file: discovered)
                            .select(base: "HEAD~1", head: "HEAD")

        assert_equal :selected, decision.mode
        assert_empty decision.selected
      end
    end

    private

    def provider_test_source
      <<~RUBY
        class ProviderTest < Minitest::Test
          def test_a
            assert true
          end
        end
      RUBY
    end

    def provider_test_source_with_new_method
      <<~RUBY
        class ProviderTest < Minitest::Test
          def test_a
            assert true
          end

          def test_b
            assert true
          end
        end
      RUBY
    end

    def provider_source
      <<~RUBY
        class Provider
          def a
            1
          end

          def b
            2
          end
        end
      RUBY
    end

    def provider_source_with_method_b_changed
      <<~RUBY
        class Provider
          def a
            1
          end

          def b
            2 + 1
          end
        end
      RUBY
    end

  end
end
