# frozen_string_literal: true

require "set"

module Riptide
  # What ran around tests instead of in one: in the process, from boot on,
  # or in a test class, from before its setup. A test depends on what ran in
  # its scopes before it started. What runs after a scope's last test, like
  # an after_all, counts for nobody.
  class Scope
    # +capture+ turns what the scope gathered, as a Tracer::Trace and a
    # Collectors::Window, into the ids of the shared sets its tests get.
    def initialize(&capture)
      @capture = capture
      @lines = Hash.new { |h, path| h[path] = Set.new }
      @receivers = Set.new.compare_by_identity
      @window = Collectors::Window.blank
      @sets = nil
    end

    # Takes in what the scope's windows gathered since the last drain.
    def absorb(trace, window)
      return if trace.lines.empty? && trace.receivers.empty? && !window.gathered?

      grew = @window.absorb(window)
      trace.lines.each do |path, numbers|
        lines = @lines[path]
        numbers.each { |number| grew = true if lines.add?(number) }
      end
      trace.receivers.each { |klass| grew = true if @receivers.add?(klass) }
      @sets = nil if grew
    end

    # Captured again only once the scope ran something new.
    def sets
      @sets ||= @capture.call(Tracer::Trace.new(@lines.transform_values(&:to_a), @receivers.to_a), @window)
    end
  end
end
