# frozen_string_literal: true

require "prism"
require "set"

module Riptide
  # Finds the tests to remove and the tests worth taking apart, from the
  # statements riptide records for every run's test body.
  #
  # A check is an assertion or mock expectation. It's the check as written,
  # the earlier statements it depends on as written, the app code they
  # reached and the values it compared. A test is removable when every check
  # it makes is also made by a test that stays.
  #
  # A megalith is a big test, and it's one of three shapes: independent
  # scenarios that split apart, steps that build on each other, or one
  # scenario, often with setup copied from its neighbors. Each is ranked by
  # what it costs, how long it takes times how many changes in the branch's
  # history would have picked it, and so is each part of a split.
  class Audit
    CHECK = /\A(assert|refute|must_|wont_)/
    # Tests this big count as megaliths whatever their shape.
    BIG = 15
    # Setup lines a big test has to share with its neighbors to be worth a
    # helper.
    SHARED = 5

    Statement = Struct.new(:line, :source, :shape, :check, :mock, :reads, :writes, :reached, :holder, :ms, :compared, :wrote, :data,
                           keyword_init: true) do
      def checks? = check || mock
    end

    Test = Struct.new(:name, :file, :ms, :statements, :around, :holders, keyword_init: true)
    Check = Struct.new(:test, :line, :key, keyword_init: true)
    Removal = Struct.new(:test, :twins, keyword_init: true)
    Part = Struct.new(:lines, :statements, :ms, :picked, keyword_init: true)
    Megalith = Struct.new(:test, :shape, :statements, :checks, :ms, :picked, :parts, :saved_ms, :shared_with, :shared_lines, keyword_init: true)

    Report = Struct.new(:tests, :unread, :removals, :unchecked, :megaliths, :changes, keyword_init: true) do
      def to_s(top: 25)
        out = ["#{tests} tests read#{unread.empty? ? "" : ", #{unread.size} couldn't be"}, priced against #{changes} changes", ""]
        out << "Removable (#{removals.size}): every check each makes, a test that stays makes too"
        removals.each do |removal|
          out << "  #{removal.test}"
          removal.twins.each { |line, twin| out << "    line #{line} is also #{twin}" }
        end
        out << "" << "Checks nothing (#{unchecked.size})"
        unchecked.each { |name| out << "  #{name}" }
        shown = megaliths.first(top)
        out << "" << "Megaliths (#{shown.size} of #{megaliths.size}, costliest first)"
        shown.each do |m|
          out << format("  %s: %d statements, %d checks, %.2fs, picked %d times", m.test, m.statements, m.checks, m.ms / 1000.0, m.picked)
          case m.shape
          when :scenarios
            out << format("    %d independent scenarios; a split %s %.1fs", m.parts.size, m.saved_ms.positive? ? "saves" : "costs", m.saved_ms.abs / 1000.0)
            m.parts.each { |part| out << format("      checks on %s: %d statements, %.2fs, picked %d", part.lines.join(","), part.statements, part.ms / 1000.0, part.picked) }
          when :steps
            out << format("    %d steps that build on each other; a split costs %.1fs and names the failing step", m.parts.size, -m.saved_ms / 1000.0)
          else
            out << "    one scenario"
          end
          out << "    shares setup lines #{m.shared_lines.join(",")} with #{m.shared_with.join(", ")}" if m.shared_with.any?
        end
        out.join("\n")
      end
    end

    # +indexes+ are the units fetch brought. +history+ prices tests, or nil.
    def initialize(indexes:, git:, root:, history: nil)
      @indexes = indexes.reject { |index| index.runs.empty? }
      @git = git
      @root = root
      @history = history
    end

    def run
      tests, unread = read
      checks = tests.to_h { |test| [test.name, checks_of(test)] }
      Report.new(tests: tests.size, unread: unread, removals: removals(tests, checks),
                 unchecked: tests.select { |test| checks[test.name].empty? }.map(&:name).sort,
                 megaliths: megaliths(tests), changes: @history&.size || 0)
    end

    private

    # Each test's newest run, wherever it came from.
    def read
      newest = {}
      @indexes.each do |index|
        model = index.model
        model.runs.each do |test, runs|
          id, run = runs.max_by { |_, holder| holder.at }
          newest[test] = [index, model, id, run] if !newest[test] || newest[test].last.at < run.at
        end
      end
      @test_files = newest.values.flat_map { |_, model, _, run| [model.test_files[run.test], run.body_file] }.compact.to_set
      unread = []
      tests = newest.filter_map do |test, (index, model, id, run)|
        found = run.body.any? && test_of(index, model, id, run)
        unread << test.join("#") unless found
        found || nil
      end
      [tests, unread.sort]
    end

    def test_of(index, model, id, run)
      file = run.body_file || model.test_files[run.test]
      nodes = file && body_nodes(file, version(model, run, file), run.body.map(&:line))
      return unless nodes

      statements = run.body.map do |recorded|
        node = nodes.fetch(recorded.line)
        reads, writes, calls = names_in(node)
        holder = recorded.set && model.set(recorded.set)
        Statement.new(line: recorded.line, source: plain(node.slice), shape: shape(node), check: calls.any? { |name| name.match?(CHECK) },
                      mock: calls.include?("expects"), reads: reads, writes: writes, reached: holder ? facts(holder.files) : Set.new,
                      holder: recorded.set, ms: recorded.ms, compared: recorded.compared.sort, wrote: recorded.wrote, data: recorded.reads)
      end
      own = run.body.filter_map(&:set).to_set
      around = run.sets.reject { |set| own.include?(set) }
      Test.new(name: run.test.join("#"), file: file, ms: run.ms.to_i, statements: statements,
               around: around.map { |set| facts(model.set(set).files) }.reduce(facts(run.files), :|), holders: [index, [id, *around]])
    rescue KeyError
      nil
    end

    # The version of +file+ the run recorded, which it pinned, or the one on
    # disk when the file isn't one riptide records.
    def version(model, run, file)
      sha = ([run] + run.sets.map { |id| model.set(id) }).filter_map { |holder| holder.files.dig(file, "sha") }.first
      (sha && @git.read(sha)) || File.read(File.join(@root, file))
    rescue SystemCallError
      nil
    end

    # { first line => statement node } for the method or block body whose
    # statements start where the run's did.
    def body_nodes(file, text, lines)
      return unless text

      found = nil
      walk = lambda do |node|
        return if found

        body = node.body if node.is_a?(Prism::DefNode) || node.is_a?(Prism::BlockNode)
        body = body.statements if body.is_a?(Prism::BeginNode)
        statements = body.is_a?(Prism::StatementsNode) ? body.body : [body].compact
        by_line = statements.to_h { |statement| [statement.location.start_line, statement] }
        found = by_line if !statements.empty? && lines.all? { |line| by_line.key?(line) }
        node.compact_child_nodes.each(&walk) unless found
      end
      walk.(Prism.parse(text).value)
      found
    end

    # Methods and blocks in the code under test. What a test's own code does
    # is in its source, which a check matches on, and its own method would
    # make every check unique.
    def facts(files)
      files.each_with_object(Set.new) do |(path, facets), all|
        next if @test_files.include?(path)

        Array(facets["methods"]).each { |method| all << method }
        Array(facets["blocks"]).each { |line| all << "#{path}:#{line}" }
      end
    end

    def names_in(node)
      reads = Set.new
      writes = Set.new
      calls = Set.new
      walk = lambda do |inner|
        case inner
        when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then reads << inner.name.to_s
        when Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::InstanceVariableOrWriteNode,
             Prism::LocalVariableOperatorWriteNode, Prism::InstanceVariableOperatorWriteNode, Prism::LocalVariableTargetNode, Prism::InstanceVariableTargetNode
          writes << inner.name.to_s
        when Prism::CallNode
          calls << inner.name.to_s
          reads << inner.name.to_s if inner.variable_call?
        end
        inner.compact_child_nodes.each(&walk)
      end
      walk.(node)
      [reads, writes, calls]
    end

    def plain(source) = source.gsub(/#.*$/, "").split.join(" ")

    # A check as written, with variables and its failure message left out,
    # so `refute @a.valid?` and `refute @b.valid?` are the same check of
    # whatever their setup made.
    def shape(node)
      case node
      when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then "v"
      when Prism::CallNode
        args = node.arguments&.arguments || []
        args = args[0...-1] if node.receiver.nil? && node.name.to_s.match?(CHECK) && args.size > 1 && message?(args.last)
        "#{node.receiver && shape(node.receiver)}.#{node.name}(#{args.map { shape(_1) }.join(",")})#{node.block && "{#{shape(node.block)}}"}"
      else
        kids = node.compact_child_nodes
        kids.empty? ? node.slice : "#{node.type}[#{kids.map { shape(_1) }.join(",")}]"
      end
    end

    def message?(node) = node.is_a?(Prism::StringNode) || node.is_a?(Prism::InterpolatedStringNode)

    # Removals

    # A check depends on the earlier statements that write what it reads,
    # call methods on it, or wrote data it read. A mock is checked by what
    # runs after it.
    def checks_of(test)
      statements = test.statements
      statements.each_index.select { |i| statements[i].checks? }.map do |i|
        linked = linked(statements, i, objects: false)
        linked |= ((i + 1)...statements.size).reject { |j| statements[j].checks? }.to_a if statements[i].mock
        reached = linked.map { |j| statements[j].reached }.reduce(statements[i].reached, :|)
        Check.new(test: test.name, line: statements[i].line,
                  key: [statements[i].shape, linked.sort.map { |j| statements[j].source }, reached.to_a.sort, statements[i].compared])
      end
    end

    # What statement +i+ depends on, by its variables and the data it read.
    # With +objects+, a statement that wrote data also counts for any object
    # +i+ reads that existed before it, since writing can change it.
    def linked(statements, i, objects:)
      vars = statements[i].reads.dup
      data = statements[i].data.to_set
      got = []
      (i - 1).downto(0) do |j|
        s = statements[j]
        next if !objects && s.checks?

        hit = s.writes.intersect?(vars) || (s.reads.intersect?(vars) && s.writes.empty?) || data.include?(j) ||
              (objects && s.wrote && vars.any? { |var| older?(statements, var, j) })
        next unless hit

        got << j
        vars |= s.reads
        data |= s.data
      end
      got
    end

    def older?(statements, var, j)
      written = statements.each_index.select { |k| statements[k].writes.include?(var) }
      written.empty? ? var.start_with?("@") : written.min < j
    end

    # Tests making the most checks stay, so the copy that goes is the one
    # that adds least.
    def removals(tests, checks)
      makers = Hash.new { |h, key| h[key] = [] }
      checks.each_value { |list| list.each { |check| makers[check.key] << check } }
      removed = Set.new
      tests.reject { |test| checks[test.name].empty? }.sort_by { |test| [checks[test.name].size, test.name] }.filter_map do |test|
        twins = checks[test.name].map { |check| makers[check.key].find { |other| other.test != test.name && !removed.include?(other.test) } }
        next unless twins.all?

        removed << test.name
        Removal.new(test: test.name, twins: checks[test.name].zip(twins).map { |mine, twin| [mine.line, "#{twin.test}:#{twin.line}"] })
      end
    end

    # Megaliths

    def megaliths(tests)
      shared = shared_setup(tests)
      tests.filter_map do |test|
        groups = scenarios(test)
        next unless test.statements.size >= BIG || groups.size > 1

        megalith = Megalith.new(test: test.name, statements: test.statements.size, checks: test.statements.count(&:checks?), ms: test.ms,
                                picked: picked(test, test.statements.each_index), shared_with: shared.dig(test.name, :with) || [],
                                shared_lines: shared.dig(test.name, :lines) || [])
        if groups.size > 1
          priced(megalith, :scenarios, test, groups)
        elsif (stages = steps(test)).size > 1
          priced(megalith, :steps, test, stages.each_index.map { |k| stages[0..k].flatten })
        else
          megalith.shape = :scenario
        end
        megalith
      end.sort_by { |megalith| -megalith.ms * megalith.picked }
    end

    # Groups of checks that do something of their own. A statement every
    # check needs is setup when it writes nothing, and the scenario itself
    # when it writes, which keeps the checks together.
    def scenarios(test)
      statements = test.statements
      checks = statements.each_index.select { |i| statements[i].checks? }
      return [] if checks.size < 2

      slices = checks.to_h do |i|
        slice = [i] + linked(statements, i, objects: true)
        ((i + 1)...statements.size).each { |j| slice |= [j] + linked(statements, j, objects: true) unless statements[j].checks? } if statements[i].mock
        [i, slice]
      end
      used = slices.values.flatten.to_set
      shared = slices.values.reduce(:&).reject { |j| statements[j].wrote } | statements.each_index.reject { |j| used.include?(j) }
      groups = checks.map { |i| [i] }
      while (pair = groups.combination(2).find { |a, b| (a.flat_map { slices[_1] } & b.flat_map { slices[_1] } - shared).any? })
        groups.delete(pair[1])
        pair[0].concat(pair[1])
      end
      own = ->(group) { (group.flat_map { slices[_1] } - shared).reject { |j| statements[j].checks? } }
      scenarios, lookers = groups.partition { |group| own.(group).any? }
      return [] if scenarios.size < 2

      scenarios.first.concat(lookers.flatten)
      scenarios.map { |group| (group.flat_map { slices[_1] } | shared).sort }
    end

    # Assertions that come after a write the later ones build on. A mock is
    # set up ahead of what it checks and verified at the end, so it never
    # ends a step.
    def steps(test)
      stages = [[]]
      checked = false
      test.statements.each_with_index do |statement, i|
        if statement.check
          checked = true
        elsif checked && statement.wrote
          stages << []
          checked = false
        end
        stages.last << i
      end
      stages.select { |stage| stage.any? { test.statements[_1].check } }
    end

    def priced(megalith, shape, test, parts)
      megalith.shape = shape
      around = [test.ms - test.statements.sum(&:ms), 0].max
      megalith.parts = parts.map do |indexes|
        Part.new(lines: indexes.map { test.statements[_1] }.select(&:checks?).map(&:line), statements: indexes.size,
                 ms: around + indexes.sum { test.statements[_1].ms }, picked: picked(test, indexes))
      end
      megalith.saved_ms = megalith.picked * megalith.ms - megalith.parts.sum { |part| part.picked * part.ms }
    end

    def picked(test, indexes)
      return 0 unless @history

      index, around = test.holders
      @history.picks(index, around + indexes.filter_map { test.statements[_1].holder })
    end

    # Setup lines a big test has word for word with others in its file.
    def shared_setup(tests)
      by_file = tests.group_by(&:file)
      tests.each_with_object({}) do |test, result|
        next if test.statements.size < BIG

        mine = test.statements.reject(&:checks?)
        others = by_file[test.file] - [test]
        with = others.select { |other| (mine.map(&:source) & other.statements.map(&:source)).size >= SHARED }
        lines = mine.select { |s| with.any? { |other| other.statements.any? { _1.source == s.source } } }.map(&:line)
        result[test.name] = { with: with.map(&:name).sort, lines: lines } if with.any? && lines.size >= SHARED
      end
    end

    # The changes a branch took, run through each index the way selection
    # runs a working tree through it: each path an index recorded, analyzed
    # from before the change to after it, and matched to the runs and sets
    # that recorded the part that changed.
    class History
      ALL = :all

      def initialize(git:, analyzer:, layout:, branch:, since:)
        @git = git
        @analyzer = analyzer
        @layout = layout
        @listings = {}
        @commits = git.output("log", "--first-parent", "--format=%H %P", "--since=#{since}", branch).lines.map(&:split).select { |_, parent| parent }
        @hits = {}
      end

      def size = @commits.size

      # How many changes reached any of +holders+, runs or sets of +index+.
      def picks(index, holders)
        hits = (@hits[index] ||= @commits.map { |commit, parent| hits_in(index, parent, commit) })
        hits.count { |hit| hit == ALL || hit.intersect?(holders) }
      end

      private

      def hits_in(index, parent, commit)
        manifest = index.manifest
        hit = Set.new
        changed(parent, commit).each do |path, old_sha, new_sha|
          if manifest.key?(path)
            versions = manifest[path]
            recorded = -> { versions.each { |version| hit.merge(index.postings(path, version)["all"]) } }
            next recorded.call if new_sha.nil?

            change = @analyzer.between(path, old_sha, new_sha)
            next recorded.call if change.nil? || change.whole?
            next if change.empty?
            return ALL if change.suite?

            versions.each { |version| index.changed_holders(path, version, change) { |_, _, ids| hit.merge(ids) } }
          end
          listed(index, path, hit) if old_sha.nil? || new_sha.nil?
        end
        hit
      end

      # A file added or removed changes the globs and fixture tables that
      # list it.
      def listed(index, path, hit)
        (@listings[index] ||= index.manifest.keys.select { |key| key.start_with?(Env::GLOB, Env::FIXTURES) }).each do |key|
          matches = if key.start_with?(Env::GLOB) then File.fnmatch?(key.delete_prefix(Env::GLOB), path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
                    elsif key.start_with?(Env::FIXTURES) then @layout.fixture?(path) && @layout.fixture_table(path, "") == key.delete_prefix(Env::FIXTURES)
                    end
          index.manifest[key].each { |version| hit.merge(index.postings(key, version)["all"]) } if matches
        end
      end

      # [path, sha before, sha after] for each file +commit+ changed, nil for
      # a side the file isn't on.
      def changed(parent, commit)
        @git.output("diff-tree", "-r", "-z", "--no-renames", "--relative", parent, commit).split("\0").each_slice(2).map do |meta, path|
          _, _, old_sha, new_sha = meta.delete_prefix(":").split
          [path, old_sha.match?(/\A0+\z/) ? nil : old_sha, new_sha.match?(/\A0+\z/) ? nil : new_sha]
        end
      end
    end
  end
end
