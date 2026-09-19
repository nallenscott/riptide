# frozen_string_literal: true

require "set"

module Riptide
  class Selector
    Decision = Struct.new(:mode, :reason, :selected, keyword_init: true) do
      # A human-readable description of this decision, shared by the CLI's
      # own commands and the Minitest plugin's dry_run logging, the two
      # places that report what got decided. Includes every selected
      # test and why, not just a count: a count alone can't be checked
      # against anything, the whole point of dry_run is to be able to
      # compare a decision against what actually happened later.
      # +total+, when given, adds "N/total" instead of a bare count.
      def summary(total: nil)
        return "full suite (#{reason})" if mode == :full

        header = total ? "#{selected.size}/#{total} tests" : "#{selected.size} tests"
        return header if selected.empty?

        lines = selected.map { |test| "  #{test[:class_name]}##{test[:method_name]}: #{test[:reasons].join(", ")}" }
        ([header] + lines).join("\n")
      end
    end

    # +discovered_tests_by_file+ is { relative_path => [[class_name, method_name], ...] },
    # every test method Minitest currently knows about, grouped by the file
    # it's actually defined in (via Method#source_location, not a naming
    # convention). Without it, a test method Store has never recorded
    # (a brand new test file, or a new method added to an existing one)
    # never gets selected at all: it has no dependency rows to diff
    # against, and isn't "modified" content Store already tracks, so it
    # silently never runs.
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

      full_suite_reason = find_full_suite_trigger(changed)
      return Decision.new(mode: :full, reason: full_suite_reason, selected: []) if full_suite_reason

      selected = {}
      changed.each do |file|
        accumulate_selection(file, selected)
        add_undiscovered_tests(file, selected)
      end

      Decision.new(mode: :selected, reason: nil, selected: selected.values)
    end

    private

    # Any test currently defined in +file+ that Store has never recorded
    # coverage for gets selected outright, regardless of the file's diff
    # status. A test already known to Store is left to accumulate_selection's
    # precise line-diffing instead of being re-selected unconditionally here.
    def add_undiscovered_tests(file, selected)
      tests_in_file = @discovered_tests_by_file[file[:path]] || []
      return if tests_in_file.empty?

      known = @store.dependencies_for_file(file[:path]).map { |d| [d[:class_name], d[:method_name]] }.to_set

      tests_in_file.each do |class_name, method_name|
        next if known.include?([class_name, method_name])

        remember(selected, { class_name: class_name, method_name: method_name },
                 "#{file[:path]} has no recorded coverage for this test yet")
      end
    end

    # A file that matches a global fallback pattern always forces a full
    # run. A file that already existed and was touched, modified, deleted,
    # or renamed, but that Store has zero historical coverage for, also
    # forces a full run: we can't tell whether that's genuinely untested
    # code or an incomplete map, and the safe assumption is the latter. A
    # brand-new file is exempt from that second check, having no history
    # yet is expected, not suspicious.
    def find_full_suite_trigger(changed)
      changed.each do |file|
        return "#{file[:path]} matches a global fallback pattern" if global_fallback?(file[:path])
        next if file[:status] == :added

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

    def global_fallback?(path)
      Riptide.configuration.global_fallback_patterns.any? do |pattern|
        File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
      end
    end
  end
end
