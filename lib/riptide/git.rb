# frozen_string_literal: true

require "digest"
require "open3"
require "set"
require "tempfile"

module Riptide
  # The git plumbing the store needs, run against one repository. Objects
  # are read through one long-lived `git cat-file --batch`.
  #
  # Every command runs in its own process group under a deadline, so a
  # stalled network call can't hold up a build: the group gets TERM, which
  # makes git drop its locks, then KILL. Nothing prompts, nothing starts a
  # gc while tests read .git, and an aborting git leaves no core file.
  class Git
    DEADLINE = 120
    GRACE = 5
    CONFIG = %w[-c gc.auto=0 -c maintenance.auto=false].freeze
    ENV_DEFAULTS = { "GIT_TERMINAL_PROMPT" => "0", "GIT_SSH_COMMAND" => "ssh -o BatchMode=yes -o ConnectTimeout=15",
                     "GIT_HTTP_LOW_SPEED_LIMIT" => "1000", "GIT_HTTP_LOW_SPEED_TIME" => "30" }.freeze

    def initialize(root)
      @root = root
    end

    # [stdout, exit status], where a signal exit is nil. Raises unless the
    # status is in +allow+.
    def run(*args, input: nil, env: {}, allow: [0], deadline: DEADLINE)
      out, err, status = spawn(args, input, env, deadline)
      raise Error, "git #{args.first} failed: #{err.strip}" unless allow.include?(status)

      [out, status]
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

    # Writes each of +blobs+ ({ path => content }) in one fast-import and
    # returns { path => blob sha }. Ones already in +known+ aren't written
    # again.
    def write_blobs(blobs, known: Set.new)
      shas = blobs.transform_values { |content| Digest::SHA1.hexdigest("blob #{content.bytesize}\0#{content}") }
      fresh = blobs.reject { |path, _| known.include?(shas[path]) }.values.uniq
      unless fresh.empty?
        stream = fresh.map { |content| "blob\ndata #{content.bytesize}\n#{content}\n" }.join << "done\n"
        run("fast-import", "--quiet", "--done", input: stream)
      end
      shas
    end

    # { ref => object } for this repository's refs under +prefix+.
    def refs(prefix)
      output("for-each-ref", "--format=%(refname) %(objectname)", prefix).lines.to_h { |line| line.split.first(2) }
    end

    # Deletes +names+ in one transaction.
    def delete_refs(names)
      run("update-ref", "--stdin", input: names.map { |name| "delete #{name}\n" }.join) unless names.empty?
    end

    def merge_base(one, other)
      out, status = run("merge-base", one, other, allow: [0, 1, 128])
      status.zero? ? out.strip : nil
    end

    # The tree from merging +theirs+ into +ours+ as if +base+ were their
    # common ancestor, or nil when it conflicts. All three can be trees.
    def merge_tree(base, ours, theirs)
      out, status = run("merge-tree", "--write-tree", "--no-messages", "--merge-base=#{base}", ours, theirs, allow: [0, 1])
      status.zero? ? out.lines.first.strip : nil
    end

    # The object +rev+ names, or nil.
    def resolve(rev)
      out, status = run("rev-parse", "--verify", "--quiet", rev, allow: [0, 1, 128])
      status.zero? ? out.strip : nil
    end

    # { path => [mode, object] } for every file under +tree+, recursively.
    # With +paths+, only those, matched literally.
    def entries(tree, paths: nil)
      return {} if tree.nil? || paths&.empty?

      args = ["ls-tree", "-r", "-z", tree]
      args += ["--", *paths] if paths
      output(*args, env: { "GIT_LITERAL_PATHSPECS" => "1" }).split("\0").to_h do |entry|
        info, path = entry.split("\t", 2)
        mode, _, object = info.split
        [path, [mode, object]]
      end
    end

    # { path => blob sha } for every file in a tree.
    def tree(object) = entries(object).transform_values(&:last)

    # A tree holding +files+ ({ path => sha } or { path => [mode, sha] }),
    # built in a throwaway index so the repository's own is never touched.
    def write_tree(files)
      Tempfile.create("riptide-index") do |index|
        File.delete(index.path)
        env = { "GIT_INDEX_FILE" => index.path }
        listing = files.sort.map do |path, entry|
          mode, sha = entry.is_a?(Array) ? entry : ["100644", entry]
          "#{mode} #{sha}\t#{path}\0"
        end.join
        run("update-index", "-z", "--add", "--index-info", input: listing, env: env) unless listing.empty?
        output("write-tree", "--missing-ok", env: env).strip
      end
    end

    # An annotated tag wrapping +tree+, dated now by riptide's own clock.
    def tag_tree(tree, name)
      content = "object #{tree}\ntype tree\ntag #{name}\ntagger riptide <riptide@users.noreply.github.com> #{Time.now.to_i} +0000\n\n#{name}\n"
      output("mktag", input: content).strip
    end

    private

    def spawn(args, input, env, deadline)
      Open3.popen3(ENV_DEFAULTS.reject { |name, _| ENV.key?(name) }.merge(env), "git", *CONFIG, "-C", @root, *args, pgroup: true, rlimit_core: 0) do |stdin, stdout, stderr, thread|
        writer = Thread.new do
          stdin.write(input) if input
        rescue IOError, SystemCallError
          nil
        ensure
          stdin.close
        end
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        timed_out = thread.join(deadline).nil?
        stop(thread) if timed_out
        writer.join
        status = thread.value
        [out.value, timed_out ? "timed out after #{deadline}s" : err.value, status.exitstatus]
      end
    end

    def stop(thread)
      signal(thread.pid, "TERM")
      signal(thread.pid, "KILL") unless thread.join(GRACE)
      thread.join
    end

    def signal(pid, name)
      Process.kill(name, -pid)
    rescue Errno::ESRCH
      nil
    end

    def batch
      @batch ||= begin
        stdin, stdout, = Open3.popen2("git", "-C", @root, "cat-file", "--batch")
        [stdin, stdout]
      end
    end
  end
end
