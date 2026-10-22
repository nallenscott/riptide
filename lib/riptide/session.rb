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
      boot_reads = Collectors.boot_reads.to_a
      boot_globs = Collectors.boot_globs.to_a
      Collectors.install_frameworks
      git = Git.new(@root)
      layout = Layout.new(root: @root, schema_path: @config.schema_path, fixtures_path: @config.fixtures_path)
      store = Store.new(root: @root, suite: @config.suite, log_dir: @config.log_dir, retained_runs: @config.retained_runs)
      inputs = Inputs.new(layout: layout, files: git.files, source_patterns: @config.source_patterns, locale_patterns: @config.locale_patterns)
      env = Env.capture(inputs: inputs, layout: layout, fallback_patterns: @config.fallback_patterns, locale_patterns: @config.locale_patterns,
                        boot_lines: Tracer.drain_boot_lines, boot_reads: boot_reads, boot_globs: boot_globs)
      tests = Riptide.discovered_tests

      select(store, layout, inputs, env, tests) unless @config.mode == :record

      recorder = Recorder.new(store: store, inputs: inputs, env_set: Store.set_id(env))
      recorder.absorb_load_facts
      store.append_set(Store.set_id(env), env)
      store.append_discovered(tests)
      Recorder.install(recorder)
    rescue StandardError => e
      warn "[riptide] #{@config.suite}: off for this run, #{e.class}: #{e.message}"
    end

    private

    def select(store, layout, inputs, env, tests)
      analyzer = Analyzer.new(layout: layout, blobs: store.method(:read_blob), load_facts: store.method(:load_facts))
      decision = Selector.new(store: store, analyzer: analyzer, root: @root, tests: tests, listing: inputs.method(:listing)).select
      report(decision)
      Runner.new(decision: decision).apply if @config.mode == :enforce
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
