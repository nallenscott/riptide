# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"

module Riptide
  # A suite run in its own Minitest process, its runs read back from the logs.
  class BodyTest < Minitest::Test
    include NeedsTracer

    LIB = File.expand_path("../../lib", __dir__)

    HELPER = <<~RUBY
      require "riptide"
      Riptide.configure do |c|
        c.suite = "unit"
        c.mode = :record
        c.fallback_patterns = []
        c.source_patterns = ["app/**/*.rb", "test/**/*.rb"]
      end
      # Enough of Mocha for riptide to see what an expectation is called with.
      module Mocha
        class Expectation
          def with(*, **) = self
        end
      end
      require "minitest/autorun"
      require "minitest/riptide_plugin"
      require_relative "../app/shop"
    RUBY

    SHOP = <<~RUBY
      class Shop
        def self.price = 2
        def self.tax = 1
        def self.open = :open
        def self.close = :close

        def self.total
          price + tax
        end
      end
    RUBY

    TESTS = <<~RUBY
      require_relative "test_helper"
      module Checking
        def assert_total(expected) = assert_equal(expected, Shop.total)
      end
      class ShopTest < Minitest::Test
        include Checking

        def setup = Shop.open
        def teardown = Shop.close

        def test_split
          price = Shop.price
          assert_equal 2, price
          assert_total 3
          Mocha::Expectation.new.with(:paid)
        end

        def test_one_line = assert_equal(1, Shop.tax)
        def test_one_line_again = assert_equal(1, Shop.tax)

        def test_failing
          assert_equal 4, Shop.total
        end

        def test_odd = assert(Odd.new)
      end

      class Odd
        def inspect = raise("can't describe me")
      end
    RUBY

    def test_each_statement_is_a_set_and_the_run_keeps_what_ran_around_the_body
      model = record_suite
      runs = model.runs.transform_values { |list| list.first.last }

      assert_equal [%w[ShopTest test_odd], %w[ShopTest test_one_line], %w[ShopTest test_one_line_again], %w[ShopTest test_split]], runs.keys.sort,
                   "a failing test records no run"
      assert_equal [[0]], runs.fetch(%w[ShopTest test_odd]).body.map(&:compared), "a value riptide can't describe still passes, with a digest of 0"
      split = runs.fetch(%w[ShopTest test_split])
      assert_equal %w[Shop.close Shop.open], methods(split.files), "setup and teardown ran around the body"
      refute(split.body.any? { |statement| statement.set && model.set(statement.set).files.key?("test/suite_test.rb") && model.set(statement.set).files["test/suite_test.rb"]["methods"]&.include?("ShopTest#test_split") },
             "the body's own lines are the test's")
      body = split.body
      assert_equal [12, 13, 14, 15], body.map(&:line)
      assert_equal [["Shop.price"], [], ["Shop.price", "Shop.tax", "Shop.total"], []], body.map { |statement| statement.set ? methods(model.set(statement.set).files).sort : [] }
      assert_equal [[2], [], [2, 3, 7, 8], []], body.map { |statement| statement.set ? model.set(statement.set).files.fetch("app/shop.rb", {}).fetch("lines", []).sort : [] },
                   "each statement keeps the lines it ran"
      assert_equal [0, 1, 1, 1], body.map { |statement| statement.compared.size }, "an assertion built on another counts once, and so does a mock's with"
      assert(body.all? { |statement| statement.ms >= 0 && !statement.wrote && statement.reads.empty? })
      assert_equal body.filter_map(&:set).sort, (split.sets & body.filter_map(&:set)).sort, "the statements' sets are the run's"
      assert_operator split.ms, :>=, body.sum(&:ms)

      one = runs.fetch(%w[ShopTest test_one_line])
      assert_equal [[18, ["Shop.tax"]]], one.body.map { |statement| [statement.line, methods(model.set(statement.set).files)] }
      assert_equal one.body.first.set, runs.fetch(%w[ShopTest test_one_line_again]).body.first.set, "statements that reached the same code share a set"
    end

    def test_a_test_files_own_lines_are_recorded_even_when_it_loads_first
      split = record_suite.runs.fetch(%w[ShopTest test_split]).first.last

      assert_includes split.files.dig("test/suite_test.rb", "methods"), "ShopTest#test_split",
                      "the first file a process loads compiles before riptide starts, and its body still counts"
    end

    private

    def methods(files) = files.fetch("app/shop.rb", {}).fetch("methods", [])

    def record_suite
      @record_suite ||= Dir.mktmpdir do |dir|
        { "app/shop.rb" => SHOP, "test/test_helper.rb" => HELPER, "test/suite_test.rb" => TESTS, ".gitignore" => "tmp/\n" }.each do |path, content|
          FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
          File.write(File.join(dir, path), content)
        end
        system("git", "init", "-q", dir, exception: true)
        system("git", "-C", dir, "add", "-A", exception: true)
        system("git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "start", exception: true)
        out, = Open3.capture2e("ruby", "-I", LIB, "test/suite_test.rb", chdir: dir)
        assert_match(/5 runs, \d+ assertions, 1 failures, 0 errors/, out)
        Store.new(root: dir, suite: "unit", log_dir: File.join(dir, "tmp/riptide/unit")).indexes.last.model
      end
    end
  end
end
