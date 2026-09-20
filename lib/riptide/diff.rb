# frozen_string_literal: true

require "open3"
require "digest"

module Riptide
  module Diff
    Hunk = Struct.new(:old_start, :old_count, :new_start, :new_count) do
      def offset
        new_count - old_count
      end
    end

    HUNK_HEADER = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

    module_function

    # Raw unified, zero-context diff between two git objects: blobs, refs, or
    # a range like "base...HEAD". Callers that just need structured hunks
    # should go through +hunks+ instead of parsing this themselves.
    def unified(from, to)
      out, err, status = Open3.capture3("git", "diff", "--no-color", "--unified=0", from, to)
      raise Error, "git diff #{from} #{to} failed: #{err.strip}" unless status.success?

      out
    end

    # Files that differ between +base+ and +head+, with rename detection
    # enabled: [{ path:, status: :added|:modified|:deleted|:renamed, old_path: }, ...].
    # Rename detection is similarity-based, not guaranteed. A rename bundled
    # with a large enough edit on a small enough file can fall back to a
    # plain delete plus add instead of a single :renamed entry.
    def changed_files(base, head)
      out, err, status = Open3.capture3("git", "diff", "--name-status", "-M", base, head)
      raise Error, "git diff --name-status #{base} #{head} failed: #{err.strip}" unless status.success?

      out.each_line.map do |line|
        code, *paths = line.chomp.split("\t")

        case code[0]
        when "A" then { path: paths[0], status: :added }
        when "D" then { path: paths[0], status: :deleted }
        when "R" then { path: paths[1], status: :renamed, old_path: paths[0] }
        else { path: paths[0], status: :modified }
        end
      end
    end

    # The commit where +ref+ and HEAD diverged, git's definition of a
    # sensible diff base for a feature branch.
    def merge_base(ref)
      out, err, status = Open3.capture3("git", "merge-base", "HEAD", ref)
      raise Error, "git merge-base HEAD #{ref} failed: #{err.strip}" unless status.success?

      out.strip
    end

    # The git blob hash of +path+'s current on-disk content, independent of
    # whether it's staged or committed. Comparable to blob hashes recorded
    # earlier for the same path, to tell whether it has changed at all since
    # Store last saw it.
    #
    # Computed in-process (git's own blob-hash algorithm: sha1("blob
    # <size>\0<content>"), verified directly against `git hash-object`'s
    # real output) rather than shelling out. This runs once per covered
    # file per test, on riptide's own critical path, and a subprocess
    # spawn (~20ms+) measured roughly 100x slower here than the actual
    # hashing.
    def blob_sha(path)
      raise Error, "git hash-object #{path} failed: No such file" unless File.exist?(path)

      content = File.binread(path)
      Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}")
    end

    # Parses `@@ -a,b +c,d @@` headers out of unified diff text, ordered by
    # position in the old file.
    def hunks(diff_text)
      diff_text.scan(HUNK_HEADER).map do |old_start, old_count, new_start, new_count|
        Hunk.new(old_start.to_i, (old_count || "1").to_i, new_start.to_i, (new_count || "1").to_i)
      end.sort_by(&:old_start)
    end

    # Translates an inclusive [start, finish] line range (old file numbering)
    # through +hunks+ into new-file numbering. Returns the translated
    # [start, finish] if every hunk fell entirely outside the range, a pure
    # shift caused by unrelated edits elsewhere in the file. Returns nil if
    # any hunk overlaps the range, meaning the covered code itself may have
    # changed and the caller should treat this as a hit rather than trust
    # a remapped range.
    #
    # A pure insertion (old_count 0) counts as overlapping when it lands
    # inside or right at the edge of the range: new code inserted inside a
    # covered method is part of what the test now exercises, and the safe
    # default is to prefer a false positive over silently trusting a stale
    # range.
    def translate_range(hunks, start, finish)
      offset = 0

      hunks.each do |hunk|
        if hunk.old_count.zero?
          return nil if hunk.old_start >= start && hunk.old_start <= finish

          offset += hunk.offset if hunk.old_start < start
        else
          hunk_end = hunk.old_start + hunk.old_count - 1
          return nil if hunk.old_start <= finish && hunk_end >= start

          offset += hunk.offset if hunk_end < start
        end
      end

      [start + offset, finish + offset]
    end
  end
end
