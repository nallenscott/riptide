# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"
require "rake/extensiontask"

Rake::ExtensionTask.new("riptide_native") do |ext|
  ext.ext_dir = "ext/riptide"
  ext.lib_dir = "lib/riptide"
end

# Minitest 5 loads every installed minitest/*_plugin.rb, riptide's
# included. Its own tests configure Riptide in-process, so --no-plugins
# keeps the plugin from recording riptide's suite against itself.
Minitest::TestTask.create do |t|
  t.extra_args = ["--no-plugins"]
end

task test: :compile
task default: :test
