# frozen_string_literal: true

module Riptide
  class Configuration
    # Path to the SQLite dependency map, relative to the host app's root.
    attr_accessor :db_path

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

    def initialize
      @db_path = "tmp/riptide/riptide.db"
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
    end
  end
end
