# frozen_string_literal: true

require "riptide/riptide_native"

module Riptide
  # Process-wide tracer. Install it before the app loads so it sees every
  # class body run.
  module Tracer
    Trace = Struct.new(:lines, :receivers)

    # What one statement of a test body ran, and how long it took.
    Statement = Struct.new(:trace, :seconds)

    module CoverageWatch
      def setup(*modes, **options) = watched(modes, options) { super }
      def start(*modes, **options) = watched(modes, options) { super }

      private

      def watched(modes, options)
        Tracer.oneshot! if [*modes, options].any? { |mode| mode.is_a?(Hash) && mode[:oneshot_lines] }
        yield
      end
    end

    class << self
      # Also notes each file's mtime and size when Ruby compiles it, so a
      # file edited mid-run can be told apart from the version that ran.
      # Ruby keeps whichever path a file was required by, so a root reached
      # through a symlink matches by either name.
      def install(root, caller: nil)
        unless SUPPORTED
          @broken = "riptide was built without its tracer: #{UNSUPPORTED}"
          return
        end

        root = File.expand_path(root)
        prefixes = [root, File.realpath(root)].uniq.map { |path| "#{path}/" }
        @prefixes = prefixes
        _install
        # The VM only looks for hooks on single iseqs while a targeted
        # TracePoint is on, so one sits on a method nothing calls. Turning it
        # on costs one YJIT wipe, before the app has compiled anything.
        @anchor = TracePoint.new(:call) {}
        @anchor.enable(target: method(:anchor))
        @compiled = {}
        @preloaded = ($LOADED_FEATURES + [caller].compact).uniq.filter_map do |path|
          prefixes.find { |prefix| path.start_with?(prefix) }&.then { |prefix| path.delete_prefix(prefix) }
        end
        # Looked up out here, since YJIT throws away the compiled hook when
        # the first app file fills a constant cache inside it.
        # https://github.com/ruby/ruby/commit/91ae69860591f0dfc85571cfbd023dd199e17e73
        file = File
        @compile_hook = TracePoint.new(:script_compiled) do |tp|
          iseq = tp.instruction_sequence
          path = iseq.absolute_path || iseq.path
          prefix = path && prefixes.find { |candidate| path.start_with?(candidate) }
          next unless prefix

          relative = path.delete_prefix(prefix).freeze
          target(iseq, relative)
          stat = file.stat(path) rescue next
          @compiled[relative] ||= [stat.mtime.to_r, stat.size]
        end
        @compile_hook.enable
      end

      # Aims the tracer at a compiled app file, every method and block in it
      # included. Anything that goes wrong leaves the file untraced, so the
      # tracer is broken for this process. The app, in the middle of loading
      # the file, never sees the error.
      def target(iseq, relative)
        pending = [iseq]
        while (current = pending.pop)
          _target(current, relative)
          current.each_child { |child| pending << child }
        end
      rescue StandardError => e
        @broken ||= "couldn't trace #{relative}: #{e.class}: #{e.message}"
      end

      def anchor = nil

      # Oneshot line coverage untraces each line after its first run, and
      # riptide's hook on that line goes with it, so the two can't run
      # together. Coverage started before now shows in its results, and a
      # later start goes through Coverage.start or setup.
      def watch_coverage
        return unless defined?(::Coverage)

        ::Coverage.singleton_class.prepend(CoverageWatch) unless ::Coverage.singleton_class < CoverageWatch
        oneshot! if ::Coverage.running? && ::Coverage.peek_result.each_value.any? { |result| result.is_a?(Hash) && result.key?(:oneshot_lines) }
      end

      def oneshot!
        @broken ||= "oneshot line coverage is on, and it turns off riptide's line tracing"
      end

      # Why the tracer missed code, or nil when it saw everything.
      attr_reader :broken

      # App files that loaded before the tracer was installed, like the test
      # helper that installs it. Nothing can trace them, so every test
      # depends on them whole.
      def preloaded = @preloaded || []

      # Windows nest, and lines go to the innermost one. The process's is
      # always open, so code that runs outside every other window, boot
      # included, lands there. It keeps no receivers.
      #
      # What ran in the innermost window since it opened, as { path =>
      # [line, ...] } and the classes of the receivers of every in-scope
      # method called.
      def close_window
        lines, receivers = _close_window
        Trace.new(lines, receivers)
      end

      # What ran in the innermost window since it opened or was last drained,
      # leaving it open.
      def drain
        lines, receivers = _drain
        Trace.new(lines, receivers)
      end

      # Runs +body+, a test method, in a window per top-level statement, each
      # starting at a line in +starts+, until close_body. The test's window
      # keeps what runs around the body. A test file that compiled before the
      # tracer was installed, like the first one a process loads, which
      # requires the test helper itself, gets its body traced here.
      def open_body(body, starts)
        iseq = RubyVM::InstructionSequence.of(body)
        path = iseq.absolute_path
        prefix = path && @prefixes&.find { |candidate| path.start_with?(candidate) }
        target(iseq, path.delete_prefix(prefix).freeze) if prefix
        _open_body(iseq, starts.sort)
      end

      # { statement's first line => Statement } for the statements that ran
      # since open_body, or nil when no body is open.
      def close_body
        _close_body&.transform_values { |lines, receivers, seconds| Statement.new(Trace.new(lines, receivers), seconds) }
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
