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
    # branch name isn't a valid fallback, a CI checkout essentially never
    # has a local branch by that name, only the remote-tracking ref.
    def default_base
      ref = "#{configuration.default_remote}/#{configuration.default_branch}"
      Diff.merge_base(ref)
    rescue Error
      ref
    end
  end
end
