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
    Decision = Struct.new(:mode, :selected, :total, keyword_init: true) do
      def summary(limit: 30)
        header = "#{selected.size}/#{total} tests"
        header = "full suite, #{header}" if mode == :full
        lines = selected.first(limit).map { |entry| "  #{entry[:test].join("#")}: #{entry[:reason]}" }
        lines << "  ... #{selected.size - limit} more" if selected.size > limit
        ([header] + lines).join("\n")
      end

      def to_h
        { "mode" => mode.to_s, "total" => total,
          "selected" => selected.map { |entry| { "test" => entry[:test], "reason" => entry[:reason] } } }
      end

      def self.full(tests, reason)
        new(mode: :full, total: tests.size, selected: tests.map { |test| { test: test, reason: reason } })
      end
    end

    # +indexes+ hold the recorded runs and open failures, from every unit
    # the build read and its logs. +listing+ returns what a recorded glob matches now.
    def initialize(indexes:, analyzer:, root:, tests:, listing:)
      @indexes = indexes
      @analyzer = analyzer
      @root = root
      @tests = tests
      @listing = listing
      @current = {}
      @suite_reason = nil
    end

    # { index => { run id => reason } } for the runs that don't hold here,
    # once #select has run.
    attr_reader :hits

    def select
      @hits = @indexes.to_h { |index| [index, hits_in(index)] }
      if @suite_reason
        @hits = @indexes.to_h { |index| [index, index.run_ids.to_h { |id| [id, @suite_reason] }] }
        return Decision.full(@tests, @suite_reason) unless @tests.empty?
      end

      selected = @tests.filter_map do |test|
        reason = reason_to_run(test)
        { test: test, reason: reason } if reason
      end
      full = !@tests.empty? && selected.size == @tests.size
      Decision.new(mode: full ? :full : :selected, selected: selected, total: @tests.size)
    end

    private

    # A test with an open failure runs until a build passes it, since a
    # failure riptide can't trace, like a flaky one, has nothing else to
    # rerun it. Otherwise it's skipped when a passing run still holds.
    def reason_to_run(test)
      return "failed and hasn't passed since" if @indexes.any? { |index| index.marks[test]&.any? }

      runs = @indexes.flat_map { |index| index.runs.fetch(test, []).map { |run| [run, @hits[index][run.id]] } }
      return "no recorded run" if runs.empty?
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

          changed(index, path, version, current) { |reason, runs| runs.each { |id| hits[id] ||= reason } }
          return hits if @suite_reason
        end
      end
      hits
    end

    # Yields the reason and the runs for each part of +version+ that
    # changed. A constant added here can shadow one read elsewhere, so it
    # reaches the runs that recorded this version and read that name in any
    # file. A dynamic read like "*::LIMIT" matches a changed constant of
    # that name.
    def changed(index, path, version, current)
      postings = index.postings(path, version)
      recorded = -> { index.runs_for(postings["all"]) }
      return yield("#{Env.constant_name(path)} is defined now", recorded.call) if Env.constant?(path)
      return yield("files matching #{path.delete_prefix(Env::GLOB)} were added or removed", recorded.call) if Env.pseudo?(path)
      return yield("#{path} was deleted", recorded.call) if current.nil?

      change = @analyzer.change(path, version)
      return yield("#{path} changed, and the recorded version isn't in this repository", recorded.call) if change.nil?
      return if change.empty?
      return suite("#{path} changed top-level code") if change.suite?
      return yield("#{path} changed as a whole", recorded.call) if change.whole?

      yield("#{path} changed as a whole", index.runs_for(postings["whole"] || []))
      Index::FACETS.each do |facet|
        by_name = postings[facet] || {}
        change.public_send(facet).each { |name| (ids = by_name[name.to_s]) && yield("#{path} changed #{name}", index.runs_for(ids)) }
      end
      return if change.constants.empty?

      runs = recorded.call
      change.constants.each do |name|
        yield("#{path} changed #{name}", index.runs_for(index.readers(name)) & runs)
        yield("#{path} changed #{name}, which the test may have looked up by name", index.runs_for(index.readers("*::#{name.split("::").last}")) & runs)
      end
    end

    def suite(reason)
      @suite_reason ||= reason
    end

    def current_sha(path)
      return @current[path] if @current.key?(path)
      return @current[path] = Env.presence(path) if Env.constant?(path)
      return @current[path] = @listing.call(path.delete_prefix(Env::GLOB)) if Env.pseudo?(path)

      full = File.join(@root, path)
      @current[path] = File.file?(full) ? Diff.blob_sha(full) : nil
    end
  end
end
