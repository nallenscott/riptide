# frozen_string_literal: true

require "json"
require "fileutils"

module Riptide
  # Everything riptide does in one test process, once every test file has
  # loaded and before any test runs, which is also before Rails forks
  # parallel workers.
  class Session
    def initialize(config)
      @config = config
      @root = config.root
    end

    # Anything that goes wrong here leaves the suite running in full and
    # unrecorded, the same as without riptide.
    def start
      raise Error, Tracer.broken if Tracer.broken
      boot_reads = Collectors.boot_reads.to_a + Tracer.preloaded
      boot_globs = Collectors.boot_globs.to_a
      Collectors.install_frameworks
      git = Git.new(@root)
      layout = Layout.new(root: @root, schema_path: @config.schema_path, fixtures_path: @config.fixtures_path)
      store = Store.new(root: @root, suite: @config.suite, log_dir: @config.log_dir, retained_runs: @config.retained_runs)
      inputs = Inputs.new(layout: layout, files: git.files, source_patterns: @config.source_patterns, locale_patterns: @config.locale_patterns)
      env = Env.capture(inputs: inputs, layout: layout, fallback_patterns: @config.fallback_patterns, locale_patterns: @config.locale_patterns,
                        boot_lines: Tracer.drain_boot_lines, boot_reads: boot_reads, boot_globs: boot_globs)
      tests = Riptide.discovered_tests

      recorder = Recorder.new(store: store, inputs: inputs, env_set: Store.set_id(env))
      recorder.absorb_load_facts
      store.append_set(Store.set_id(env), env)
      Recorder.install(recorder)
      select(store, layout, inputs, tests) unless @config.mode == :record
    rescue StandardError => e
      warn "[riptide] #{@config.suite}: off for this run, #{e.class}: #{e.message}"
    end

    private

    # What the selection found about each unit's runs goes in the log, so
    # publishing can tell which held here. A selection that fails leaves
    # every test running, still recorded.
    def select(store, layout, inputs, tests)
      analyzer = Analyzer.new(layout: layout, blobs: store.method(:read_blob), load_facts: store.method(:load_facts))
      selector = Selector.new(indexes: store.indexes, analyzer: analyzer, root: @root, tests: tests,
                              listing: inputs.method(:listing))
      decision = selector.select
      store.append_selected(decision.selected.map { |entry| entry[:test] })
      selector.hits.each { |index, hits| store.append_hits(index, hits.keys) if index.ref }
      report(decision)
      Runner.new(decision: decision).apply if @config.mode == :enforce
      decision
    rescue StandardError => e
      warn "[riptide] #{@config.suite}: running every test, #{e.class}: #{e.message}"
    end

    def report(decision)
      verb = @config.mode == :enforce ? "running" : "would run"
      puts "[riptide] #{@config.suite}: #{verb} #{decision.summary}"
      return unless @config.plan_path

      path = File.expand_path(@config.plan_path, @root)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(decision.to_h))
    end
  end
end
