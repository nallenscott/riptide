# frozen_string_literal: true

require "set"

module Riptide
  # Records which lines of project source execute while a block of code
  # runs, using a global TracePoint(:line) rather than Ruby's Coverage
  # module. Coverage's result/peek_result cost scales with every file ever
  # loaded into the process, not just the ones touched, which makes it
  # unusable for a per-test checkpoint in a large app. A plain TracePoint
  # accumulator only pays for lines that execute.
  #
  # This does not see "code-less" classes, plain data objects whose only
  # footprint is allocation, with no method body a line event would ever
  # fire for. Datadog's collector needs a second allocation-tracing hook to
  # cover that case; this one doesn't have it yet.
  class Collector
    def initialize(root: Dir.pwd)
      @root = File.expand_path(root)
      @trace = nil
      @touched = nil
    end

    # Starts a capture window. Call +stop+ to end it and get the result.
    # Not reentrant: starting a second window before stopping the first
    # replaces it.
    def start
      touched = Hash.new { |h, k| h[k] = Set.new }
      root = @root

      @touched = touched
      @trace = TracePoint.new(:line) do |tp|
        path = tp.path
        next unless path.start_with?(root)

        touched[path.delete_prefix("#{root}/")] << tp.lineno
      end
      @trace.enable
      nil
    end

    # Ends the current capture window and returns what it saw, as
    # { relative_path => Set<Integer> }.
    def stop
      @trace.disable
      @touched
    end

    # Runs the block inside a capture window and returns what it saw.
    def capture
      start
      yield
      stop
    end
  end
end
