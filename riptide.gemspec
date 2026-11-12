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

  # 5.26.1 is the first Minitest that installs on Ruby 4. The cap makes a
  # major riptide hasn't been tested on fail at install instead of at runtime.
  spec.add_dependency "minitest", ">= 5.26.1", "< 7"
  spec.add_dependency "prism", ">= 1.0"
end
