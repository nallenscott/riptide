# frozen_string_literal: true

module Riptide
  class Configuration
    MODES = %i[record dry_run enforce].freeze

    # The app root everything is relative to.
    attr_accessor :root

    # Names the ref runs are kept under, refs/riptide/<suite>. Each CI stage
    # that runs a different slice of the tests is its own suite.
    attr_accessor :suite

    # Where test processes write their logs until `riptide publish` folds
    # them into the ref. Defaults to tmp/riptide/<suite>.
    attr_writer :log_dir

    # :record only records. :dry_run also prints what it would run. :enforce
    # runs only the selected tests.
    attr_reader :mode

    # Files every test depends on as a whole.
    attr_accessor :fallback_patterns

    # Globs of the files dependencies are recorded on. Empty means every
    # file under the root.
    attr_accessor :source_patterns

    # Locale files, which a test that translated anything depends on.
    attr_accessor :locale_patterns

    # The schema file, db/structure.sql or db/schema.rb when unset.
    attr_accessor :schema_path

    attr_accessor :fixtures_path

    # Recorded runs kept per test. A test is skipped when any of them
    # matches the current tree, so a few let moving between branches reuse
    # an earlier run.
    attr_accessor :retained_runs

    # When set, the selection is also written here as JSON.
    attr_accessor :plan_path

    def initialize
      @root = Dir.pwd
      @suite = "default"
      @mode = :record
      @fallback_patterns = %w[Gemfile Gemfile.lock config/application.rb config/environment.rb config/environments/test.rb config/initializers/**/*]
      @source_patterns = []
      @locale_patterns = ["config/locales/**/*"]
      @schema_path = nil
      @fixtures_path = "test/fixtures"
      @retained_runs = 4
      @plan_path = nil
    end

    def log_dir
      File.expand_path(@log_dir || "tmp/riptide/#{suite}", root)
    end

    def mode=(value)
      raise ArgumentError, "mode must be one of #{MODES.inspect}, got #{value.inspect}" unless MODES.include?(value)

      @mode = value
    end
  end
end
