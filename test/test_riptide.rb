# frozen_string_literal: true

require "test_helper"

class TestRiptide < Minitest::Test
  include GitFixture

  def test_that_it_has_a_version_number
    refute_nil ::Riptide::VERSION
  end

  def test_default_base_uses_merge_base_when_the_remote_ref_exists
    in_repo do |root|
      write_and_commit(root, "a.txt", "1\n", message: "base")
      base_sha = `git rev-parse HEAD`.strip
      system("git", "update-ref", "refs/remotes/origin/main", base_sha, exception: true)

      write_and_commit(root, "a.txt", "2\n", message: "feature work")

      assert_equal base_sha, Riptide.default_base
    end
  end

  def test_default_base_falls_back_to_the_ref_itself_when_it_has_no_local_history
    in_repo do |root|
      write_and_commit(root, "a.txt", "1\n", message: "base")

      assert_equal "origin/main", Riptide.default_base
    end
  end

  def test_decide_returns_a_bootstrap_full_suite_decision_for_an_empty_store
    in_repo do |root|
      write_and_commit(root, "a.txt", "1\n", message: "base")
      store = Riptide::Store.new(path: ":memory:")

      decision, base = Riptide.decide(store: store, root: root, discovered_tests_by_file: {})

      assert_equal :full, decision.mode
      assert_equal "no dependency map yet", decision.reason
      assert_nil base
    end
  end

  def test_decide_computes_a_real_decision_against_base_for_a_non_empty_store
    in_repo do |root|
      write_and_commit(root, "app/models/widget.rb", "class Widget\nend\n", message: "base")
      base_sha = `git rev-parse HEAD`.strip
      system("git", "update-ref", "refs/remotes/origin/main", base_sha, exception: true)

      store = Riptide::Store.new(path: ":memory:")
      store.record(
        class_name: "WidgetTest", method_name: "test_a",
        coverage: { "app/models/widget.rb" => Set[1] },
        blob_shas: { "app/models/widget.rb" => Riptide::Diff.blob_sha(File.join(root, "app/models/widget.rb")) }
      )

      decision, base = Riptide.decide(store: store, root: root, discovered_tests_by_file: {})

      assert_equal :selected, decision.mode
      assert_equal base_sha, base
    end
  end
end
