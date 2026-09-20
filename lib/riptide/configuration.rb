# frozen_string_literal: true

module Riptide
  class Configuration
    # Where the Store keeps its dependency map. Relative paths resolve
    # against wherever the process is running (the host app's root, in any
    # invocation); can also be absolute, for an environment that only
    # persists one specific directory across runs (e.g. a CI container
    # that bind-mounts /workspace back to the host).
    attr_accessor :store_path

    # Changing any of these always selects the full suite, regardless of
    # what Store knows, since they can affect app-wide behavior in ways
    # line-level coverage can't be trusted to capture. Defaults are
    # verified against Rails' generator templates (railties 6.1, 7.0,
    # 8.1 checked directly), not guessed: Gemfile/Gemfile.lock are Bundler
    # requirements, the rest are fixed Rails conventions, not something an
    # individual app configures. test_helper_path is pulled in separately
    # below rather than duplicated here as a literal.
    attr_accessor :fallback_patterns

    # Where the app's covered source lives. A changed file outside this
    # scope can't have historical coverage, no test execution could touch
    # it, so treating an empty history as suspicious and forcing a full
    # suite over it, the same way an untested .rb file would, is a false
    # alarm. Only files matching this scope go through that check;
    # everything else is outside Selector's consideration entirely,
    # neither forcing a full run nor selecting anything.
    #
    # No default. Unlike fallback_patterns, there's no universal Rails
    # convention for "where does this specific app's tested code live",
    # autoload/eager-load paths are the wrong proxy for it (an app can
    # autoload directories nothing tests, e.g. rake task libraries), and
    # guessing anything else is exactly the kind of assumption this gem
    # exists to avoid making about a codebase it doesn't know. Left empty,
    # the no-historical-coverage check applies to every changed file, the
    # original, unscoped behavior. Set it once data from the app's Store
    # shows which directories are exercised by tests.
    attr_accessor :source_patterns

    # Branch a default diff base is computed against, as
    # <default_remote>/<default_branch>. Not every app calls it "main".
    attr_accessor :default_branch

    # Remote a default diff base is fetched from, as
    # <default_remote>/<default_branch>. Not every remote is named
    # "origin", though nearly every one is.
    attr_accessor :default_remote

    # Required before any test file, boots whatever the host app's test
    # environment needs (Rails, fixtures, etc.).
    attr_accessor :test_helper_path

    # Glob, relative to the host app's root, of every test file to load.
    attr_accessor :test_glob

    # Files matching test_glob are skipped if their path matches any of
    # these regexes. Mirrors an app's test-partitioning convention
    # (e.g. a rake task excluding test/controllers for a "unit" run)
    # rather than requiring riptide to know about it structurally.
    attr_accessor :test_exclude_patterns

    # When true, the Minitest plugin computes and prints what it would
    # select for the current diff, using whatever Minitest discovered
    # in this process, same underlying Selector the plan CLI command
    # uses, just handed its inputs a different way. Doesn't filter or
    # skip anything either way, this only prints.
    attr_accessor :dry_run

    def initialize
      @store_path = "tmp/riptide/riptide.db"
      @default_branch = "main"
      @default_remote = "origin"
      @test_helper_path = "test/test_helper.rb"
      @fallback_patterns = [
        "Gemfile",
        "Gemfile.lock",
        "config/application.rb",
        "config/environment.rb",
        "config/initializers/**/*",
        @test_helper_path
      ]
      @source_patterns = []
      @test_glob = "test/**/*_test.rb"
      @test_exclude_patterns = []
      @dry_run = false
    end
  end
end
