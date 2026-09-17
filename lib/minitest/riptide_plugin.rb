# frozen_string_literal: true

require "riptide"

# Riptide's Minitest plugin. Add one line to test_helper.rb:
#
#   require "minitest/riptide_plugin"
#
# That's the entire setup, for any test run, riptide's own CLI or a plain
# `bin/rails test`/`rake test`. Minitest's plugin loading has been opt-in
# since it made auto-discovering and auto-loading any gem's plugin file
# just for being installed a real problem ("bad actors installed
# globally", per minitest's own History.rdoc), so this file registers
# itself explicitly with Minitest.register_plugin rather than relying on
# being found automatically. register_plugin, init_plugins, and the
# plugin_<name>_init hook convention are the same API across minitest 5.x
# and 6.x, confirmed directly against both, so this needs nothing
# version-specific.
module Minitest
  def self.plugin_riptide_init(_options)
    root = Dir.pwd
    store = Riptide::Store.new(path: File.join(root, Riptide.configuration.db_path))

    Riptide::Collector::MinitestHooks.wire(store: store, root: root)
    Minitest::Test.include(Riptide::Collector::MinitestHooks)
  end

  register_plugin(:riptide)
end
