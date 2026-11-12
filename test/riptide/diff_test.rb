# frozen_string_literal: true

require "test_helper"

module Riptide
  class DiffTest < Minitest::Test
    include GitFixture

    def test_blob_sha_matches_git_hash_object
      in_repo do |root|
        File.write("a.rb", "puts 1\n")

        assert_equal `git hash-object a.rb`.strip, Diff.blob_sha(File.join(root, "a.rb"))
      end
    end

    def test_hunks_describe_rewrites_insertions_and_deletions
      hunks = Diff.hunks("a\nb\nc\nd\n", "a\nB\nc\nnew\nd\n")

      assert_equal [Diff::Hunk.new(2, 1, 2, 1), Diff::Hunk.new(3, 0, 4, 1)], hunks
    end

    def test_hunks_is_empty_for_identical_text
      assert_empty Diff.hunks("same\n", "same\n")
    end

    # Merging the two hunks would make the lines between them look rewritten.
    def test_hunks_ignore_git_config_and_attributes_from_anywhere
      Dir.mktmpdir do |home|
        merge = "[diff]\n\tinterHunkContext = 5\n"
        File.write(File.join(home, "system"), merge)
        File.write(File.join(home, ".gitconfig"), merge)
        FileUtils.mkdir_p(File.join(home, ".config/git"))
        File.write(File.join(home, ".config/git/attributes"), "* -diff\n")
        planted = File.join(home, "planted")
        system("git", "init", "-q", planted, exception: true)
        File.write(File.join(planted, ".git/config"), merge, mode: "a")

        from_everywhere = {
          "HOME" => home, "XDG_CONFIG_HOME" => File.join(home, ".config"), "GIT_CONFIG_SYSTEM" => File.join(home, "system"),
          "TMPDIR" => planted, "GIT_DIR" => File.join(planted, ".git"), "GIT_CONFIG_PARAMETERS" => "'diff.interhunkcontext'='5'",
          "GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "diff.interHunkContext", "GIT_CONFIG_VALUE_0" => "5"
        }
        with_env(from_everywhere) do
          assert_equal [Diff::Hunk.new(1, 1, 1, 1), Diff::Hunk.new(5, 1, 5, 1)], Diff.hunks("a\nb\nc\nd\ne\n", "A\nb\nc\nd\nE\n")
        end
      end
    end

    private

    def with_env(values)
      saved = values.keys.to_h { |name| [name, ENV[name]] }
      ENV.update(values)
      yield
    ensure
      ENV.update(saved)
    end
  end
end
