# frozen_string_literal: true

require_relative "lib/riptide/version"

Gem::Specification.new do |spec|
  spec.name     = "riptide"
  spec.version  = Riptide::VERSION
  spec.authors  = ["Nathan Allen"]
  spec.email    = ["hello@nallenscott.com"]
  spec.summary  = "Test impact analysis for Rails and Minitest"
  spec.homepage = "https://github.com/nallenscott/riptide"
  spec.license  = "MIT"

  spec.metadata = {
    "source_code_uri" => "https://github.com/nallenscott/riptide",
    "changelog_uri" => "https://github.com/nallenscott/riptide/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/nallenscott/riptide/issues"
  }

  # The tracer is built for the VM of Ruby 4.0 and later.
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir["lib/**/*.rb", "ext/**/*.{rb,c,h}", "exe/*"] + ["riptide.gemspec"]
  spec.bindir = "exe"
  spec.executables = ["riptide"]
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/riptide/extconf.rb"]

  # 5.1 to match Rails' declared minitest floor (activesupport 7.0 and
  # 8.1 both require >= 5.1). The plugin API this gem relies on
  # (register_plugin, init_plugins) is verified identical on 5.27, 6.0.0,
  # and 6.0.6, the versions checked; 7 doesn't exist yet, capping there
  # means an incompatible future major fails loudly at bundle install
  # instead of quietly at runtime.
  spec.add_dependency "minitest", ">= 5.1", "< 7"
  spec.add_dependency "prism", ">= 1.0"
end
