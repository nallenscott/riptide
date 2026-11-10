# frozen_string_literal: true

require "test_helper"

module Riptide
  class IndexTest < Minitest::Test
    Model = Index::Model

    def test_postings_are_gaps_between_sorted_ids
      assert_equal [3, 4, 1], Index.gaps([8, 3, 7])
      assert_equal [3, 7, 8], Index.ids([3, 4, 1])
    end

    def test_a_model_survives_a_round_trip_through_the_tree
      model = Model.new
      env = model.add_set({ "Gemfile.lock" => { "sha" => "g1", "whole" => true }, "glob:config/**/*" => { "sha" => "l1" } }, ["Rails"])
      owner = model.add_set({ "app/card.rb" => { "sha" => "c1", "owners" => ["Card"] } }, [])
      empty = model.add_set({}, [])
      model.add_run(test: %w[CardTest test_a], at: 2.0, sets: [env, owner, empty], file: "test/card_test.rb",
                    files: { "app/card.rb" => { "sha" => "c1", "methods" => ["Card#b", "Card#a"], "blocks" => [12, 3] },
                             "const:Card Missing" => { "sha" => "absent" } },
                    constants: ["Card::LIMIT", "*::NAME"])
      model.add_run(test: %w[CardTest test_a], at: 1.0, sets: [env], files: {}, constants: [])
      model.merge_loads("c1", { "3" => { "owners" => ["Card"], "called" => false } })

      decoded = Index.of(model.encode).model

      assert_equal model.holders.transform_values(&:to_h), decoded.holders.transform_values(&:to_h)
      assert_equal model.loads, decoded.loads
      assert_equal({ %w[CardTest test_a] => "test/card_test.rb" }, decoded.test_files)
      assert_equal model.encode, decoded.encode, "decoding and encoding again writes the same tree"
    end

    def test_every_directory_is_sharded
      model = Model.new
      model.add_run(test: %w[ATest test_a], at: 1.0, sets: [], files: { "a.rb" => { "sha" => "a1b2" } }, constants: ["A"])
      model.merge_loads("a1b2", { "1" => { "owners" => ["A"], "called" => true } })

      expected = ["files/a1", "loads/a1", "manifest/#{Index.shard("a.rb")}", "meta", "names/#{Index.shard("A")}", "tests/#{Index.shard(Index.test_key(%w[ATest test_a]))}"]
      assert_equal expected.sort, model.encode.keys.sort
    end

    def test_a_new_run_takes_the_next_id_after_a_round_trip
      model = Model.new
      model.add_run(test: %w[ATest test_a], at: 1.0, sets: [], files: { "a.rb" => { "sha" => "a1" } }, constants: [])
      decoded = Index.of(model.encode).model
      id = decoded.add_run(test: %w[ATest test_b], at: 1.0, sets: [], files: {}, constants: [])

      assert_equal 1, id
    end

    def test_retention_drops_sets_and_load_facts_nothing_uses
      model = Model.new
      set = model.add_set({ "old.rb" => { "sha" => "o1" } }, [])
      model.add_run(test: %w[ATest test_a], at: 1.0, sets: [set], files: {}, constants: [])
      model.add_run(test: %w[ATest test_a], at: 2.0, sets: [], files: { "new.rb" => { "sha" => "n1" } }, constants: [])
      model.merge_loads("o1", { "1" => { "owners" => [], "called" => true } })
      model.retain(1)

      assert_equal [2.0], model.runs.values.flatten(1).map { |_, run| run.at }
      assert_empty model.loads
      assert_equal Set["n1"], model.versions
    end

    # The index lookup selects exactly what checking every run against the
    # tree one by one does, over random runs, sets and changes.
    def test_lookups_select_what_a_plain_evaluation_of_each_run_does
      Dir.mktmpdir do |root|
        200.times do |seed|
          random = Random.new(seed)
          scenario = Scenario.new(random, root)
          indexes = scenario.models.zip(scenario.marks).map { |model, marks| Index.of(model.encode, marks: marks) }
          selector = Selector.new(indexes: indexes, analyzer: scenario, root: root, tests: scenario.tests, listing: scenario.method(:listing))
          decision = selector.select

          assert_equal scenario.expected, decision.selected.map { |entry| entry[:test] }.sort, "seed #{seed}"
        end
      end
    end

    # Random runs in one to three refs over a handful of files, a tree
    # where some of those files moved on, and an analyzer that says what
    # changed.
    class Scenario
      PATHS = %w[app/a.rb app/b.rb app/c.rb app/d.rb lib/e.rb].freeze
      PSEUDO = ["glob:app/**/*.rb", "const:Object RiptideIndexTestMissing", "const:Object String"].freeze
      NAMES = %w[A::LIMIT B::MAX C::NAME].freeze

      attr_reader :models, :marks, :tests

      def initialize(random, root)
        @random = random
        @versions = PATHS.to_h { |path| [path, Array.new(3) { |i| format("%040x", random.rand(2**64) + i) }] }
        @current = {}
        PATHS.each do |path|
          full = File.join(root, path)
          FileUtils.mkdir_p(File.dirname(full))
          if random.rand < 0.1
            File.delete(full) if File.exist?(full)
            @current[path] = nil
          else
            File.write(full, "content #{random.rand}\n")
            @current[path] = Diff.blob_sha(full)
          end
        end
        @listing = random.rand < 0.2 ? "new" : "old"
        @changes = {}
        @tests = Array.new(8) { |i| ["T#{i % 3}Test", "test_#{i}"] }
        @models = Array.new(random.rand(1..3)) { build_model }
        @marks = @models.map { @tests.select { random.rand < 0.15 }.to_h { |test| [test, Set[format("%032x", random.rand(2**64))]] } }
      end

      def listing(_pattern) = @listing

      # The Analyzer's half: what changed from +version+ to the tree.
      def change(path, version)
        return @changes[[path, version]] if @changes.key?([path, version])

        @changes[[path, version]] = begin
          change = Change.new
          roll = @random.rand
          if roll < 0.03 then nil
          elsif roll < 0.04 then change.tap(&:suite!)
          elsif roll < 0.1 then change.tap(&:whole!)
          else
            Index::FACETS.each { |facet| change.public_send(facet) << value(facet) if @random.rand < 0.3 }
            change.constants << NAMES.sample(random: @random) if @random.rand < 0.3
            change
          end
        end
      end

      # The selection worked out run by run: a test runs when it has an open
      # failure anywhere, or no passing run that still holds.
      def expected
        runs = @models.flat_map { |model| model.runs.values.flatten(1).map { |_, run| [run, hit?(model, run)] } }
        return @tests.sort if runs.any? { |_, hit| hit == :suite }

        @tests.select do |test|
          next true if @marks.any? { |marks| marks.key?(test) }

          mine = runs.select { |run, _| run.test == test }
          mine.empty? || mine.all? { |_, hit| hit }
        end.sort
      end

      private

      def value(facet) = facet == "blocks" ? @random.rand(1..4) : "#{facet}#{@random.rand(1..4)}"

      def build_model
        model = Model.new
        sets = Array.new(3) { model.add_set(*holder_parts) }
        @tests.each do |test|
          @random.rand(0..3).times do |i|
            model.add_run(test: test, at: @random.rand * 100 + i, sets: sets.sample(@random.rand(0..2), random: @random),
                          files: holder_parts.first, constants: holder_parts.last)
          end
        end
        model.retain(4)
        model
      end

      def holder_parts
        files = PATHS.sample(@random.rand(0..3), random: @random).to_h do |path|
          current = @current[path] && @random.rand < 0.6
          facets = { "sha" => current ? @current[path] : @versions[path].sample(random: @random) }
          facets["whole"] = true if @random.rand < 0.1
          Index::FACETS.each { |facet| facets[facet] = Array.new(@random.rand(1..2)) { value(facet) }.uniq if @random.rand < 0.4 }
          [path, facets]
        end
        PSEUDO.sample(@random.rand(0..1), random: @random).each do |path|
          files[path] = { "sha" => path.start_with?("glob:") ? %w[old new].sample(random: @random) : "absent" }
        end
        constants = NAMES.sample(@random.rand(0..2), random: @random)
        constants << "*::#{NAMES.sample(random: @random).split("::").last}" if @random.rand < 0.2
        [files, constants]
      end

      def hit?(model, run)
        groups = run.sets.map { |id| model.set(id) } << run
        read = groups.flat_map { |holder| holder.constants.to_a }.to_set
        results = groups.flat_map { |holder| holder.files.map { |path, facets| file_hit(path, facets, read) } }
        results.include?(:suite) ? :suite : results.any?
      end

      def current(path) = path.start_with?("glob:") ? @listing : (Env.constant?(path) ? Env.presence(path) : @current[path])

      def file_hit(path, facets, read)
        current = current(path)
        return false if current == facets["sha"]
        return true if Env.pseudo?(path) || current.nil?

        change = change(path, facets["sha"])
        return true if change.nil?
        return false if change.empty?
        return :suite if change.suite?
        return true if change.whole? || facets["whole"]
        return true if Index::FACETS.any? { |facet| facets[facet]&.any? { |name| change.public_send(facet).include?(name) } }

        change.constants.any? { |name| read.include?(name) || read.include?("*::#{name.split("::").last}") }
      end
    end
  end
end
