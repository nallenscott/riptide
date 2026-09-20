# frozen_string_literal: true

require "riptide"

# Riptide's Minitest plugin. Add one line to test_helper.rb:
#
#   require "minitest/riptide_plugin"
#
# That's the entire setup, for any test run, riptide's CLI or a plain
# `bin/rails test`/`rake test`. Minitest's plugin loading has been opt-in
# since it made auto-discovering and auto-loading any gem's plugin file
# just for being installed a problem ("bad actors installed globally",
# per minitest's History.rdoc), so this file registers itself explicitly
# with Minitest.register_plugin rather than relying on being found
# automatically. register_plugin, init_plugins, and the plugin_<name>_init
# hook convention are the same API across minitest 5.x and 6.x, verified
# directly against both, so this needs nothing version-specific.
module Minitest
  # Some apps' own boot chains call Minitest.autorun more than once (Rails
  # itself does: rails/test_help requires active_support/testing/autorun,
  # which calls Minitest.autorun directly, independent of any earlier
  # minitest/autorun require), so Minitest.run, and this hook, can fire
  # more than once in a single process even though the actual test suite
  # only ever executes once. Guard against wiring/printing twice.
  def self.plugin_riptide_init(_options)
    return if @riptide_initialized

    @riptide_initialized = true

    root = Dir.pwd
    store = Riptide::Store.new(path: Riptide.configuration.store_path)

    Riptide::Collector::MinitestHooks.wire(store: store, root: root)
    Minitest::Test.include(Riptide::Collector::MinitestHooks)

    riptide_dry_run(store, root) if Riptide.configuration.dry_run
  end

  # Same decision-making as Riptide::CLI's plan command, Selector is the
  # shared piece, but gathers its inputs instead of going through CLI:
  # by the time this hook fires, Minitest has discovered every test in
  # this process, so there's nothing to boot or load a second time.
  # Doesn't filter or skip anything, only prints.
  def self.riptide_dry_run(store, root)
    if store.empty?
      puts "[riptide] plan: no dependency map yet"
      return
    end

    discovered = Riptide.discovered_tests_by_file(root: root)

    base = Riptide.default_base
    decision = Riptide::Selector.new(store: store, root: root, discovered_tests_by_file: discovered).select(base: base)
    total = discovered.values.flatten(1).size

    puts "[riptide] plan vs #{base}: #{decision.summary(total: total)}"
  end

  register_plugin(:riptide)
end
