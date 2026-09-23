# frozen_string_literal: true

require "set"

module Riptide
  class Selector
    Decision = Struct.new(:mode, :reason, :selected, keyword_init: true) do
      # A human-readable description of this decision, shared by the CLI
      # commands and the Minitest plugin's dry_run logging, the two
      # places that report what got decided. Includes every selected
      # test and why, not just a count: a count alone can't be checked
      # against anything, the whole point of dry_run is to be able to
      # compare a decision against what happened later.
      # +total+, when given, adds "N/total" instead of a bare count.
      def summary(total: nil)
        return "full suite (#{reason})" if mode == :full

        header = total ? "#{selected.size}/#{total} tests" : "#{selected.size} tests"
        return header if selected.empty?

        lines = selected.map { |test| "  #{test[:class_name]}##{test[:method_name]}: #{test[:reasons].join(", ")}" }
        ([header] + lines).join("\n")
      end

      # Whether this decision would actually execute the given test. Used
      # by the Minitest plugin's dry_run path to gate which tests' coverage
      # gets recorded: dry_run runs every test regardless of what got
      # selected, so without this, a test riptide wouldn't have selected
      # would still have its coverage refreshed, permanently erasing the
      # "this file still differs from base" signal the next build would
      # otherwise correctly see. Memoized: called once per test in the
      # whole suite, not something to linear-scan +selected+ for each time.
      def runs?(class_name, method_name)
        mode == :full || selected_set.include?([class_name, method_name])
      end

      private

      def selected_set
        @selected_set ||= selected.map { |test| [test[:class_name], test[:method_name]] }.to_set
      end
    end

    # +discovered_tests_by_file+ is { relative_path => [[class_name, method_name], ...] },
    # every test method Minitest currently knows about, grouped by the file
    # it's defined in (via Method#source_location, not a naming
    # convention). Without it, a test method Store hasn't recorded
    # (a brand new test file, or a new method added to an existing one)
    # doesn't get selected at all: it has no dependency rows to diff
    # against, and isn't "modified" content Store tracks, so it silently
    # doesn't run.
    def initialize(store:, root: Dir.pwd, discovered_tests_by_file: {})
      @store = store
      @root = root
      @discovered_tests_by_file = discovered_tests_by_file
    end

    # Decides what to run for the changes between +base+ and +head+.
    # Returns a Decision: mode is :full (run everything, with +reason+ set)
    # or :selected (run exactly +selected+, an array of
    # { class_name:, method_name:, reasons: [...] }).
    def select(base:, head: "HEAD")
      changed = Diff.changed_files(base, head)

      fallback_reason = find_fallback_reason(changed)
      return Decision.new(mode: :full, reason: fallback_reason, selected: []) if fallback_reason

      selected = {}
      changed.each do |file|
        accumulate_selection(file, selected)
        add_undiscovered_tests(file, selected)
      end

      Decision.new(mode: :selected, reason: nil, selected: selected.values)
    end

    private

    # Any test currently defined in +file+ that Store hasn't recorded
    # coverage for gets selected outright, regardless of the file's diff
    # status. A test known to Store is left to accumulate_selection's
    # precise line-diffing instead of being re-selected unconditionally here.
    # Looks Store up by lookup_path_for, not file[:path]: for a renamed
    # file, Store's rows are still keyed by the old path, checking the new
    # one would always come back empty and treat every test in the file as
    # newly discovered.
    def add_undiscovered_tests(file, selected)
      tests_in_file = @discovered_tests_by_file[file[:path]] || []
      return if tests_in_file.empty?

      known = @store.dependencies_for_file(lookup_path_for(file)).map { |d| [d[:class_name], d[:method_name]] }.to_set

      tests_in_file.each do |class_name, method_name|
        next if known.include?([class_name, method_name])

        remember(selected, { class_name: class_name, method_name: method_name },
                 "#{file[:path]} has no recorded coverage for this test yet")
      end
    end

    # A file that matches a fallback pattern always forces a full run. An
    # existing file that was touched, modified, deleted, or renamed, but
    # that Store has zero historical coverage for, also forces a full
    # run: we can't tell whether that's untested code or an incomplete
    # map, and the safe assumption is the latter. A brand-new file is
    # exempt from that second check, having no history yet is expected,
    # not suspicious. So is a file outside source_patterns (when the app
    # has set it): no test execution could produce history for it, so an
    # empty history there isn't a signal of anything.
    def find_fallback_reason(changed)
      changed.each do |file|
        return "#{file[:path]} matches a fallback pattern" if fallback_pattern?(file[:path])
        next if file[:status] == :added
        next unless in_source_scope?(file[:path])

        lookup_path = lookup_path_for(file)
        return "#{file[:path]} has no historical coverage" if @store.dependencies_for_file(lookup_path).empty?
      end
      nil
    end

    def accumulate_selection(file, selected)
      case file[:status]
      when :added
        nil
      when :deleted
        add_all(file[:path], selected, reason: "#{file[:path]} was deleted")
      when :modified, :renamed
        add_for_content_change(file, selected)
      end
    end

    def add_all(lookup_path, selected, reason:)
      @store.dependencies_for_file(lookup_path).each { |dep| remember(selected, dep, reason) }
    end

    def add_for_content_change(file, selected)
      lookup_path = lookup_path_for(file)
      deps = @store.dependencies_for_file(lookup_path)
      current_sha = Diff.blob_sha(File.join(@root, file[:path]))

      deps.each do |dep|
        next if dep[:source_blob_sha] == current_sha

        hunks = Diff.hunks(Diff.unified(dep[:source_blob_sha], current_sha))
        overlap = dep[:ranges].any? { |range| Diff.translate_range(hunks, *range).nil? }
        next unless overlap

        remember(selected, dep, "#{file[:path]} changed within a covered range")
      end
    end

    def remember(selected, dep, reason)
      key = [dep[:class_name], dep[:method_name]]
      selected[key] ||= { class_name: dep[:class_name], method_name: dep[:method_name], reasons: [] }
      selected[key][:reasons] << reason
    end

    def lookup_path_for(file)
      file[:status] == :renamed ? file[:old_path] : file[:path]
    end

    def fallback_pattern?(path)
      matches_any?(Riptide.configuration.fallback_patterns, path)
    end

    # True when source_patterns is unset (the original, unscoped behavior)
    # or path matches one of the app's declared patterns.
    def in_source_scope?(path)
      patterns = Riptide.configuration.source_patterns
      patterns.empty? || matches_any?(patterns, path)
    end

    def matches_any?(patterns, path)
      patterns.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
    end
  end
end
