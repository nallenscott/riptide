# frozen_string_literal: true

require_relative "lib/riptide/version"

Gem::Specification.new do |spec|
  spec.name     = "riptide"
  spec.version  = Riptide::VERSION
  spec.authors  = ["Nathan Allen"]
  spec.email    = ["hello@nallenscott.com"]
  spec.summary  = "Local-first test impact analysis for Rails and Minitest"
  spec.homepage = "https://github.com/nallenscott/riptide"
  spec.license  = "MIT"

  spec.metadata = {
    "source_code_uri" => "https://github.com/nallenscott/riptide",
    "changelog_uri" => "https://github.com/nallenscott/riptide/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/nallenscott/riptide/issues"
  }

  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir["lib/**/*.rb", "exe/*"] + ["riptide.gemspec"]
  spec.bindir = "exe"
  spec.executables = ["riptide"]
  spec.require_paths = ["lib"]

  spec.add_dependency "minitest", ">= 5.0"
  spec.add_dependency "sqlite3", "~> 2.0"
end
