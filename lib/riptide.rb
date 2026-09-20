# frozen_string_literal: true

require_relative "riptide/version"
require_relative "riptide/configuration"
require_relative "riptide/diff"
require_relative "riptide/collector"
require_relative "riptide/collector/minitest_hooks"
require_relative "riptide/store/ranges"
require_relative "riptide/store"
require_relative "riptide/selector"
require_relative "riptide/runner"
require_relative "riptide/cli"

module Riptide
  class Error < StandardError; end

  class << self
    def configure
      yield configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    # Merge-base against <default_remote>/<default_branch> when that ref
    # exists, the common ancestor a normal feature branch diverged from.
    # Falls back to that ref's current tip when merge-base fails, e.g. the
    # ref hasn't been fetched yet. Still the same ref either way: a bare
    # branch name isn't a valid fallback, a CI checkout has no local
    # branch by that name, only the remote-tracking ref.
    def default_base
      ref = "#{configuration.default_remote}/#{configuration.default_branch}"
      Diff.merge_base(ref)
    rescue Error
      ref
    end

    # { relative_path => [[class_name, method_name], ...] }, every test
    # method Minitest currently knows about, grouped by the file it's
    # defined in via Method#source_location, not a naming convention.
    # Shared by the CLI and the Minitest plugin, the two places that
    # gather this to hand to Selector. methods_matching, not
    # runnable_methods: the latter sorts/shuffles based on Minitest.seed,
    # which isn't set yet this early in the plugin's case, before
    # Minitest.run's arg parsing has run, and neither pruning nor
    # selection needs run order, just the raw set of names.
    def discovered_tests_by_file(root:)
      Minitest::Runnable.runnables.each_with_object(Hash.new { |h, k| h[k] = [] }) do |klass, mapping|
        klass.methods_matching(/^test_/).each do |method|
          file = klass.instance_method(method).source_location&.first
          next unless file

          mapping[file.delete_prefix("#{root}/")] << [klass.name, method]
        end
      end
    end
  end
end
