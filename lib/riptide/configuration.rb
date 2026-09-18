# frozen_string_literal: true

module Riptide
  class Configuration
    # Where the Store keeps its dependency map. Relative paths resolve
    # against wherever the process is running (the host app's root, in any
    # real invocation); can also be absolute, for an environment that only
    # persists one specific directory across runs (e.g. a CI container
    # that bind-mounts /workspace back to the host).
    attr_accessor :store_path

    # Changing any of these always selects the full suite, regardless of
    # what Store knows, since they can affect app-wide behavior in ways
    # line-level coverage can't be trusted to capture.
    attr_accessor :global_fallback_patterns

    # Branch a default diff base is computed against, as origin/<main_branch>.
    # Not every app calls it "main".
    attr_accessor :main_branch

    # Required before any test file, boots whatever the host app's test
    # environment needs (Rails, fixtures, etc.).
    attr_accessor :test_helper_path

    # Glob, relative to the host app's root, of every test file to load.
    attr_accessor :test_glob

    # Files matching test_glob are skipped if their path matches any of
    # these regexes. Mirrors an app's own test-partitioning convention
    # (e.g. a rake task excluding test/controllers for a "unit" run)
    # rather than requiring riptide to know about it structurally.
    attr_accessor :test_exclude_patterns

    # When true, the Minitest plugin computes and prints what it would
    # select for the current diff, using whatever Minitest already
    # discovered in this process, same underlying Selector the plan CLI
    # command uses, just handed its inputs a different way. Never filters
    # or skips anything either way, this only ever prints.
    attr_accessor :dry_run

    def initialize
      @store_path = "tmp/riptide/riptide.db"
      @global_fallback_patterns = %w[
        Gemfile
        Gemfile.lock
        test/test_helper.rb
        config/application.rb
        config/environment.rb
        config/initializers/**/*
      ]
      @main_branch = "main"
      @test_helper_path = "test/test_helper.rb"
      @test_glob = "test/**/*_test.rb"
      @test_exclude_patterns = []
      @dry_run = false
    end
  end
end
