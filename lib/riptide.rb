# frozen_string_literal: true

require_relative "riptide/version"
require_relative "riptide/configuration"
require_relative "riptide/diff"

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
