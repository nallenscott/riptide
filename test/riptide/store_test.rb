# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

module Riptide
  class StoreTest < Minitest::Test
    include GitFixture

    TEST = %w[WidgetTest test_a].freeze
    OTHER = %w[OtherTest test_b].freeze
    MAIN = Store::Build.branch("main", harvest: true)

    def pr(number = 1, target: "main") = Store::Build.pr(number, target: target)

    # A repository with a bare remote, and a helper to clone it.
    def with_remote
      Dir.mktmpdir do |dir|
        remote = File.join(dir, "remote.git")
        system("git", "init", "-q", "--bare", "-b", "main", remote, exception: true)
        clone = ->(name) do
          path = File.join(dir, name)
          system("git", "clone", "-q", remote, path, exception: true, err: File::NULL)
          system("git", "-C", path, "config", "user.email", "t@t", exception: true)
          system("git", "-C", path, "config", "user.name", "t", exception: true)
          path
        end
        yield remote, clone
      end
    end

    def store_for(root, suite: "unit", **options)
      Store.new(root: root, suite: suite, log_dir: File.join(root, "tmp/riptide/#{suite}"), **options)
    end

    def commit_file(root, path, content, push: false)
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), content)
      system("git", "-C", root, "add", path, exception: true)
      system("git", "-C", root, "commit", "-qm", "add #{path}", exception: true)
      system("git", "-C", root, "push", "-q", "origin", "HEAD", exception: true, err: File::NULL) if push
      Diff.blob_sha(File.join(root, path))
    end

    def run_for(sha, at: 1.0, passed: true, test: TEST, sets: [], methods: ["Widget#a"], file: nil)
      Store::Run.new(test: test, at: at, passed: passed, sets: sets, inputs: { "app/widget.rb" => { "sha" => sha, "methods" => methods } }, file: file)
    end

    def fetch(root, build) = Store.fetch(root: root, build: build)

    # Every passing run of +test+ the store can read, newest first.
    def ats(store, test) = store.indexes.flat_map { |index| index.runs.fetch(test, []) }.map(&:at).sort.reverse
    def marks(store, test) = store.indexes.flat_map { |index| index.marks.fetch(test, []).to_a }

    def branch(root, name, from: "main") = system("git", "-C", root, "checkout", "-q", "-b", name, from, exception: true)
    def checkout(root, name) = system("git", "-C", root, "checkout", "-q", name, exception: true)
    def git(root, *args) = IO.popen(["git", "-C", root, *args], err: File::NULL, &:read)
    def refs(root) = git(root, "for-each-ref", "--format=%(refname)", "refs/riptide/").lines.map(&:strip)
    def push_main(root) = system("git", "-C", root, "push", "-q", "origin", "main", exception: true, err: File::NULL)

    def test_runs_appended_by_a_process_are_readable_before_publishing
      with_remote do |_, clone|
        root = clone.("a")
        store = store_for(root)
        store.append_run(run_for(commit_file(root, "app/widget.rb", "class Widget\nend\n")))

        assert_equal [1.0], ats(store, TEST)
      end
    end

    def test_published_runs_are_readable_from_another_clone_after_a_fetch
      with_remote do |_, clone|
        a = clone.("a")
        sha = commit_file(a, "app/widget.rb", "class Widget\nend\n", push: true)
        writer = store_for(a)
        writer.append_set("e1", { "Gemfile.lock" => { "sha" => "g1", "whole" => true } })
        writer.append_load_facts(sha, { "1" => { "owners" => ["Widget"], "called" => false } })
        writer.append_run(run_for(sha, sets: ["e1"]))
        assert_equal "refs/riptide/runs/unit/branches/main", writer.publish(build: MAIN).ref

        b = clone.("b")
        fetch(b, MAIN)
        reader = store_for(b)

        assert_equal [1.0], ats(reader, TEST)
        model = reader.indexes.first.model
        run = model.runs.fetch(TEST).first.last
        assert_equal({ "Gemfile.lock" => { "sha" => "g1", "whole" => true } }, model.set(run.sets.first).files)
        assert_equal({ 1 => { "owners" => ["Widget"], "called" => false } }, reader.load_facts(sha))
        assert_equal "class Widget\nend\n", reader.read_blob(sha)
      end
    end

    # A push uploads only the objects the host doesn't have, which git can
    # only work out through a tag, never through a commit with no parent.
    def test_a_unit_is_two_tags_wrapping_trees
      with_remote do |remote, clone|
        root = clone.("a")
        store = store_for(root)
        store.append_run(run_for(commit_file(root, "app/widget.rb", "x = 1\n", push: true)))
        store.publish(build: MAIN)

        %w[runs stamps].each do |kind|
          ref = "refs/riptide/#{kind}/unit/branches/main"
          assert_equal "tag", git(remote, "cat-file", "-t", ref).strip
          assert_equal "tree", git(remote, "cat-file", "-t", "#{ref}^{}").strip
        end
        assert_equal git(remote, "rev-parse", "refs/riptide/runs/unit/branches/main").strip, git(remote, "show", "refs/riptide/stamps/unit/branches/main:runs").strip
      end
    end

    def test_a_branch_with_nothing_to_publish_gets_no_unit
      with_remote do |remote, clone|
        root = clone.("a")
        commit_file(root, "README", "x\n", push: true)
        store_for(root).publish(build: MAIN)

        assert_empty refs(remote)
      end
    end

    def test_a_failure_stays_open_until_a_later_build_passes_it
      with_remote do |_, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n", push: true)
        store = store_for(root)
        store.append_run(run_for(sha, passed: false))
        store.publish(build: MAIN)
        fetch(root, MAIN)
        assert_equal 1, marks(store_for(root), TEST).size

        store = store_for(root)
        store.append_run(run_for(sha, at: 2.0))
        store.publish(build: MAIN)
        fetch(root, MAIN)
        assert_empty marks(store_for(root), TEST)
        assert_equal [2.0], ats(store_for(root), TEST)
      end
    end

    # Build A fetched before build B failed the test, so A's pass says
    # nothing about B's failure.
    def test_a_pass_never_closes_a_failure_it_didnt_see
      with_remote do |_, clone|
        a = clone.("a")
        sha = commit_file(a, "app/widget.rb", "x = 1\n", push: true)
        seed = store_for(a)
        seed.append_run(run_for(sha))
        seed.publish(build: MAIN)
        fetch(a, MAIN)
        b = clone.("b")
        fetch(b, MAIN)
        failing = store_for(b)
        failing.append_run(run_for(sha, at: 2.0, passed: false))
        failing.publish(build: MAIN)
        passing = store_for(a)
        passing.append_run(run_for(sha, at: 3.0))
        passing.publish(build: MAIN)

        c = clone.("c")
        fetch(c, MAIN)
        assert_equal 1, marks(store_for(c), TEST).size
      end
    end

    def test_a_test_that_started_and_never_finished_is_a_failure
      with_remote do |_, clone|
        root = clone.("a")
        commit_file(root, "README", "x\n", push: true)
        store = store_for(root)
        store.append_start(TEST)
        store.publish(build: MAIN)
        fetch(root, MAIN)

        assert_equal 1, marks(store_for(root), TEST).size
      end
    end

    def test_a_skipped_test_neither_opens_nor_closes_a_failure
      with_remote do |_, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n", push: true)
        store = store_for(root)
        store.append_run(run_for(sha, passed: false))
        store.publish(build: MAIN)
        fetch(root, MAIN)
        store = store_for(root)
        store.append_start(TEST)
        store.append_run(Store::Run.new(test: TEST, at: 2.0, passed: nil))
        store.publish(build: MAIN)
        fetch(root, MAIN)

        assert_equal 1, marks(store_for(root), TEST).size
      end
    end

    def test_each_test_keeps_only_its_newest_retained_runs
      with_remote do |_, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n", push: true)
        store = store_for(root, retained_runs: 2)
        [1.0, 2.0, 3.0].each { |at| store.append_run(run_for(sha, at: at, methods: ["Widget#m#{at}"])) }
        store.publish(build: MAIN)
        fetch(root, MAIN)

        assert_equal [3.0, 2.0], ats(store_for(root), TEST)
      end
    end

    def test_a_test_whose_file_is_gone_is_dropped
      with_remote do |_, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n", push: true)
        commit_file(root, "test/old_test.rb", "old\n", push: true)
        store = store_for(root)
        store.append_run(run_for(sha, test: %w[OldTest test_old], file: "test/old_test.rb"))
        store.append_run(run_for(sha, file: "app/widget.rb"))
        store.publish(build: MAIN)
        system("git", "-C", root, "rm", "-q", "test/old_test.rb", exception: true)
        system("git", "-C", root, "commit", "-qm", "rm", exception: true)
        fetch(root, MAIN)
        store = store_for(root)
        store.append_run(run_for(sha, at: 2.0, file: "app/widget.rb", methods: ["Widget#b"]))
        store.publish(build: MAIN)
        fetch(root, MAIN)

        assert_empty ats(store_for(root), %w[OldTest test_old])
        assert_equal [2.0, 1.0], ats(store_for(root), TEST)
      end
    end

    def test_ids_stay_put_so_a_publish_rewrites_only_what_changed
      with_remote do |remote, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n")
        other = commit_file(root, "app/other.rb", "y = 1\n", push: true)
        store = store_for(root)
        store.append_run(run_for(sha))
        store.publish(build: MAIN)
        first = git(remote, "rev-parse", "refs/riptide/runs/unit/branches/main^{}").strip
        fetch(root, MAIN)
        store = store_for(root)
        store.append_run(Store::Run.new(test: OTHER, at: 2.0, passed: true, sets: [], inputs: { "app/other.rb" => { "sha" => other } }))
        store.publish(build: MAIN)
        second = git(remote, "rev-parse", "refs/riptide/runs/unit/branches/main^{}").strip

        changed = git(remote, "diff-tree", "-r", "--name-only", first, second).lines.map(&:strip)
        refute_includes changed, "files/#{sha[0, 2]}" unless sha[0, 2] == other[0, 2]
        assert_includes changed, "files/#{other[0, 2]}"
      end
    end

    # The loser fetched before the winner published, so its push loses
    # the race, and it folds again onto what the winner wrote.
    def test_a_writer_that_lost_the_race_retries_and_keeps_both
      with_remote do |_, clone|
        a = clone.("a")
        sha = commit_file(a, "app/widget.rb", "x = 1\n", push: true)
        b = clone.("b")
        winner = store_for(a)
        winner.append_run(run_for(sha, at: 1.0, test: %w[WinnerTest test_w]))
        winner.publish(build: MAIN)
        loser = store_for(b)
        loser.append_run(run_for(sha, at: 2.0, test: %w[LateTest test_l]))
        loser.publish(build: MAIN)

        c = clone.("c")
        fetch(c, MAIN)
        reader = store_for(c)
        assert_equal [1.0], ats(reader, %w[WinnerTest test_w])
        assert_equal [2.0], ats(reader, %w[LateTest test_l])
      end
    end

    # A version that was never committed, like a local key, can't leak
    # through the unit.
    def test_a_version_that_was_never_committed_is_not_pinned
      with_remote do |_, clone|
        root = clone.("a")
        commit_file(root, "README", "x\n", push: true)
        File.write(File.join(root, "draft.rb"), "draft = true\n")
        sha = Diff.blob_sha(File.join(root, "draft.rb"))
        store = store_for(root)
        store.append_run(Store::Run.new(test: TEST, at: 1.0, passed: true, sets: [], inputs: { "draft.rb" => { "sha" => sha } }))
        store.publish(build: MAIN)

        b = clone.("b")
        fetch(b, MAIN)
        assert_nil store_for(b).read_blob(sha)
      end
    end

    # A PR from main into stable is keyed by its number, so it can't touch
    # main's unit.
    def test_prs_are_keyed_by_number_and_branches_by_name
      with_remote do |remote, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n", push: true)
        system("git", "-C", root, "push", "-q", "origin", "main:stable", exception: true, err: File::NULL)
        fetch(root, pr(7, target: "stable"))
        store = store_for(root)
        store.append_run(run_for(sha))
        store.publish(build: pr(7, target: "stable"))
        store = store_for(root)
        store.append_run(run_for(sha))
        store.publish(build: Store::Build.branch("feature/a", upstream: "main"))

        assert_equal %w[refs/riptide/runs/unit/branches/feature%2Fa refs/riptide/runs/unit/prs/7 refs/riptide/stamps/unit/branches/feature%2Fa
                        refs/riptide/stamps/unit/prs/7], refs(remote).sort
      end
    end

    # A PR into main: a branch off main changing the widget, built and
    # published like CI would.
    def publish_pr(root, name = "feature", number: 1, content: "x = 2\n", passed: true, suites: ["unit"])
      branch(root, name)
      sha = commit_file(root, "app/widget.rb", content, push: true)
      fetch(root, pr(number))
      suites.each do |suite|
        store = store_for(root, suite: suite)
        store.append_run(run_for(sha, passed: passed))
        store.publish(build: pr(number))
      end
      sha
    end

    def merge(root, style, name = "feature")
      checkout(root, "main")
      case style
      when "squash" then system("git", "-C", root, "merge", "-q", "--squash", name, exception: true) && system("git", "-C", root, "commit", "-qm", "squash", exception: true)
      when "merge" then system("git", "-C", root, "merge", "-q", "--no-ff", "-m", "merge", name, exception: true)
      when "rebase" then system("git", "-C", root, "cherry-pick", name, exception: true, out: File::NULL)
      end
    end

    def harvest_main(root, suites: ["unit"])
      checkout(root, "main")
      push_main(root)
      fetch(root, MAIN)
      suites.map do |suite|
        store = store_for(root, suite: suite)
        store.append_run(run_for("s1", test: OTHER))
        store.publish(build: MAIN)
      end
    end

    PR_UNIT = %w[refs/riptide/runs/unit/prs/1 refs/riptide/stamps/unit/prs/1].freeze

    def test_a_pr_s_stamp_holds_its_landing_record
      with_remote do |remote, clone|
        root = clone.("a")
        commit_file(root, "README", "x\n", push: true)
        publish_pr(root)

        stamp = "refs/riptide/stamps/unit/prs/1"
        assert_equal "main", git(remote, "show", "#{stamp}:landing/target")
        assert_equal "x = 2\n", git(remote, "show", "#{stamp}:landing/tested/app/widget.rb")
        assert_empty git(remote, "ls-tree", "-r", "#{stamp}:landing/base"), "the file is new"
      end
    end

    %w[squash merge rebase].each do |style|
      define_method(:"test_a_pr_that_landed_with_a_#{style}_merge_is_harvested_and_deleted") do
        with_remote do |remote, clone|
          root = clone.("a")
          commit_file(root, "README", "x\n", push: true)
          publish_pr(root)
          merge(root, style)
          commit_file(root, "app/other.rb", "y = 1\n")
          published = harvest_main(root).first

          assert_equal 1, published.harvested
          assert_equal PR_UNIT.sort, published.deleted.sort
          assert_empty refs(remote) & PR_UNIT
          fetch(root, MAIN)
          assert_equal [1.0], ats(store_for(root), TEST)
        end
      end
    end

    # main changed the same file before the PR merged, so the merged file
    # is neither side's.
    def test_a_pr_lands_when_main_also_changed_its_file
      with_remote do |_, clone|
        root = clone.("a")
        commit_file(root, "app/widget.rb", "a = 1\n\n\n\n\nb = 1\n", push: true)
        publish_pr(root, content: "a = 2\n\n\n\n\nb = 1\n")
        checkout(root, "main")
        commit_file(root, "app/widget.rb", "a = 1\n\n\n\n\nb = 2\n")
        merge(root, "merge")

        assert_equal PR_UNIT.sort, harvest_main(root).first.deleted.sort
      end
    end

    def test_an_empty_pr_counts_as_landed
      with_remote do |_, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n", push: true)
        branch(root, "feature")
        system("git", "-C", root, "push", "-q", "origin", "feature", exception: true, err: File::NULL)
        fetch(root, pr)
        store = store_for(root)
        store.append_run(run_for(sha))
        store.publish(build: pr)

        assert_equal PR_UNIT.sort, harvest_main(root).first.deleted.sort
      end
    end

    def test_a_pr_that_renamed_and_deleted_files_lands
      with_remote do |_, clone|
        root = clone.("a")
        commit_file(root, "app/old.rb", "old = 1\n")
        commit_file(root, "app/gone.rb", "gone = 1\n", push: true)
        branch(root, "feature")
        system("git", "-C", root, "mv", "app/old.rb", "app/new.rb", exception: true)
        system("git", "-C", root, "rm", "-q", "app/gone.rb", exception: true)
        system("git", "-C", root, "commit", "-qm", "rename", exception: true)
        system("git", "-C", root, "push", "-q", "origin", "feature", exception: true, err: File::NULL)
        fetch(root, pr)
        store = store_for(root)
        store.append_run(run_for("s1"))
        store.publish(build: pr)
        merge(root, "squash")

        assert_equal PR_UNIT.sort, harvest_main(root).first.deleted.sort
      end
    end

    # If the landing check itself breaks, main harvests nothing, and every
    # PR into main counts its open failures, so main runs more.
    def test_a_landing_check_that_fails_counts_every_targeting_pr_s_failures
      with_remote do |remote, clone|
        root = clone.("a")
        commit_file(root, "README", "x\n", push: true)
        publish_pr(root, passed: false)
        checkout(root, "main")
        push_main(root)
        breaking = Module.new { def landed?(_) = raise(ArgumentError, "broken") }
        harvest = Store::Harvest.new(Git.new(root), MAIN, "origin").extend(breaking)
        Store::Harvest.stub(:new, harvest) { capture_io { fetch(root, MAIN) } }

        assert_equal 1, marks(store_for(root), TEST).size
        assert_empty refs(root).grep(%r{\Arefs/riptide/runs/unit/prs/})
        assert_empty PR_UNIT - refs(remote)
      end
    end

    def test_stable_harvests_a_pr_into_stable_and_reads_main
      with_remote do |remote, clone|
        root = clone.("a")
        commit_file(root, "README", "x\n", push: true)
        system("git", "-C", root, "push", "-q", "origin", "main:stable", exception: true, err: File::NULL)
        main = store_for(root)
        main.append_run(run_for("s1", test: OTHER))
        main.publish(build: MAIN)
        system("git", "-C", root, "checkout", "-q", "-b", "stable", "origin/stable", exception: true)
        branch(root, "hotfix", from: "stable")
        sha = commit_file(root, "app/widget.rb", "x = 2\n", push: true)
        fetch(root, pr(9, target: "stable"))
        hotfix = store_for(root)
        hotfix.append_run(run_for(sha))
        hotfix.publish(build: pr(9, target: "stable"))
        checkout(root, "stable")
        system("git", "-C", root, "merge", "-q", "--no-ff", "-m", "merge", "hotfix", exception: true)
        system("git", "-C", root, "push", "-q", "origin", "stable", exception: true, err: File::NULL)
        stable_build = Store::Build.branch("stable", upstream: "main", harvest: true)
        fetch(root, stable_build)
        reader = store_for(root)
        assert_equal [1.0], ats(reader, OTHER), "stable reads main's runs"
        published = reader.publish(build: stable_build)

        assert_equal 1, published.harvested
        assert_empty refs(remote).grep(%r{prs/9})
      end
    end

    # main never downloads an unmerged PR's runs or counts its failures.
    def test_main_doesn_t_read_a_pr_that_hasn_t_landed
      with_remote do |remote, clone|
        root = clone.("a")
        commit_file(root, "README", "x\n", push: true)
        publish_pr(root, passed: false)
        checkout(root, "main")
        fetch(root, MAIN)

        assert_empty refs(root)
        assert_empty harvest_main(root).first.deleted
        assert_empty PR_UNIT - refs(remote)
      end
    end

    def test_a_landed_pr_s_open_failures_carry_into_main
      with_remote do |_, clone|
        root = clone.("a")
        commit_file(root, "README", "x\n", push: true)
        publish_pr(root, passed: false)
        merge(root, "merge")
        harvest_main(root)
        fetch(root, MAIN)

        assert_equal 1, marks(store_for(root), TEST).size
      end
    end

    # A conflict resolved in main's favor leaves the PR's change out of
    # main, so it waits to age out.
    def test_a_merge_that_changed_the_pr_s_work_stays_until_it_ages_out
      with_remote do |remote, clone|
        root = clone.("a")
        commit_file(root, "app/widget.rb", "a = 1\n", push: true)
        publish_pr(root, content: "a = 2\n")
        checkout(root, "main")
        commit_file(root, "app/widget.rb", "a = 3\n")
        system("git", "-C", root, "merge", "-q", "-s", "ours", "-m", "merge", "feature", exception: true)

        assert_empty harvest_main(root).first.deleted
        assert_empty PR_UNIT - refs(remote)
        Time.stub(:now, Time.now + Store::EXPIRY + 60) { fetch(root, MAIN) }
        assert_empty refs(remote) & PR_UNIT
      end
    end

    # main's and stable's units are only ever written by their own builds,
    # and nothing but ageing deletes them.
    def test_main_never_deletes_another_branch_s_unit
      with_remote do |remote, clone|
        root = clone.("a")
        commit_file(root, "README", "x\n", push: true)
        store = store_for(root)
        store.append_run(run_for("s1"))
        store.publish(build: Store::Build.branch("stable", upstream: "main", harvest: true))
        harvest_main(root)

        assert_includes refs(remote), "refs/riptide/runs/unit/branches/stable"
        assert_empty refs(root) & ["refs/riptide/stamps/unit/branches/stable"], "main doesn't read stable's failures"
      end
    end

    # The PR published again after main fetched, so main's delete is about
    # runs the PR has moved past.
    def test_a_pr_republished_after_the_harvesting_build_fetched_stays
      with_remote do |remote, clone|
        root = clone.("a")
        commit_file(root, "README", "x\n", push: true)
        publish_pr(root)
        merge(root, "merge")
        push_main(root)
        fetch(root, MAIN)
        other = clone.("b")
        checkout(other, "feature")
        fetch(other, pr)
        republish = store_for(other)
        republish.append_run(run_for("s2", at: 5.0))
        republish.publish(build: pr)
        main = store_for(root)
        main.append_run(run_for("s1", test: OTHER))

        assert_empty main.publish(build: MAIN).deleted
        assert_empty PR_UNIT - refs(remote)
      end
    end

    def test_one_fetch_brings_every_suite_and_clears_leftovers
      with_remote do |_, clone|
        a = clone.("a")
        sha = commit_file(a, "app/widget.rb", "x = 1\n", push: true)
        %w[unit models].each do |suite|
          writer = store_for(a, suite: suite)
          writer.append_run(run_for(sha))
          writer.publish(build: MAIN)
        end
        b = clone.("b")
        system("git", "-C", b, "update-ref", "refs/riptide/unit", git(b, "rev-parse", "HEAD").strip, exception: true)
        fetch(b, pr)

        assert_equal %w[refs/riptide/runs/models/branches/main refs/riptide/runs/unit/branches/main refs/riptide/stamps/models/branches/main
                        refs/riptide/stamps/unit/branches/main refs/riptide/target], refs(b).sort
        assert_equal [[TEST]], store_for(b, suite: "models").indexes.map { |index| index.runs.keys }.reject(&:empty?)
      end
    end

    def test_publishing_needs_no_git_identity
      with_remote do |remote, clone|
        root = clone.("a")
        commit_file(root, "README", "x\n", push: true)
        system("git", "-C", root, "config", "--unset", "user.email", exception: true)
        system("git", "-C", root, "config", "--unset", "user.name", exception: true)
        store = store_for(root)
        store.append_run(run_for("s1"))
        store.publish(build: MAIN)

        assert_match(/\Atagger riptide /, git(remote, "cat-file", "tag", "refs/riptide/runs/unit/branches/main").lines.grep(/tagger/).first)
      end
    end

    # A unit written by another version of riptide still brings its open
    # failures, and none of its runs.
    def test_a_unit_in_another_format_counts_only_its_failures
      with_remote do |_, clone|
        root = clone.("a")
        sha = commit_file(root, "app/widget.rb", "x = 1\n", push: true)
        store = store_for(root)
        store.append_run(run_for(sha))
        store.append_run(run_for(sha, test: OTHER, passed: false))
        store.publish(build: MAIN)
        fetch(root, MAIN)
        stamp = "refs/riptide/stamps/unit/branches/main"
        old = IO.popen(["git", "-C", root, "hash-object", "-w", "--stdin"], "r+") { |io| io.write("1"); io.close_write; io.read.strip }
        entries = git(root, "ls-tree", "#{stamp}^{tree}").sub(/^(100644 blob )\h+(\tformat)$/) { "#{$1}#{old}#{$2}" }
        tree = IO.popen(["git", "-C", root, "mktree"], "r+") { |io| io.write(entries); io.close_write; io.read.strip }
        system("git", "-C", root, "update-ref", stamp, tree, exception: true)
        reader = store_for(root)

        assert_empty ats(reader, TEST)
        assert_equal 1, marks(reader, OTHER).size
      end
    end

    def test_a_truncated_log_line_is_skipped
      with_remote do |_, clone|
        root = clone.("a")
        store = store_for(root)
        store.append_run(run_for("s1"))
        File.open(Dir.glob(File.join(root, "tmp/riptide/unit/log-*.jsonl")).first, "a") { |f| f.write('{"type":"run","te') }

        assert_equal [1.0], ats(store_for(root), TEST)
      end
    end

    def test_forked_processes_each_write_their_own_log
      with_remote do |_, clone|
        root = clone.("a")
        store = store_for(root)
        store.append_run(run_for("s1"))
        pids = 2.times.map do |i|
          fork do
            store.append_run(run_for("s1", test: ["ForkTest", "test_#{i}"]))
            exit!(0)
          end
        end
        pids.each { |pid| Process.wait(pid) }

        assert_equal 3, Dir.glob(File.join(root, "tmp/riptide/unit/log-*.jsonl")).size
      end
    end
  end
end
