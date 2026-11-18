# frozen_string_literal: true

require "digest"
require "json"
require "prism"
require "set"

module Riptide
  # Finds the tests to remove and the tests worth taking apart, from what
  # riptide records for every run. It only reports what the runs prove.
  #
  # Only a test's newest passing run of the file as it is now counts. One
  # that's failing, or last passed on an older version of its file, isn't
  # what's there anymore.
  #
  # An inherited test runs again in every test class that subclasses the
  # one it's from, which nesting a class to group tests does without saying
  # so. One the class it's from never ran, like a base class's that only its
  # subclasses run, is the subclass's own.
  #
  # A duplicate is the same program as a test in its class that stays: its
  # method or block as written, everything it ran outside that, down to the
  # lines, and the values each of its checks compared. Within one class,
  # both share everything the class sets up, run or not. A test can't be
  # compared that way when something it runs reads what isn't in the
  # source: a local from around its body, like a test defined in a loop, or
  # the test's own name. A test a subclass inherits is never the one to
  # delete, since deleting it deletes theirs.
  #
  # A megalith is a big test, and it's one of two shapes: steps that build
  # on each other, which split into a test per step, or one scenario, often
  # with setup copied from its neighbors. Everything is priced by how long a
  # test takes times how many changes in the branch's history would have
  # picked it.
  class Audit
    CHECK = /\A(assert|refute|must_|wont_)/
    # Tokens that don't change what a statement says.
    SKIPPED = %i[COMMENT NEWLINE IGNORED_NEWLINE EMBDOC_BEGIN EMBDOC_LINE EMBDOC_END EOF __END__].freeze
    # What a test calls to ask for its own name.
    NAMES = %i[name method_name __method__].freeze
    # Tests this big count as megaliths.
    BIG = 15
    # Setup lines a big test has to share with its neighbors to be worth a
    # helper.
    SHARED = 5

    # +check+ is a statement written as an assertion or one that ran one,
    # like a helper's, and +mock+ one that set up a mock expectation.
    Statement = Struct.new(:line, :source, :check, :mock, :compared, :holder, :ms, :wrote, keyword_init: true) do
      def checks? = check || mock
    end

    # +statements+ are the ones that ran and +written+ the whole method or
    # block. +run+ is the run's id, +around+ it plus its sets outside the
    # body, +span+ the body's lines, and +unseen+ whether it reads something
    # the source doesn't hold, like a local from around it or its own name.
    Test = Struct.new(:name, :file, :ms, :statements, :written, :index, :run, :around, :span, :unseen, :inherited_from, keyword_init: true)

    Copy = Struct.new(:test, :from, :ms, :picked, keyword_init: true)
    # +of+ is the test that stays.
    Duplicate = Struct.new(:test, :of, :ms, :picked, keyword_init: true)
    Part = Struct.new(:lines, :statements, :ms, :picked, keyword_init: true)
    Megalith = Struct.new(:test, :shape, :statements, :checks, :ms, :picked, :parts, :saved_ms, :shared_with, :shared_lines, keyword_init: true)

    # +outdated+ are the tests that are failing or last passed on an older
    # version of their file.
    Report = Struct.new(:tests, :unread, :outdated, :inherited, :duplicates, :unchecked, :megaliths, :changes, keyword_init: true) do
      def to_s(top: 25)
        skipped = [(", #{unread.size} couldn't be" if unread.any?), (", #{outdated.size} failing or changed since they passed" if outdated.any?)].join
        out = ["#{tests} tests read#{skipped}, priced against #{changes} changes", ""]
        heading(out, "Inherited", "tests a class runs again because it subclasses the test class they're from", inherited)
        inherited.group_by { |copy| [copy.test.split("#").first, copy.from] }.sort_by { |_, copies| -cost(copies) }.each do |(klass, from), copies|
          out << format("  %s inherits %d from %s: %.1fs, %.1fs over the changes", klass, copies.size, from, copies.sum(&:ms) / 1000.0, cost(copies) / 1000.0)
          copies.sort_by(&:test).each { |copy| out << "    #{copy.test.split("#", 2).last}" }
        end
        heading(out << "", "Duplicates", "the same body, run the same way, checking the same values, as a test in its class that stays", duplicates)
        duplicates.each do |duplicate|
          out << format("  %s: %.2fs, picked %d times", duplicate.test, duplicate.ms / 1000.0, duplicate.picked)
          out << "    same as #{duplicate.of}"
        end
        out << "" << "Checks nothing (#{unchecked.size})"
        unchecked.each { |name| out << "  #{name}" }
        shown = megaliths.first(top)
        out << "" << "Megaliths (#{shown.size} of #{megaliths.size}, costliest first)"
        shown.each do |m|
          out << format("  %s: %d statements, %d checks, %.2fs, picked %d times", m.test, m.statements, m.checks, m.ms / 1000.0, m.picked)
          if m.shape == :steps
            out << format("    %d steps that build on each other; a split costs %.1fs and names the failing step", m.parts.size, -m.saved_ms / 1000.0)
          else
            out << "    one scenario"
          end
          out << "    shares setup lines #{m.shared_lines.join(",")} with #{m.shared_with.join(", ")}" if m.shared_with.any?
        end
        out.join("\n")
      end

      private

      def cost(found) = found.sum { _1.ms * _1.picked }

      def heading(out, title, rule, found)
        out << format("%s (%d, %.1fs a build, %.1fs over the changes): %s", title, found.size, found.sum(&:ms) / 1000.0, cost(found) / 1000.0, rule)
      end
    end

    # +indexes+ are the units fetch brought. +history+ prices tests, or nil.
    def initialize(indexes:, git:, root:, history: nil)
      @indexes = indexes.reject { |index| index.runs.empty? }
      @git = git
      @root = root
      @history = history
      @models = {}
      @facts = {}
      @current = {}
      @named = {}
    end

    def run
      tests, unread, outdated = read
      by_name = tests.to_h { |test| [test.name, test] }
      originals = tests.to_h { |test| [test, test.inherited_from && by_name["#{test.inherited_from}##{test.name.split("#", 2).last}"]] }
      copies, own = tests.partition { |test| originals[test] }
      Report.new(tests: tests.size, unread: unread, outdated: outdated, inherited: inherited(copies), duplicates: duplicates(own, originals.values.compact.to_set),
                 unchecked: tests.reject { |test| test.statements.any?(&:checks?) }.map(&:name).sort,
                 megaliths: megaliths(tests), changes: @history&.size || 0)
    end

    private

    # Each test's newest run, wherever it came from, read a file version at
    # a time, since a version's syntax tree is big and only its tests need
    # it. A model decodes its whole index, so each is read once.
    def read
      newest = {}
      failing = Set.new
      @indexes.each do |index|
        model = @models[index] = index.model
        failing.merge(index.marks.keys)
        model.runs.each do |test, runs|
          id, run = runs.max_by { |_, holder| holder.at }
          newest[test] = [index, model, id, run] if !newest[test] || newest[test].last.at < run.at
        end
      end
      @test_files = newest.values.flat_map { |_, model, _, run| [model.test_files[run.test], run.body_file] }.compact.to_set
      unread = []
      outdated = []
      versions = Hash.new { |h, k| h[k] = [] }
      newest.each do |test, (index, model, id, run)|
        file = run.body_file || model.test_files[run.test]
        next unread << test.join("#") unless file && run.body_line && run.body.any?

        sha = pinned(model, run, file)
        next outdated << test.join("#") if failing.include?(test) || (sha && sha != current(file))

        versions[[file, sha]] << [index, model, id, run]
      end
      tests = versions.flat_map do |(file, sha), runs|
        text = text_of(file, sha)
        program, tokens = text && parsed(text)
        @named[[file, sha]] ||= program ? named(program) : Set.new
        runs.filter_map do |index, model, id, run|
          found = program && test_of(index, model, id, run, file, program, tokens)
          unread << run.test.join("#") unless found
          found || nil
        end
      end
      [tests, unread.sort, outdated.sort]
    end

    def test_of(index, model, id, run, file, program, tokens)
      node = body_at(program, run.body_line)
      return unless node

      nodes = body_statements(node).to_h { |statement| [statement.location.start_line, statement] }
      statements = run.body.map do |recorded|
        statement = nodes.fetch(recorded.line)
        calls = calls_in(statement)
        mock = calls.include?("expects")
        Statement.new(line: recorded.line, source: written(statement, tokens), mock: mock,
                      check: !mock && (calls.any? { |name| name.match?(CHECK) } || recorded.compared.any?),
                      compared: recorded.compared, holder: recorded.set, ms: recorded.ms, wrote: recorded.wrote)
      end
      own = run.body.filter_map(&:set).to_set
      span = node.location.start_line..last_line(node)
      Test.new(name: run.test.join("#"), file: file, ms: run.ms.to_i, statements: statements, written: written(node, tokens), index: index, run: id,
               around: [id, *run.sets.reject { |set| own.include?(set) }], span: span,
               unseen: captures?(node) || reads_name?(model, run, file, span), inherited_from: run.inherited_from)
    rescue KeyError
      nil
    end

    # The version of +file+ the run recorded, or nil when the file isn't
    # one riptide records.
    def pinned(model, run, file)
      ([run] + run.sets.map { |id| model.set(id) }).filter_map { |holder| holder.files.dig(file, "sha") }.first
    end

    # +file+ at +sha+, or as it is on disk, which is the same version when
    # the run's is current.
    def text_of(file, sha)
      (sha && @git.read(sha)) || (File.read(File.join(@root, file)) if File.file?(File.join(@root, file)))
    end

    def current(file)
      @current.fetch(file) { @current[file] = File.file?(full = File.join(@root, file)) ? Diff.blob_sha(full) : nil }
    end

    # The file's syntax tree, and its tokens in order without comments and
    # line breaks, as [type, value, offset].
    def parsed(text)
      program, tokens = Prism.parse_lex(text).value
      [program, tokens.filter_map { |token, _| [token.type, token.value, token.location.start_offset] unless SKIPPED.include?(token.type) }.sort_by(&:last)]
    end

    # The method or block whose body starts at +line+, the way the recorder
    # found it: the outermost one starting there, or whose call does.
    def body_at(node, line)
      return node if (node.is_a?(Prism::DefNode) || node.is_a?(Prism::BlockNode)) && node.location.start_line == line
      return node.block if node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode) && node.location.start_line == line

      node.compact_child_nodes.each do |child|
        found = body_at(child, line)
        return found if found
      end
      nil
    end

    def body_statements(node)
      body = node.body
      body = body.statements if body.is_a?(Prism::BeginNode)
      body.is_a?(Prism::StatementsNode) ? body.body : [body].compact
    end

    def calls_in(node)
      calls = Set.new
      walk = lambda do |inner|
        calls << inner.name.to_s if inner.is_a?(Prism::CallNode)
        inner.compact_child_nodes.each(&walk)
      end
      walk.(node)
      calls
    end

    # Whether a block body reads or sets a local from around it. A local's
    # depth counts the blocks out to where it lives, so one deeper than the
    # blocks inside the body lives outside it. A method's body can't.
    def captures?(node)
      return false if node.is_a?(Prism::DefNode)

      walk = lambda do |inner, depth|
        return true if inner.class.name.start_with?("Prism::LocalVariable") && inner.respond_to?(:depth) && inner.depth > depth

        inside = inner.is_a?(Prism::BlockNode) || inner.is_a?(Prism::LambdaNode) ? depth + 1 : depth
        inner.compact_child_nodes.any? { |child| walk.(child, inside) }
      end
      node.compact_child_nodes.any? { |child| walk.(child, 0) }
    end

    # Whether the test's body, or test code it ran, asks for the test's
    # name, which tells two tests apart without a line of difference. Code
    # that ran outside every test, in a class's or the process's setup,
    # had no test to ask about.
    def reads_name?(model, run, file, span)
      return true if @named.fetch([file, pinned(model, run, file)], Set.new).any? { |line| span.cover?(line) }

      ([run] + run.sets.map { |id| model.set(id) }.reject(&:scope)).any? do |holder|
        holder.files.any? do |path, facets|
          @test_files.include?(path) && facets["lines"]&.any? { |line| named_at(path, facets["sha"]).include?(line) }
        end
      end
    end

    def named_at(path, sha)
      @named.fetch([path, sha]) do
        text = text_of(path, sha)
        @named[[path, sha]] = text ? named(Prism.parse(text).value) : Set.new
      end
    end

    # The lines that ask for the running test's name.
    def named(program)
      lines = Set.new
      walk = lambda do |node|
        if node.is_a?(Prism::CallNode) && NAMES.include?(node.name) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) && node.arguments.nil?
          lines << node.location.start_line
        end
        node.compact_child_nodes.each(&walk)
      end
      walk.(program)
      lines
    end

    # A method or block as its tokens, from after a method's name, so
    # spacing and comments don't count but what's inside a string does, a
    # heredoc's body too.
    def written(node, tokens)
      from = node.is_a?(Prism::DefNode) ? node.name_loc.end_offset : node.location.start_offset
      to = ends(node)
      first = tokens.bsearch_index { |token| token.last >= from } || tokens.size
      tokens[first..].take_while { |token| token.last < to }.map { |type, value, _| [type, value] }
    end

    # The last line of +node+, past any heredoc it opens.
    def last_line(node)
      own = node.respond_to?(:heredoc?) && node.heredoc? && node.closing_loc ? node.closing_loc.start_line : node.location.end_line
      node.compact_child_nodes.map { |child| last_line(child) }.push(own).max
    end

    # Where +node+ ends, past any heredoc it opens.
    def ends(node)
      own = node.respond_to?(:heredoc?) && node.heredoc? && node.closing_loc ? node.closing_loc.end_offset : node.location.end_offset
      node.compact_child_nodes.map { |child| ends(child) }.push(own).max
    end

    # Inherited and duplicate tests

    def inherited(copies)
      copies.map { |copy| Copy.new(test: copy.name, from: copy.inherited_from, ms: copy.ms, picked: picked(copy, copy.statements.each_index)) }
    end

    # Of each set of tests in a class that are the same program, the first
    # by name stays. One that +lent+ to a subclass stays too, since deleting
    # it deletes the subclass's, which runs another way.
    def duplicates(tests, lent)
      tests.reject(&:unseen).group_by { |test| [test.name.split("#").first, program(test)] }.values.select { |same| same.size > 1 }.flat_map do |same|
        stays, *rest = same.sort_by(&:name)
        rest.reject { |test| lent.include?(test) }.map do |test|
          Duplicate.new(test: test.name, of: stays.name, ms: test.ms, picked: picked(test, test.statements.each_index))
        end
      end.sort_by { |duplicate| [-duplicate.ms * duplicate.picked, -duplicate.ms, duplicate.test] }
    end

    # The test as written, which of its statements ran and what their checks
    # compared, and what it ran outside its own body. A test file's code
    # counts by its lines alone, since the classes it names are the test's,
    # which every copy names differently.
    def program(test)
      model = @models.fetch(test.index)
      run = model.set(test.run)
      ran = [facts(run, test.file, test.span)] + run.sets.map { |id| @facts[[test.index, id]] ||= facts(model.set(id), nil, nil) }
      [test.written, test.statements.map { |statement| [statement.line - test.span.first, statement.compared] }, ran.compact.sort]
    end

    # A digest of what +holder+ ran, leaving out the lines in +span+ of
    # +body_file+, or nil when that's nothing.
    def facts(holder, body_file, span)
      files = holder.files.filter_map do |path, facets|
        next [path, facets] unless @test_files.include?(path)

        lines = Array(facets["lines"])
        lines = lines.reject { |line| span.cover?(line) } if path == body_file
        [path, { "sha" => facets["sha"], "lines" => lines }] if lines.any?
      end
      return if files.empty? && holder.constants.empty?

      Digest::SHA1.hexdigest(JSON.generate([holder.scope, files, holder.constants.sort]))
    end

    # Megaliths

    def megaliths(tests)
      shared = shared_setup(tests)
      tests.filter_map do |test|
        next if test.statements.size < BIG

        megalith = Megalith.new(test: test.name, statements: test.statements.size, checks: test.statements.count(&:checks?), ms: test.ms,
                                picked: picked(test, test.statements.each_index), shared_with: shared.dig(test.name, :with) || [],
                                shared_lines: shared.dig(test.name, :lines) || [])
        if (stages = steps(test)).size > 1
          priced(megalith, test, stages.each_index.map { |k| stages[0..k].flatten })
        else
          megalith.shape = :scenario
        end
        megalith
      end.sort_by { |megalith| -megalith.ms * megalith.picked }
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

    def priced(megalith, test, parts)
      megalith.shape = :steps
      around = [test.ms - test.statements.sum(&:ms), 0].max
      megalith.parts = parts.map do |indexes|
        Part.new(lines: indexes.map { test.statements[_1] }.select(&:checks?).map(&:line), statements: indexes.size,
                 ms: around + indexes.sum { test.statements[_1].ms }, picked: picked(test, indexes))
      end
      megalith.saved_ms = megalith.picked * megalith.ms - megalith.parts.sum { |part| part.picked * part.ms }
    end

    def picked(test, indexes)
      return 0 unless @history

      @history.picks(test.index, test.around + indexes.filter_map { test.statements[_1].holder })
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
