# frozen_string_literal: true

require "set"

module Riptide
  # Decides which tests the working tree can affect, from recorded runs
  # alone. Every recorded input names the exact file version it was
  # recorded against, so there's no diff base: the question for each test
  # is whether anything it depended on differs from what's on disk now.
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

    FACETS = %w[methods blocks owners tables].freeze

    # +listing+ returns what a recorded glob matches now.
    def initialize(store:, analyzer:, root:, tests:, listing:)
      @store = store
      @analyzer = analyzer
      @root = root
      @tests = tests
      @listing = listing
      @current = {}
      @suite_reason = nil
    end

    def select
      runs = @store.runs(@tests)
      selected = @tests.filter_map do |test|
        reason = reason_to_run(runs.fetch(test, []))
        { test: test, reason: reason } if reason
      end
      return Decision.full(@tests, @suite_reason) if @suite_reason && !@tests.empty?

      full = !@tests.empty? && selected.size == @tests.size
      Decision.new(mode: full ? :full : :selected, selected: selected, total: @tests.size)
    end

    private

    # A test is skipped when any passing run it kept still holds: nothing it
    # depended on changed in a way that reaches it. A run from another branch
    # can hold when the newest one doesn't.
    def reason_to_run(runs)
      return "no recorded run" if runs.empty?
      return "failed the last time it ran" unless runs.first.passed

      reasons = runs.select(&:passed).map { |run| unchanged?(run) ? nil : first_reason(run) }
      reasons.all? ? reasons.first : nil
    end

    # Everything a run depended on: its shared sets, then its own inputs.
    # nil when a shared set is missing, since then nothing can be checked.
    def files_of(run)
      sets = run.sets.map { |id| @store.set(id) }
      sets.include?(nil) ? nil : sets << run.inputs
    end

    def unchanged?(run)
      files_of(run)&.all? { |files| files.all? { |path, facets| current_sha(path) == facets["sha"] } }
    end

    def first_reason(run)
      groups = files_of(run)
      return "a shared set it depended on isn't available" unless groups

      read = groups.flat_map { |files| files.values.flat_map { |facets| facets["constants"] || [] } }.to_set
      groups.each do |files|
        files.each do |path, facets|
          reason = reason_for(path, facets, read)
          return reason if reason
        end
      end
      nil
    end

    # +read+ holds every constant the run read, in any file. A constant
    # added here can shadow one read elsewhere, and a dynamic read like
    # "*::LIMIT" matches a changed constant of that name.
    def reason_for(path, facets, read)
      current = current_sha(path)
      return nil if current == facets["sha"]
      return "#{Env.constant_name(path)} is defined now" if Env.constant?(path)
      return "files matching #{path.delete_prefix(Env::GLOB)} were added or removed" if Env.pseudo?(path)
      return "#{path} was deleted" if current.nil?

      change = @analyzer.change(path, facets["sha"])
      return "#{path} changed, and the recorded version isn't in this repository" if change.nil?
      return nil if change.empty?
      return suite("#{path} changed top-level code") if change.suite?
      return "#{path} changed as a whole" if change.whole? || facets["whole"]

      FACETS.each do |facet|
        hit = facets[facet]&.find { |name| change.public_send(facet).include?(name) }
        return "#{path} changed #{hit}" if hit
      end
      hit = change.constants.find { |name| read.include?(name) }
      return "#{path} changed #{hit}" if hit

      hit = change.constants.find { |name| read.include?("*::#{name.split("::").last}") }
      hit && "#{path} changed #{hit}, which the test may have looked up by name"
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
