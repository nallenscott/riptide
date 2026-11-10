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
      def install(root, caller: nil)
        root = File.expand_path(root)
        prefixes = [root, File.realpath(root)].uniq.map { |path| "#{path}/" }
        _install(prefixes)
        @compiled = {}
        @preloaded = ($LOADED_FEATURES + [caller].compact).uniq.filter_map do |path|
          prefixes.find { |prefix| path.start_with?(prefix) }&.then { |prefix| path.delete_prefix(prefix) }
        end
        @compile_hook = TracePoint.new(:script_compiled) do |tp|
          iseq = tp.instruction_sequence
          path = iseq.absolute_path || iseq.path
          prefix = path && prefixes.find { |candidate| path.start_with?(candidate) }
          next unless prefix

          target(iseq, path)
          stat = File.stat(path) rescue next
          @compiled[path.delete_prefix(prefix)] ||= [stat.mtime.to_r, stat.size]
        end
        @compile_hook.enable
      end

      # Aims the tracer at a compiled app file. A file with no code in it,
      # like one that's all comments, has nothing to trace. Anything else
      # that goes wrong leaves the file untraced, so the tracer is broken for
      # this process. The app, in the middle of loading the file, never sees
      # the error.
      def target(iseq, path)
        _target(iseq)
      rescue ArgumentError
        nil
      rescue StandardError => e
        @broken ||= "couldn't trace #{path}: #{e.class}: #{e.message}"
      end

      # Why the tracer missed code, or nil when it saw everything.
      attr_reader :broken

      # App files that loaded before the tracer was installed, like the test
      # helper that installs it. Nothing can trace them, so every test
      # depends on them whole.
      def preloaded = @preloaded || []

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
