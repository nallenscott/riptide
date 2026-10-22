# frozen_string_literal: true

require "open3"
require "set"

module Riptide
  # The git plumbing the store needs, run against one repository. Objects
  # are read through one long-lived `git cat-file --batch`.
  class Git
    def initialize(root)
      @root = root
    end

    def run(*args, input: nil, env: {}, allow: [0])
      out, err, status = Open3.capture3(env, "git", "-C", @root, *args, stdin_data: input)
      raise Error, "git #{args.first} failed: #{err.strip}" unless allow.include?(status.exitstatus)

      [out, status.exitstatus]
    end

    def output(*args, **options) = run(*args, **options).first

    # A blob's content, or nil when the repository doesn't have it.
    def read(sha)
      batch_in, batch_out = batch
      batch_in.puts(sha)
      header = batch_out.gets
      return nil if header.nil? || header.end_with?("missing\n")

      size = header.split.last.to_i
      content = batch_out.read(size)
      batch_out.read(1)
      content
    end

    # Every path git tracks or would track: committed, staged, or untracked
    # and not ignored.
    def files
      output("ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0").to_set
    end

    def write_blob(content) = output("hash-object", "-w", "--stdin", input: content).strip

    # The commit a ref points at, or nil.
    def resolve(ref)
      out, status = run("rev-parse", "--verify", "--quiet", "#{ref}^{commit}", allow: [0, 1, 128])
      status.zero? ? out.strip : nil
    end

    # { path => blob sha } for every file in a commit's tree.
    def tree(commit)
      return {} unless commit

      output("ls-tree", "-r", "-z", commit).split("\0").to_h do |entry|
        info, path = entry.split("\t", 2)
        [path, info.split.last]
      end
    end

    # A tree holding +files+ ({ path => blob sha }), built in a throwaway
    # index so the working repository's index is never touched.
    def write_tree(files)
      Tempfile.create("riptide-index") do |index|
        File.delete(index.path)
        env = { "GIT_INDEX_FILE" => index.path }
        listing = files.sort.map { |path, sha| "100644 #{sha}\t#{path}\n" }.join
        run("update-index", "--add", "--index-info", input: listing, env: env)
        output("write-tree", env: env).strip
      end
    end

    private

    def batch
      @batch ||= begin
        stdin, stdout, = Open3.popen2("git", "-C", @root, "cat-file", "--batch")
        [stdin, stdout]
      end
    end
  end
end
