# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "rake/extensiontask"

Rake::ExtensionTask.new("riptide_native") do |ext|
  ext.ext_dir = "ext/riptide"
  ext.lib_dir = "lib/riptide"
end

# riptide ships its own Minitest plugin (lib/minitest/riptide_plugin.rb),
# which auto-activates for any Minitest run once the gem's on the load
# path, confirmed via bundle exec that this includes riptide's own test
# suite. --no-plugins keeps that plugin from instrumenting riptide's tests
# against themselves; it doesn't affect how the plugin behaves for a real
# consuming app, which never sets this.
Minitest::TestTask.create do |t|
  t.extra_args = ["--no-plugins"]
end

task test: :compile
task default: :test
