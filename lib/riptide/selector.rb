# frozen_string_literal: true

require "set"

module Riptide
  # Decides which tests the working tree can affect, from recorded runs
  # alone. Every recorded input names the exact file version it was
  # recorded against, so there's no diff base: the question for each test
  # is whether anything it depended on differs from what's on disk now.
  # Each recorded version that differs gets analyzed once, and the index
  # says which runs used the parts that changed.
  class Selector
    # The rows of the README's table of what a change selects, plus why a
    # test runs with no change behind it.
    KINDS = {
      code: "Anything inside a method or block",
      constant: "A constant's value",
      declaration: "A declaration",
      override: "A new method that could take over a call",
      table: "A table or its fixtures",
      read: "A file a test read, a directory it listed, or a name it found missing that now exists",
      fallback: "A file in fallback_patterns",
      preloaded: "A file that loaded before riptide started, like the test helper",
      boot: "Top-level code that runs at boot",
      deleted: "A deleted file, or a recorded version git no longer has",
      failed: "A test that failed and hasn't passed since",
      shared: "Tests that share a name",
      unrecorded: "A test with no recorded run"
    }.freeze

    # Where a change reached a test: its own run, which counts the classes
    # it used, its test class's setup, or the process's.
    VIA = { test: "their own runs", class: "their test class's setup", process: "the process's setup" }.freeze

    # Why a run no longer holds, and how the change reached it.
    Cause = Struct.new(:reason, :kind, :via)

    Decision = Struct.new(:mode, :selected, :total, keyword_init: true) do
      # How many tests each kind of change selected, then for each way a
      # change reached them, the reasons behind the most.
      def summary(top: 3)
        header = "#{selected.size}/#{total} tests"
        return "full suite, #{header}: #{selected.first&.dig(:reason)}" if mode == :full && selected.map { |entry| entry[:reason] }.uniq.size == 1

        header = "full suite, #{header}" if mode == :full
        kinds = selected.group_by { |entry| entry[:kind] }.sort_by { |_, entries| -entries.size }
        lines = kinds.map { |kind, entries| "  #{KINDS.fetch(kind)}: #{entries.size}" }
        VIA.each do |via, label|
          reached = selected.select { |entry| entry[:via] == via }
          next if reached.empty?

          causes = reached.group_by { |entry| entry[:reason] }.sort_by { |reason, entries| [-entries.size, reason] }.first(top)
          lines << "  through #{label}: #{reached.size}, most from #{causes.map { |reason, entries| "#{reason} (#{entries.size})" }.join(", ")}"
        end
        ([header] + lines).join("\n")
      end

      def to_h
        { "mode" => mode.to_s, "total" => total,
          "selected" => selected.map do |entry|
            { "test" => entry[:test], "reason" => entry[:reason], "change" => KINDS.fetch(entry[:kind]), "through" => entry[:via] && VIA.fetch(entry[:via]) }.compact
          end }
      end

      def self.full(tests, cause)
        new(mode: :full, total: tests.size, selected: tests.map { |test| { test: test, reason: cause.reason, kind: cause.kind, via: cause.via } })
      end
    end

    # +indexes+ hold the recorded runs and open failures, from every unit
    # the build read and its logs. +pseudo+ returns what a recorded glob,
    # fixture table or name lookup gives now.
    # +fallback+ is the fallback patterns.
    def initialize(indexes:, analyzer:, root:, tests:, pseudo:, fallback: [])
      @indexes = indexes
      @fallback = fallback
      @analyzer = analyzer
      @root = root
      @tests = tests
      @pseudo = pseudo
      @current = {}
      @suite_cause = nil
    end

    # { index => { run id => Cause } } for the runs that don't hold here,
    # once #select has run.
    attr_reader :hits

    def select
      @hits = @indexes.to_h { |index| [index, hits_in(index)] }
      if @suite_cause
        @hits = @indexes.to_h { |index| [index, index.run_ids.to_h { |id| [id, @suite_cause] }] }
        return Decision.full(@tests, @suite_cause) unless @tests.empty?
      end

      selected = @tests.filter_map do |test|
        cause = cause_to_run(test)
        { test: test, reason: cause.reason, kind: cause.kind, via: cause.via } if cause
      end
      full = !@tests.empty? && selected.size == @tests.size
      Decision.new(mode: full ? :full : :selected, selected: selected, total: @tests.size)
    end

    private

    # A test with an open failure runs until a build passes it, since a
    # failure riptide can't trace, like a flaky one, has nothing else to
    # rerun it. Two tests with one name, like specs with the same describe
    # and it text, record runs nobody can tell apart, so they always run.
    # Otherwise a test is skipped when a passing run still holds.
    def cause_to_run(test)
      return Cause.new("failed and hasn't passed since", :failed) if @indexes.any? { |index| index.marks[test]&.any? }
      return Cause.new("shares its name with another test, so their runs can't be told apart", :shared) if shared_names.include?(test)

      runs = @indexes.flat_map { |index| index.runs.fetch(test, []).map { |run| [run, @hits[index][run.id]] } }
      return Cause.new("no recorded run", :unrecorded) if runs.empty?
      return nil if runs.any? { |_, hit| hit.nil? }

      runs.max_by { |run, _| run.at }.last
    end

    # Looks up the runs each recorded version that differs from the tree
    # reaches, and why.
    def hits_in(index)
      hits = {}
      index.manifest.each do |path, versions|
        current = current_sha(path)
        versions.each do |version|
          next if version == current

          changed(index, path, version, current) do |reason, kind, reached|
            reached.each { |id, via| hits[id] ||= Cause.new(reason, kind, via) }
          end
          return hits if @suite_cause
        end
      end
      hits
    end

    # Yields the reason, the kind of change and the runs reached, as { id =>
    # via }, for each part of +version+ that changed. A constant added here
    # can shadow one read elsewhere, so it reaches the runs that recorded
    # this version and read that name in any file. A dynamic read like
    # "*::LIMIT" matches a changed constant of that name.
    def changed(index, path, version, current)
      postings = index.postings(path, version)
      recorded = -> { index.reach(postings["all"]) }
      return yield("#{Env.constant_name(path)} is defined now", :read, recorded.call) if Env.constant?(path)
      return yield("fixture files for #{path.delete_prefix(Env::FIXTURES)} were added or removed", :table, recorded.call) if path.start_with?(Env::FIXTURES)
      return yield("files matching #{path.delete_prefix(Env::GLOB)} were added or removed", fallback?(path.delete_prefix(Env::GLOB)) ? :fallback : :read, recorded.call) if Env.pseudo?(path)
      return yield("#{path} was deleted", :deleted, recorded.call) if current.nil?

      change = @analyzer.change(path, version)
      return yield("#{path} changed, and the recorded version isn't in this repository", :deleted, recorded.call) if change.nil?
      return if change.empty?
      return suite(Cause.new("#{path} changed top-level code", :boot)) if change.suite?
      return yield("#{path} changed as a whole", ruby?(path) ? :code : whole_kind(path), recorded.call) if change.whole?

      runs = nil
      index.changed_holders(path, version, change) do |part, name, ids|
        case part
        when :whole then yield("#{path} changed as a whole", whole_kind(path), index.reach(ids))
        when :constant, :named_constant
          runs ||= recorded.call
          reason = part == :constant ? "#{path} changed #{name}" : "#{path} changed #{name}, which the test may have looked up by name"
          yield(reason, :constant, index.reach(ids).slice(*runs.keys))
        else yield("#{path} changed #{name}", facet_kind(part, change, name), index.reach(ids))
        end
      end
    end

    def facet_kind(facet, change, name)
      case facet
      when "owners" then change.causes.fetch(name)
      when "tables" then :table
      else :code
      end
    end

    # A Ruby file recorded whole loaded before riptide could trace it.
    def whole_kind(path)
      return :fallback if fallback?(path)

      ruby?(path) ? :preloaded : :read
    end

    def ruby?(path) = Layout::RUBY_EXTENSIONS.include?(File.extname(path))

    def fallback?(path)
      @fallback.any? { |pattern| pattern == path || File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
    end

    def shared_names
      @shared_names ||= @tests.tally.filter_map { |test, count| test if count > 1 }.to_set
    end

    def suite(cause)
      @suite_cause ||= cause
    end

    def current_sha(path)
      return @current[path] if @current.key?(path)
      return @current[path] = @pseudo.call(path) if Env.pseudo?(path)

      full = File.join(@root, path)
      @current[path] = File.file?(full) ? Diff.blob_sha(full) : nil
    end
  end
end
