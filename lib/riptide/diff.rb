# frozen_string_literal: true

require "digest"
require "tmpdir"

module Riptide
  module Diff
    Hunk = Struct.new(:old_start, :old_count, :new_start, :new_count) do
      # Lines this hunk removes or rewrites in the old file.
      def old_lines = (old_start...(old_start + old_count))

      # Lines this hunk adds or rewrites in the new file.
      def new_lines = (new_start...(new_start + new_count))
    end

    HUNK_HEADER = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

    # No git config from anywhere reaches the diff, so a setting like
    # diff.interHunkContext can't merge hunks on one machine and not another.
    ISOLATED = { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_COUNT" => nil,
                 "GIT_CONFIG_PARAMETERS" => nil, "GIT_DIR" => nil }.freeze

    module_function

    # Git's blob hash of a file's content, the same as `git hash-object`.
    def blob_sha(path)
      content = File.binread(path)
      Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")
    end

    # Zero-context hunks turning +old_text+ into +new_text+, compared as bytes.
    def hunks(old_text, new_text)
      return [] if old_text.b == new_text.b

      # A directory riptide just made, with git stopped from looking above it
      # for a repository.
      Dir.mktmpdir("riptide-diff") do |dir|
        File.binwrite(File.join(dir, "old"), old_text)
        File.binwrite(File.join(dir, "new"), new_text)
        env = ISOLATED.merge("GIT_CEILING_DIRECTORIES" => File.dirname(dir))
        # --text keeps a global attributes file from calling it binary.
        # --no-index exits 1 when the files differ.
        out, = Git.new(dir).run("diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--text", "--unified=0", "old", "new", env: env, allow: [0, 1])
        parse(out.b)
      end
    end

    def parse(diff_text)
      diff_text.scan(HUNK_HEADER).map do |old_start, old_count, new_start, new_count|
        Hunk.new(old_start.to_i, (old_count || "1").to_i, new_start.to_i, (new_count || "1").to_i)
      end
    end
  end
end
