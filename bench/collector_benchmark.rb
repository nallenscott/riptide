#!/usr/bin/env ruby
# frozen_string_literal: true

# Decomposed benchmark for Collector's native event hook, against raw
# TracePoint(:line) as a reference point for the underlying VM mechanism's
# cost. Same shape as the manual benchmarking used earlier to diagnose
# galore's real CI regression under the old TracePoint-based implementation:
# baseline with no instrumentation, the bare cost of having a :line hook
# enabled at all with an empty callback, the added cost of reading
# path/lineno off each event, then Collector's real, full accumulation
# logic.
#
#   ruby bench/collector_benchmark.rb
#   ITERATIONS=50000 TRIALS=5 ruby bench/collector_benchmark.rb

require_relative "../lib/riptide"

ITERATIONS = ENV.fetch("ITERATIONS", 20_000).to_i
TRIALS = ENV.fetch("TRIALS", 3).to_i

# Several lines with real side effects (assignments, not bare literals --
# see test/riptide/collector_test.rb for why bare literals as non-last
# statements don't reliably get their own line event at all), called many
# times, to approximate many short per-test capture windows each touching
# a handful of real app-code lines.
class BenchmarkWorkload
  def self.run
    total = 0
    total += 1
    total += 2
    total += 3
    total -= 1
    total *= 2
    total
  end
end

def median(values)
  sorted = values.sort
  mid = sorted.length / 2
  sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

def measure(label)
  samples = TRIALS.times.map do
    GC.start
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end
  result = median(samples)
  samples_str = samples.map { |s| format("%.4f", s) }.join(", ")
  printf("%-34s %8.4fs  (samples: %s)\n", label, result, samples_str)
  result
end

puts "Iterations per trial: #{ITERATIONS}, trials per label: #{TRIALS}"
puts

baseline = measure("baseline (no instrumentation)") do
  ITERATIONS.times { BenchmarkWorkload.run }
end

tracepoint_floor = measure("TracePoint (empty callback)") do
  tp = TracePoint.new(:line) {}
  tp.enable
  ITERATIONS.times { BenchmarkWorkload.run }
  tp.disable
end

tracepoint_attrs = measure("TracePoint (read path+lineno)") do
  tp = TracePoint.new(:line) { |t| t.path; t.lineno }
  tp.enable
  ITERATIONS.times { BenchmarkWorkload.run }
  tp.disable
end

collector = measure("Collector (real, native extension)") do
  c = Riptide::Collector.new(root: __dir__)
  ITERATIONS.times { c.capture { BenchmarkWorkload.run } }
end

puts
puts "Overhead relative to baseline:"
{
  "TracePoint (empty callback)" => tracepoint_floor,
  "TracePoint (read path+lineno)" => tracepoint_attrs,
  "Collector (real)" => collector
}.each do |label, elapsed|
  printf("  %-34s %6.2fx\n", label, elapsed / baseline)
end
