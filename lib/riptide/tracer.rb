# frozen_string_literal: true

require "riptide/riptide_native"

module Riptide
  # Process-wide tracer. Install it before the app loads so it sees every
  # class body run.
  module Tracer
    Trace = Struct.new(:lines, :receivers)

    class << self
      # Also notes each file's mtime and size when Ruby compiles it, so a
      # file edited mid-run can be told apart from the version that ran.
      # Ruby keeps whichever path a file was required by, so a root reached
      # through a symlink matches by either name.
      def install(root)
        root = File.expand_path(root)
        prefixes = [root, File.realpath(root)].uniq.map { |path| "#{path}/" }
        _install(prefixes)
        @compiled = {}
        @compile_hook = TracePoint.new(:script_compiled) do |tp|
          path = tp.instruction_sequence.absolute_path || tp.instruction_sequence.path
          prefix = path && prefixes.find { |candidate| path.start_with?(candidate) }
          next unless prefix

          stat = File.stat(path) rescue next
          @compiled[path.delete_prefix(prefix)] ||= [stat.mtime.to_r, stat.size]
        end
        @compile_hook.enable
      end

      # What ran since the window opened: { path => [line, ...] }, and the
      # classes of the receivers of every in-scope method called.
      def close_window
        lines, receivers = _close_window
        Trace.new(lines, receivers)
      end

      # [mtime, size] of +path+ when it was first compiled, or nil.
      def compiled_stat(path)
        @compiled&.[](path)
      end

      # { path => { line => { "owners" => [class name, ...], "called" => bool } } }
      # since the last drain: lines that ran because those classes were
      # loading, and whether each ran as called code, a method or block body,
      # rather than as a class body statement.
      def drain_load_facts
        called = _drain_load_called
        _drain_load_facts.to_h do |path, lines|
          facts = lines.to_h do |line, owners|
            [line, { "owners" => owners.filter_map { |owner| Tracer.name_of(owner) }.uniq, "called" => called.dig(path, line) == true }]
          end
          [path, facts]
        end
      end

      # Files whose lines ran while +mod+ was loading, including reopenings
      # and concerns' included blocks.
      def files_for(mod)
        files = _owner_files[mod]
        files ? files.keys : []
      end

      # A singleton class is named after the object it belongs to.
      def name_of(mod)
        mod = attached(mod)
        mod.is_a?(Module) ? mod.name : nil
      end

      def attached(mod) = mod.singleton_class? ? mod.attached_object : mod
    end
  end
end
