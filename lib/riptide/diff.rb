# frozen_string_literal: true

require "open3"
require "digest"
require "tempfile"

module Riptide
  module Diff
    Hunk = Struct.new(:old_start, :old_count, :new_start, :new_count) do
      # Lines this hunk removes or rewrites in the old file.
      def old_lines = (old_start...(old_start + old_count))

      # Lines this hunk adds or rewrites in the new file.
      def new_lines = (new_start...(new_start + new_count))
    end

    HUNK_HEADER = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

    module_function

    # Git's blob hash of a file's content, the same as `git hash-object`.
    def blob_sha(path)
      content = File.binread(path)
      Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")
    end

    # Zero-context hunks turning +old_text+ into +new_text+, compared as bytes.
    def hunks(old_text, new_text)
      return [] if old_text.b == new_text.b

      Tempfile.create("riptide-old", binmode: true) do |old_file|
        Tempfile.create("riptide-new", binmode: true) do |new_file|
          old_file.write(old_text)
          new_file.write(new_text)
          old_file.flush
          new_file.flush
          out, err, status = Open3.capture3("git", "diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--unified=0", old_file.path, new_file.path)
          # --no-index exits 1 when the files differ.
          raise Error, "git diff --no-index failed: #{err.strip}" unless [0, 1].include?(status.exitstatus)

          parse(out.b)
        end
      end
    end

    def parse(diff_text)
      diff_text.scan(HUNK_HEADER).map do |old_start, old_count, new_start, new_count|
        Hunk.new(old_start.to_i, (old_count || "1").to_i, new_start.to_i, (new_count || "1").to_i)
      end
    end
  end
end
