# frozen_string_literal: true

require "test_helper"

module Riptide
  class AuditTest < Minitest::Test
    include GitFixture

    Statement = Index::Model::Statement

    def test_a_test_whose_checks_another_makes_too_is_removable_once
      report = audit(<<~RUBY, { "test_price" => [[3, ["Shop.price"], [1]]], "test_price_again" => [[7, ["Shop.price"], [1]]] })
        class ShopTest < Minitest::Test
          def test_price
            assert_equal 2, Shop.price
          end

          def test_price_again
            assert_equal 2, Shop.price
          end
        end
      RUBY

      assert_equal ["ShopTest#test_price"], report.removals.map(&:test), "one of the two stays"
      assert_equal [[3, "ShopTest#test_price_again:7"]], report.removals.first.twins
    end

    def test_the_same_assertion_on_different_setup_is_a_different_check
      report = audit(<<~RUBY, { "test_nil" => [[3, []], [4, ["Shop#about"], [1]]], "test_empty" => [[8, []], [9, ["Shop#about"], [1]]] })
        class ShopTest < Minitest::Test
          def test_nil
            @shop.about = nil
            assert_equal "x", @shop.about
          end

          def test_empty
            @shop.about = ""
            assert_equal "x", @shop.about
          end
        end
      RUBY

      assert_empty report.removals
    end

    def test_the_same_assertion_reaching_different_code_or_comparing_different_values_is_a_different_check
      report = audit(<<~RUBY, { "test_one" => [[2, ["Shop.open?", "Shop.hours"], [1]]], "test_two" => [[3, ["Shop.open?"], [1]]], "test_three" => [[4, ["Shop.open?"], [2]]] })
        class ShopTest < Minitest::Test
          def test_one = assert(Shop.open?)
          def test_two = assert(Shop.open?)
          def test_three = assert(Shop.open?)
        end
      RUBY

      assert_empty report.removals
    end

    def test_code_in_test_files_doesnt_count_toward_a_check
      report = audit(<<~RUBY, { "test_one" => [[2, ["Shop.open?"], [1], { test: ["ShopTest#test_one"] }]], "test_two" => [[3, ["Shop.open?"], [1], { test: ["ShopTest#test_two"] }]] })
        class ShopTest < Minitest::Test
          def test_one = assert(Shop.open?)
          def test_two = assert(Shop.open?)
        end
      RUBY

      assert_equal 1, report.removals.size
    end

    def test_a_mock_is_checked_by_what_runs_after_it
      report = audit(<<~RUBY, { "test_ships" => [[3, [], [5]], [4, ["Shop.ship"]]], "test_refunds" => [[8, [], [5]], [9, ["Shop.refund"]]] })
        class ShopTest < Minitest::Test
          def test_ships
            Mailer.expects(:shipped).with(1)
            Shop.ship
          end

          def test_refunds
            Mailer.expects(:shipped).with(1)
            Shop.refund
          end
        end
      RUBY

      assert_empty report.removals
    end

    def test_a_body_that_ran_no_assertions_or_mocks_checks_nothing
      report = audit(<<~RUBY, { "test_warm" => [[3, ["Cache.warm"]]], "test_guarded" => [[7, []]] })
        class ShopTest < Minitest::Test
          def test_warm
            Cache.warm
          end

          def test_guarded
            return unless ready?
            assert Shop.open?
          end
        end
      RUBY

      assert_equal %w[ShopTest#test_guarded ShopTest#test_warm], report.unchecked, "a guard that returned ran no assertion"
    end

    def test_a_test_doing_two_unrelated_things_splits_into_them
      report = audit(<<~RUBY, { "test_both" => [[3, ["Shop.create"], [], { wrote: true, ms: 1000 }], [4, [], [1]], [5, ["Shop.create"], [], { wrote: true, ms: 1000 }], [6, [], [1]]] })
        class ShopTest < Minitest::Test
          def test_both
            api = Shop.create(name: "api")
            assert_not api.persisted?
            www = Shop.create(name: "www")
            assert_not www.persisted?
          end
        end
      RUBY

      megalith = report.megaliths.find { |m| m.test == "ShopTest#test_both" }
      assert_equal :scenarios, megalith.shape
      assert_equal [[4], [6]], megalith.parts.map(&:lines)
    end

    def test_checks_on_one_write_are_one_scenario
      report = audit(<<~RUBY, { "test_order" => [[3, ["Shop.order"], [], { wrote: true }], [4, [], [1]], [5, [], [1]]] })
        class ShopTest < Minitest::Test
          def test_order
            order = Shop.order
            assert order.paid?
            assert order.shipped?
          end
        end
      RUBY

      assert_empty report.megaliths
    end

    def test_a_write_can_change_an_object_a_later_check_reads
      report = audit(<<~RUBY, { "test_spy" => [[3, [], [1]], [4, ["Shop.order"], [], { wrote: true }], [5, [], [1]]] })
        class ShopTest < Minitest::Test
          def test_spy
            assert @notifier.ready?
            Shop.order
            assert @notifier.used?
          end
        end
      RUBY

      assert_empty report.megaliths, "the order can change the notifier from setup that the second check reads"
    end

    def test_a_statement_is_linked_to_the_earlier_ones_whose_writes_it_read
      report = audit(<<~RUBY, { "test_found" => [[3, [], [], { wrote: true }], [4, [], [], { wrote: true }], [5, [], [1], { reads: [0] }], [6, [], [1], { reads: [1] }]] })
        class ShopTest < Minitest::Test
          def test_found
            Shop.create(name: "a")
            Shop.create(name: "b")
            assert Shop.find_by(name: "a")
            assert Shop.find_by(name: "b")
          end
        end
      RUBY

      assert_equal [[5], [6]], report.megaliths.first.parts.map(&:lines)
    end

    def test_assertions_on_a_write_that_builds_on_earlier_assertions_are_a_step
      source = +"class ShopTest < Minitest::Test\n  def test_flow\n"
      statements = (3..18).map do |line|
        source << (line.even? ? "    assert Shop.ok?\n" : "    Shop.step#{line}\n")
        line.even? ? [line, [], [1]] : [line, ["Shop.step#{line}"], [], { wrote: true }]
      end
      source << "  end\nend\n"
      report = audit(source, { "test_flow" => statements })

      megalith = report.megaliths.first
      assert_equal :steps, megalith.shape
      assert_equal 8, megalith.parts.size
    end

    def test_a_body_that_cant_be_found_in_its_file_is_reported
      report = audit("class ShopTest < Minitest::Test\nend\n", { "test_missing" => [[40, [], [1]]] })

      assert_equal ["ShopTest#test_missing"], report.unread
    end

    def test_parts_are_priced_by_the_changes_that_would_have_picked_them
      in_repo do |root|
        write_and_commit(root, "app/shop.rb", "class Shop\n  def self.price = 1\n  def self.tax = 1\nend\n", message: "start")
        write_and_commit(root, "app/shop.rb", "class Shop\n  def self.price = 2\n  def self.tax = 1\nend\n", message: "price")
        write_and_commit(root, "app/shop.rb", "class Shop\n  def self.price = 3\n  def self.tax = 1\nend\n", message: "price again")
        write_and_commit(root, "app/shop.rb", "class Shop\n  def self.price = 3\n  def self.tax = 2\nend\n", message: "tax")
        write_and_commit(root, "app/other.rb", "class Other\nend\n", message: "a file nothing recorded")
        sha = Diff.blob_sha(File.join(root, "app/shop.rb"))
        git = Git.new(root)
        layout = Layout.new(root: root)
        history = Audit::History.new(git: git, analyzer: Analyzer.new(layout: layout, blobs: git.method(:read), load_facts: ->(_) {}),
                                     layout: layout, branch: "HEAD", since: "1 year ago")

        report = audit(<<~RUBY, { "test_both" => [[3, ["Shop.price"], [], { ms: 1000 }], [4, [], [1]], [5, ["Shop.tax"], [], { ms: 1000 }], [6, [], [2]]] },
          class ShopTest < Minitest::Test
            def test_both
              price = Shop.price
              assert_equal 3, price
              tax = Shop.tax
              assert_equal 2, tax
            end
          end
        RUBY
                       root: root, history: history, sha: sha, ms: 2000)

        assert_equal 4, history.size
        megalith = report.megaliths.first
        assert_equal [2, 1], megalith.parts.map(&:picked)
        assert_equal 3, megalith.picked
        assert_equal (3 * 2000) - ((2 * 1000) + (1 * 1000)), megalith.saved_ms
      end
    end

    private

    # Audits +source+, written as test/shop_test.rb, with a run per test in
    # +bodies+: { name => [[line, methods, compared, options], ...] }.
    def audit(source, bodies, root: nil, history: nil, sha: "s1", ms: 1000)
      run = lambda do |dir|
        FileUtils.mkdir_p(File.join(dir, "test"))
        File.write(File.join(dir, "test/shop_test.rb"), source)
        model = Index::Model.new
        bodies.each do |name, statements|
          body = statements.map do |line, methods, compared = [], options = {}|
            files = {}
            files["app/shop.rb"] = { "sha" => sha, "methods" => methods } if methods.any?
            files["test/shop_test.rb"] = { "sha" => "t1", "methods" => options[:test] } if options[:test]
            set = files.empty? ? nil : model.add_set(files, [])
            Statement.new(line: line, set: set, ms: options.fetch(:ms, 0), compared: compared, wrote: options.fetch(:wrote, false), reads: options.fetch(:reads, []))
          end
          model.add_run(test: ["ShopTest", name], at: 1.0, sets: body.filter_map(&:set), files: {}, constants: [], file: "test/shop_test.rb", body: body, ms: ms)
        end
        Audit.new(indexes: [Index.of(model.encode)], git: Git.new(dir), root: dir, history: history).run
      end
      root ? run.(root) : in_repo { |dir| run.(dir) }
    end
  end
end
