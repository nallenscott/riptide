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
  end
end
