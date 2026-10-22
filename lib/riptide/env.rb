# frozen_string_literal: true

require "digest"
require "json"

module Riptide
  # What every test in a process depends on: fallback files as a whole, the
  # code that ran at boot, files read at boot, and listings of the globs
  # that catch new files. A new initializer, or a new support file a boot
  # glob requires, can change every test without touching any file a run
  # recorded.
  module Env
    GLOB = "glob:"
    # A constant a test looked up by name and didn't find, as
    # "const:<scope> <name>", counting the scope's ancestors or not.
    CONSTANT = "const:"
    OWN_CONSTANT = "const-own:"
    ABSENT = "absent"

    module_function

    # { path => facets }, stored as one of the process's shared sets.
    def capture(inputs:, layout:, fallback_patterns:, locale_patterns:, boot_lines:, boot_reads:, boot_globs:)
      files = {}
      (fallback_patterns + locale_patterns + boot_globs.to_a).uniq.each do |pattern|
        files["#{GLOB}#{pattern}"] = { "sha" => inputs.listing(pattern) }
      end
      fallback_patterns.flat_map { |pattern| Dir.glob(pattern, base: layout.root) }.uniq.each do |path|
        files[path] = { "sha" => inputs.sha(path), "whole" => true } if inputs.recordable?(path) && File.file?(File.join(layout.root, path))
      end
      inputs.for_boot(boot_lines).each { |path, facets| files[path] ||= facets }
      boot_reads.each do |path|
        files[path] = { "sha" => inputs.sha(path), "whole" => true } if !files.key?(path) && inputs.recordable?(path)
      end
      files.sort.to_h
    end

    def pseudo?(path) = path.start_with?(GLOB, CONSTANT, OWN_CONSTANT)

    def constant?(path) = path.start_with?(CONSTANT, OWN_CONSTANT)

    def constant_name(path)
      scope, name = path.delete_prefix(OWN_CONSTANT).delete_prefix(CONSTANT).split(" ", 2)
      scope == "Object" ? name : "#{scope}::#{name}"
    end

    # Whether a constant entry's lookup finds something now, made the same
    # way, counting an autoload as there.
    def presence(path)
      scope, name = path.delete_prefix(OWN_CONSTANT).delete_prefix(CONSTANT).split(" ", 2)
      Object.const_get(scope).const_defined?(name, !path.start_with?(OWN_CONSTANT)) ? "present" : ABSENT
    rescue NameError
      ABSENT
    end
  end
end
