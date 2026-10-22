# frozen_string_literal: true

require "minitest"
require "riptide"

# Minitest 5 loads every installed gem's minitest/*_plugin.rb by itself, so
# riptide does nothing in a process that never called Riptide.configure.
module Minitest
  def self.plugin_riptide_init(_options)
    return unless Riptide.configured?
    # Rails' own boot calls Minitest.autorun again, which can run plugin
    # init twice in one process.
    return if @riptide_started

    @riptide_started = true
    Riptide::Session.new(Riptide.configuration).start
  end

  register_plugin(:riptide)
end
