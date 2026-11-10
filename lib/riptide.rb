# frozen_string_literal: true

module Riptide
  class Error < StandardError; end
end

require_relative "riptide/version"
require_relative "riptide/configuration"
require_relative "riptide/tracer"
require_relative "riptide/diff"
require_relative "riptide/source"
require_relative "riptide/change"
require_relative "riptide/analysis/ruby"
require_relative "riptide/analysis/sql"
require_relative "riptide/analysis/schema"
require_relative "riptide/analysis/fixture"
require_relative "riptide/layout"
require_relative "riptide/analyzer"
require_relative "riptide/resolver"
require_relative "riptide/collectors"
require_relative "riptide/inputs"
require_relative "riptide/env"
require_relative "riptide/git"
require_relative "riptide/index"
require_relative "riptide/store"
require_relative "riptide/harvest"
require_relative "riptide/selector"
require_relative "riptide/runner"
require_relative "riptide/recorder"
require_relative "riptide/session"

module Riptide
  class << self
    # Turns riptide on and starts tracing, so call it before the app loads:
    # the tracer has to see class bodies run, and the collectors the files
    # boot reads and lists.
    def configure
      yield configuration
      @configured = true
      warn "[riptide] configure ran after the app loaded, so its boot isn't recorded" if app_loaded?
      Tracer.install(configuration.root, caller: caller_locations(1, 1).first&.absolute_path) unless Tracer.installed?
      Collectors.install(configuration.root)
    end

    def configured?
      @configured == true
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def app_loaded?
      defined?(::Rails.application) && ::Rails.application&.initialized?
    end

    # Every [class_name, method_name] Minitest knows about in this process.
    # methods_matching rather than runnable_methods, which shuffles by a
    # seed that isn't set yet when plugins start.
    def discovered_tests
      Minitest::Runnable.runnables.flat_map do |klass|
        klass.methods_matching(/^test_/).map { |method| [klass.name, method] }
      end
    end
  end
end
