# frozen_string_literal: true

module Riptide
  class Selector
    Decision = Struct.new(:mode, :reason, :selected, keyword_init: true)

    def initialize(store:, root: Dir.pwd)
      @store = store
      @root = root
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
      changed.each { |file| accumulate_selection(file, selected) }

      Decision.new(mode: :selected, reason: nil, selected: selected.values)
    end

    private

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
