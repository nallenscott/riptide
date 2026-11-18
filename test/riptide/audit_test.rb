# frozen_string_literal: true

require "test_helper"

module Riptide
  class AuditTest < Minitest::Test
    include GitFixture

    Statement = Index::Model::Statement

    SHOP = <<~SOURCE
      class Shop
        def self.price
          2
        end

        def self.open?
          return true if @always
          hours.any?
        end

        def self.log
          :logged
        end
      end
    SOURCE

    TWO_PRICES = <<~SOURCE
      class ShopTest < Minitest::Test
        def test_price
          assert_equal 2, Shop.price
        end

        def test_price_again
          assert_equal 2, Shop.price
        end
      end
    SOURCE

    def test_the_same_body_run_the_same_way_checking_the_same_values_is_a_duplicate
      report = audit(TWO_PRICES, { "test_price" => [[3, [3], [1]]], "test_price_again" => [[7, [3], [1]]] })

      assert_equal [%w[ShopTest#test_price_again ShopTest#test_price]], report.duplicates.map { [_1.test, _1.of] },
                   "the first by name stays, and each body's own lines don't count"
    end

    def test_spacing_and_comments_dont_change_a_body
      report = audit(<<~SOURCE, { "test_price" => [[3, [3], [1]]], "test_price_again" => [[7, [3], [1]]] })
        class ShopTest < Minitest::Test
          def test_price
            assert_equal 2, Shop.price
          end

          def test_price_again
            assert_equal 2,   Shop.price # same check
          end
        end
      SOURCE

      assert_equal ["ShopTest#test_price_again"], report.duplicates.map(&:test)
    end

    def test_a_duplicate_compares_the_same_values
      report = audit(TWO_PRICES, { "test_price" => [[3, [3], [1]]], "test_price_again" => [[7, [3], [2]]] })

      assert_empty report.duplicates
    end

    def test_a_duplicate_runs_the_same_lines
      report = audit(<<~SOURCE, { "test_always" => [[3, [7], [1]]], "test_hours" => [[7, [7, 8], [1]]] })
        class ShopTest < Minitest::Test
          def test_always
            assert Shop.open?
          end

          def test_hours
            assert Shop.open?
          end
        end
      SOURCE

      assert_empty report.duplicates, "the test that stopped at the guard went another way through the method"
    end

    def test_a_duplicate_runs_the_same_test_code_around_its_body
      report = audit(TWO_PRICES, { "test_price" => [[3, [3], [1]]], "test_price_again" => [[7, [3], [1]]] }, setups: { "test_price_again" => [12] })

      assert_empty report.duplicates, "a setup or helper only one of them ran can change what the same body does"
    end

    def test_a_one_line_body_inside_a_block_is_its_own
      source = <<~SOURCE
        class ShopTest < Minitest::Test
          def self.group = yield
          group do
            define_method(:test_price) { assert_equal 2, Shop.price }
            define_method(:test_price_again) { assert_equal 2, Shop.price }
          end
        end
      SOURCE
      bodies = { "test_price" => [[4, [3], [1]]], "test_price_again" => [[5, [3], [1]]] }
      lines = { "test_price" => 4, "test_price_again" => 5 }

      assert_equal ["ShopTest#test_price_again"], audit(source, bodies, lines: lines).duplicates.map(&:test)
      assert_empty audit(source, bodies, lines: lines, setups: { "test_price_again" => [3] }).duplicates,
                   "the block around the body isn't the body, so what ran in it counts"
    end

    def test_a_heredoc_is_part_of_its_statement
      report = audit(<<~SOURCE, { "test_one" => [[3, [12], [1]]], "test_two" => [[9, [12], [1]]] })
        class ShopTest < Minitest::Test
          def test_one
            Shop.log(<<~TEXT)
              one
            TEXT
          end

          def test_two
            Shop.log(<<~TEXT)
              two
            TEXT
          end
        end
      SOURCE

      assert_empty report.duplicates
    end

    def test_spacing_inside_a_string_counts
      report = audit(<<~SOURCE, { "test_price" => [[3, [3], [1]]], "test_price_again" => [[7, [3], [1]]] })
        class ShopTest < Minitest::Test
          def test_price
            assert_equal "a b", Shop.price
          end

          def test_price_again
            assert_equal "a  b", Shop.price
          end
        end
      SOURCE

      assert_empty report.duplicates
    end

    def test_tests_in_different_classes_are_never_duplicates
      report = audit(TWO_PRICES.sub("test_price_again", "test_other"), { "test_price" => [[3, [3], [1]]] }, classes: { "ShopTest" => {}, "OtherShopTest" => {} })

      assert_empty report.duplicates, "a class's setup can change what the same body does without running a line, like its database settings"
    end

    def test_a_duplicate_has_the_same_body_past_where_it_stopped
      report = audit(<<~SOURCE, { "test_price" => [[3, [], [], {}]], "test_tax" => [[8, [], [], {}]] })
        class ShopTest < Minitest::Test
          def test_price
            return unless ready?
            assert_equal 2, Shop.price
          end

          def test_tax
            return unless ready?
            assert_equal 1, Shop.tax
          end
        end
      SOURCE

      assert_empty report.duplicates, "where neither got past the guard, a class that's ready runs them differently"
    end

    def test_a_test_a_subclass_inherits_isnt_a_duplicate_in_its_own_class
      report = audit(TWO_PRICES, { "test_price" => [[3, [3], [1]]], "test_price_again" => [[7, [3], [1]]] },
                     classes: { "ShopTest" => {}, "ShopTest::Grouped" => { inherited_from: "ShopTest" } })

      assert_equal 2, report.inherited.size
      assert_empty report.duplicates, "deleting it deletes the subclass's too"
    end

    def test_a_rescue_is_part_of_the_body
      report = audit(<<~SOURCE, { "test_price" => [[3, [3], [1]]], "test_price_again" => [[9, [3], [1]]] })
        class ShopTest < Minitest::Test
          def test_price
            assert_equal 2, Shop.price
          rescue ArgumentError
            flunk "no price"
          end

          def test_price_again
            assert_equal 2, Shop.price
          rescue ArgumentError
            pass
          end
        end
      SOURCE

      assert_empty report.duplicates, "neither raised, and only one would fail if it did"
    end

    def test_a_block_s_parameters_are_part_of_the_body
      report = audit(<<~SOURCE, { "test_price" => [[3, [3], [1]]], "test_price_again" => [[6, [3], [1]]] })
        class ShopTest < Minitest::Test
          define_method(:test_price) do |limit = 1|
            assert Shop.price < limit
          end
          define_method(:test_price_again) do |limit = 500|
            assert Shop.price < limit
          end
        end
      SOURCE

      assert_empty report.duplicates
    end

    def test_a_test_that_asks_for_its_name_has_no_duplicate
      report = audit(<<~SOURCE, { "test_price" => [[7, [3], [1]]], "test_price_again" => [[11, [3], [1]]] }, setups: { "test_price" => [3], "test_price_again" => [3] })
        class ShopTest < Minitest::Test
          def setup
            @limit = name.end_with?("again") ? 500 : 1
          end

          def test_price
            assert Shop.price < @limit
          end

          def test_price_again
            assert Shop.price < @limit
          end
        end
      SOURCE

      assert_empty report.duplicates, "the setup gave each a different limit"
    end

    def test_a_test_thats_failing_or_changed_since_it_passed_isnt_read
      report = audit(TWO_PRICES, { "test_price" => [[3, [3], [1]]], "test_price_again" => [[7, [3], [1]]] },
                     shas: { "test_price_again" => "0" * 40 }, marks: { %w[ShopTest test_price] => Set["a"] })

      assert_equal %w[ShopTest#test_price ShopTest#test_price_again], report.outdated
      assert_equal 0, report.tests
    end

    def test_a_body_reading_a_local_from_around_it_has_no_duplicate
      report = audit(<<~SOURCE, { "test_price" => [[4, [3], [1]]], "test_price_again" => [[7, [3], [1]]] })
        class ShopTest < Minitest::Test
          [2].each do |price|
            define_method(:test_price) do
              assert_equal price, Shop.price
            end
            define_method(:test_price_again) do
              assert_equal price, Shop.price
            end
          end
        end
      SOURCE

      assert_empty report.duplicates, "what the loop handed it isn't in the source"
    end

    def test_a_test_a_subclass_inherits_is_listed_with_the_class_its_from
      classes = { "ShopTest" => {}, "ShopTest::Grouped" => { inherited_from: "ShopTest" }, "ShopTest::Logged" => { inherited_from: "ShopTest", ran: [12] } }
      report = audit(<<~SOURCE, { "test_price" => [[3, [3], [1]]] }, classes: classes)
        class ShopTest < Minitest::Test
          def test_price
            assert_equal 2, Shop.price
          end
        end
      SOURCE

      assert_equal [["ShopTest::Grouped#test_price", "ShopTest"], ["ShopTest::Logged#test_price", "ShopTest"]], report.inherited.map { [_1.test, _1.from] }.sort
      assert_empty report.duplicates, "an inherited test is listed once, with the class it's from"
    end

    def test_a_test_the_class_its_from_never_ran_is_the_subclass_s_own
      report = audit(TWO_PRICES, { "test_price" => [[3, [3], [1]]], "test_price_again" => [[7, [3], [1]]] },
                     classes: { "ShopTest::Concrete" => { inherited_from: "ShopTest" } })

      assert_empty report.inherited, "a base class that only lends its tests runs none of them"
      assert_equal ["ShopTest::Concrete#test_price_again"], report.duplicates.map(&:test)
    end

    def test_a_body_that_ran_no_assertions_or_mocks_checks_nothing
      report = audit(<<~SOURCE, { "test_warm" => [[3, [12]]], "test_guarded" => [[7, []]] })
        class ShopTest < Minitest::Test
          def test_warm
            Shop.log
          end

          def test_guarded
            return unless ready?
            assert Shop.open?
          end
        end
      SOURCE

      assert_equal %w[ShopTest#test_guarded ShopTest#test_warm], report.unchecked, "a guard that returned ran no assertion"
    end

    def test_assertions_on_a_write_that_builds_on_earlier_assertions_are_a_step
      source = +"class ShopTest < Minitest::Test\n  def test_flow\n"
      statements = (3..18).map do |line|
        source << (line.even? ? "    assert Shop.open?\n" : "    Shop.log\n")
        line.even? ? [line, [7], [1]] : [line, [12], [], { wrote: true }]
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

    def test_a_megalith_is_priced_by_the_changes_that_would_have_picked_it
      in_repo do |root|
        write_and_commit(root, "app/shop.rb", "class Shop\n  def self.price = 1\n  def self.tax = 1\nend\n", message: "start")
        write_and_commit(root, "app/shop.rb", "class Shop\n  def self.price = 2\n  def self.tax = 1\nend\n", message: "price")
        write_and_commit(root, "app/shop.rb", "class Shop\n  def self.price = 3\n  def self.tax = 1\nend\n", message: "price again")
        write_and_commit(root, "app/shop.rb", "class Shop\n  def self.price = 3\n  def self.tax = 2\nend\n", message: "tax")
        write_and_commit(root, "app/other.rb", "class Other\nend\n", message: "a file nothing recorded")
        git = Git.new(root)
        layout = Layout.new(root: root)
        history = Audit::History.new(git: git, analyzer: Analyzer.new(layout: layout, blobs: git.method(:read), load_facts: ->(_) {}),
                                     layout: layout, branch: "HEAD", since: "1 year ago")
        source = +"class ShopTest < Minitest::Test\n  def test_flow\n"
        statements = (3..18).map do |line|
          source << (line.even? ? "    assert Shop.price\n" : "    Shop.tax\n")
          line.even? ? [line, [], [1], { methods: ["Shop.price"] }] : [line, [], [], { wrote: true, methods: ["Shop.tax"], ms: 100 }]
        end
        source << "  end\nend\n"

        report = audit(source, { "test_flow" => statements }, root: root, history: history, ms: 2000)

        assert_equal 4, history.size
        megalith = report.megaliths.first
        assert_equal 3, megalith.picked, "the price changed twice and the tax once"
        assert_equal [3] * 8, megalith.parts.map(&:picked), "every step runs both"
      end
    end

    private

    # Audits +source+, written as test/shop_test.rb, with a run per test in
    # +bodies+ for each class in +classes+: { name => [[line, lines of SHOP
    # that ran, compared, options], ...] }. Each run ran its body's lines in
    # the test file, plus the ones in +setups+, and its class's +ran+ lines
    # of SHOP. A body runs from the line before its first statement to the
    # one after its last, or is the one line in +lines+. A run in +shas+
    # recorded that version of the test file, and +marks+ are open failures.
    def audit(source, bodies, root: nil, history: nil, ms: 1000, classes: { "ShopTest" => {} }, setups: {}, lines: {}, shas: {}, marks: {})
      run = lambda do |dir|
        write_and_commit(dir, "app/shop.rb", SHOP, message: "shop") unless File.exist?(File.join(dir, "app/shop.rb"))
        sha = Diff.blob_sha(File.join(dir, "app/shop.rb"))
        FileUtils.mkdir_p(File.join(dir, "test"))
        File.write(File.join(dir, "test/shop_test.rb"), source)
        test_sha = Diff.blob_sha(File.join(dir, "test/shop_test.rb"))
        model = Index::Model.new
        classes.each do |klass, options|
          bodies.each do |name, statements|
            body = statements.map do |line, lines, compared = [], extra = {}|
              facets = { "sha" => sha }
              facets["lines"] = lines if lines.any?
              facets["methods"] = extra[:methods] if extra[:methods]
              set = facets.size > 1 ? model.add_set({ "app/shop.rb" => facets }, []) : nil
              Statement.new(line: line, set: set, ms: extra.fetch(:ms, 0), compared: compared, wrote: extra.fetch(:wrote, false), reads: [])
            end
            own = (lines.key?(name) ? [lines[name]] : (statements.first.first - 1..statements.last.first + 1).to_a) + setups.fetch(name, [])
            files = { "test/shop_test.rb" => { "sha" => shas.fetch(name, test_sha), "lines" => own } }
            files["app/shop.rb"] = { "sha" => sha, "lines" => options[:ran] } if options[:ran]
            model.add_run(test: [klass, name], at: 1.0, sets: body.filter_map(&:set), files: files, constants: [], file: "test/shop_test.rb",
                          body: body, ms: ms, body_line: lines.fetch(name, statements.first.first - 1), inherited_from: options[:inherited_from])
          end
        end
        Audit.new(indexes: [Index.of(model.encode, marks: marks)], git: Git.new(dir), root: dir, history: history).run
      end
      root ? run.(root) : in_repo { |dir| run.(dir) }
    end
  end
end
