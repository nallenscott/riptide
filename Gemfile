# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in riptide.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"
gem "rake-compiler", "~> 1.2"

# CI sets MINITEST to run the suite on each Minitest the gemspec allows.
gem "minitest", *ENV["MINITEST"]
# Minitest 6 moved stubs and mocks out into their own gem.
gem "minitest-mock"
