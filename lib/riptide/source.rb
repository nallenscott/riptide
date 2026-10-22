# frozen_string_literal: true

require "prism"
require "set"

module Riptide
  # Static structure of one version of a Ruby file: what every line belongs
  # to, which methods and constants it defines, and which constants each
  # line references.
  class Source
    # +kind+ is one of :method_header, :method_body, :block_body, :constant,
    # :declaration, :top or :data. +owner+ is the enclosing class or module,
    # +name+ the method or constant, +line+ where its statement starts and
    # +block+ where a block body's block starts. +head+ is a statement with
    # its block bodies blanked, and a block body's +parent+ is its
    # statement's unit. Units keep no syntax tree, so a cached Source stays
    # small.
    Unit = Struct.new(:kind, :owner, :name, :line, :block, :head, :parent, keyword_init: true)

    # +header+ and +body+ are line ranges.
    Method = Struct.new(:name, :owner, :header, :body, keyword_init: true)

    # A constant read: the lexical nesting it was read in, innermost last,
    # the path segments, and whether it started with ::. A +dynamic+ read,
    # like `self.class::LIMIT` or `const_get(:LIMIT)`, only knows its last
    # segment.
    Reference = Struct.new(:nesting, :segments, :absolute, :dynamic, keyword_init: true)

    CONSTANT_LOOKUPS = %i[const_get const_defined? const_source_location].freeze

    attr_reader :methods, :constants

    # nil when +text+ doesn't parse.
    def self.parse(text)
      result = Prism.parse(text)
      result.success? ? new(text, result) : nil
    end

    def initialize(text, result)
      @units = {}
      @methods = {}
      @constants = {}
      @computed = Set.new
      @declared = Hash.new { |h, k| h[k] = Set.new }
      @aliases = {}
      @block_starts = Hash.new { |h, k| h[k] = [] }
      @references = Hash.new { |h, k| h[k] = [] }
      @significant = significant_lines(text, result)

      walk_program(result.value)
      collect_references(result.value, [])
      magic_comments(result)
    end

    # nil for blank lines, comments and anything outside every unit.
    def unit_at(line)
      @significant.include?(line) ? @units[line] : nil
    end

    # Keys of the blocks that start on +line+, which is where Ruby reports a
    # block being entered.
    def blocks_starting_at(line)
      @block_starts.fetch(line, [])
    end

    # Every name a class, module or constant defined here could have at
    # runtime. A compact `class Billing::Card` inside `module Admin` is
    # Admin::Billing::Card if Admin::Billing exists and Billing::Card if it
    # doesn't, so both count.
    def names_for(name)
      @aliases.each_with_object([name]) do |(full, short), names|
        names << name.sub(full, short) if name == full || name.start_with?("#{full}::")
      end.uniq
    end

    def references_at(line)
      @references.fetch(line, [])
    end

    # Whether a class-level statement in +owner+ names +method+, the way
    # `attr_accessor :status` or `delegate :total` define one without a def.
    def declares?(owner, method)
      @declared.key?(owner) && @declared[owner].include?(method)
    end

    # Whether a constant's value came from running code, like
    # `LIMIT = Calc.base * 2`, rather than a literal.
    def computed?(name)
      @computed.include?(name)
    end

    # The statement's source with every block body blanked out, so a
    # one-line `scope :x, -> { ... }` can tell a changed lambda from a
    # changed declaration.
    def self.head_of(statement)
      text = statement.slice.b
      offset = statement.location.start_offset
      # Prism's offsets are bytes, so the cutting is too.
      block_bodies(statement).sort_by { |b| -b.location.start_offset }.each do |body|
        text.bytesplice(body.location.start_offset - offset, body.location.length, "")
      end
      text
    end

    def self.block_bodies(node)
      node.compact_child_nodes.flat_map do |child|
        if (child.is_a?(Prism::BlockNode) || child.is_a?(Prism::LambdaNode)) && child.body
          [child.body]
        else
          block_bodies(child)
        end
      end
    end

    private

    IGNORED_TOKENS = %i[COMMENT NEWLINE IGNORED_NEWLINE EMBDOC_BEGIN EMBDOC_LINE EMBDOC_END EOF].freeze

    # Lines carrying at least one real token. Heredoc content counts, a
    # comment or blank line outside a string doesn't, and everything after
    # __END__ is data the file can read.
    def significant_lines(text, result)
      lines = Set.new
      Prism.lex(text).value.each do |token, _state|
        next if IGNORED_TOKENS.include?(token.type)

        location = token.location
        if token.type == :__END__
          (location.start_line..text.count("\n") + 1).each { |line| lines << line; @units[line] = Unit.new(kind: :data) }
          break
        end
        last = location.end_column.zero? && location.end_line > location.start_line ? location.end_line - 1 : location.end_line
        (location.start_line..last).each { |line| lines << line }
      end
      lines
    end

    def mark(range, unit)
      range.each { |line| @units[line] = unit unless @units[line]&.kind == :data }
    end

    # `# frozen_string_literal: true` and its kind change how the whole file
    # runs, so they're data, not comments.
    def magic_comments(result)
      result.magic_comments.each do |comment|
        line = comment.key_loc.start_line
        @significant << line
        @units[line] = Unit.new(kind: :data)
      end
    end

    # A node's lines, including the body of any heredoc it opens: Prism
    # ends `TEXT = <<~T` on its first line.
    def lines_of(node)
      node.location.start_line..last_line(node)
    end

    def last_line(node)
      own = node.respond_to?(:closing_loc) && node.closing_loc && node.respond_to?(:heredoc?) && node.heredoc? ? node.closing_loc.start_line : node.location.end_line
      node.compact_child_nodes.map { |child| last_line(child) }.push(own).max
    end

    def walk_program(program)
      program.statements.body.each do |statement|
        case statement
        when Prism::ClassNode, Prism::ModuleNode then walk_namespace(statement, nil)
        when Prism::DefNode then define_method(statement, "Object", statement)
        # A literal top-level constant is read like any other. One whose
        # value ran code stays top-level, since that code ran at boot.
        when Prism::ConstantWriteNode
          literal?(statement.value) ? define_constant(statement, nil, statement.name.to_s) : top(statement)
        else
          top(statement)
        end
      end
    end

    def top(statement)
      unit = statement_unit(:top, nil, nil, statement)
      mark(lines_of(statement), unit)
      walk_blocks(statement, nil, parent: unit)
    end

    # No constant read and no call into the app's code. A method called on
    # a literal, like `%w[a b].freeze`, runs Ruby's own code.
    def literal?(node)
      case node
      when Prism::ConstantReadNode, Prism::ConstantPathNode then false
      when Prism::CallNode then !node.receiver.nil? && node.block.nil? && node.compact_child_nodes.all? { |child| literal?(child) }
      else node.compact_child_nodes.all? { |child| literal?(child) }
      end
    end

    def walk_namespace(node, outer)
      name = namespace_name(outer, node)
      mark(node.location.start_line..node.location.start_line, Unit.new(kind: :declaration, owner: name, line: node.location.start_line))
      walk_body(node.body, name)
    end

    # `class ::Widget` is Widget wherever it's written.
    def namespace_name(outer, node)
      path = node.constant_path.slice
      return path.delete_prefix("::") if path.start_with?("::") || outer.nil?

      name = "#{outer}::#{path}"
      @aliases[name] = path if path.include?("::")
      name
    end

    def walk_body(body, owner, singleton: false)
      statements = body.is_a?(Prism::StatementsNode) ? body.body : [body].compact
      statements.each { |statement| walk_statement(statement, owner, singleton: singleton) }
    end

    def walk_statement(statement, owner, singleton: false)
      case statement
      when Prism::ClassNode, Prism::ModuleNode
        walk_namespace(statement, owner)
      when Prism::SingletonClassNode
        mark(statement.location.start_line..statement.location.start_line, Unit.new(kind: :declaration, owner: owner, line: statement.location.start_line))
        walk_body(statement.body, owner, singleton: true)
      when Prism::DefNode
        define_method(statement, owner, statement, singleton: singleton)
      when ->(node) { defines_through_call?(node) }
        # `private def charge` and `memoize def total` define a method too.
        statement.arguments.arguments.grep(Prism::DefNode).each { |node| define_method(node, owner, statement, singleton: singleton) }
      when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode
        define_constant(statement, owner, [owner, statement.name].compact.join("::"))
      when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode
        define_constant(statement, owner, [owner, statement.target.slice.delete_prefix("::")].compact.join("::"))
      when ->(node) { node.is_a?(Prism::MultiWriteNode) && constant_targets(node).any? }
        define_constant(statement, owner, constant_targets(statement).map { |target| [owner, target.slice.delete_prefix("::")].compact.join("::") })
      else
        unit = statement_unit(:declaration, owner, nil, statement)
        mark(lines_of(statement), unit)
        walk_blocks(statement, owner, parent: unit)
        declared(statement, owner)
        nested_constants(statement, owner)
      end
    end

    def constant_targets(node)
      (node.lefts + [node.rest&.expression].compact + node.rights).grep(Prism::ConstantTargetNode) +
        (node.lefts + node.rights).grep(Prism::ConstantPathTargetNode)
    end

    def declared(statement, owner)
      return unless statement.is_a?(Prism::CallNode) && statement.receiver.nil?

      statement.arguments&.arguments&.each do |argument|
        next unless argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)

        name = argument.unescaped
        @declared[owner].merge([name, "#{name}=", "#{name}?"])
      end
    end

    # A constant assigned inside a class-level `if` or `begin` is still a
    # constant.
    def nested_constants(node, owner)
      node.compact_child_nodes.each do |child|
        case child
        when Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::BlockNode, Prism::LambdaNode then next
        when Prism::ConstantWriteNode then define_constant(child, owner, [owner, child.name].compact.join("::"))
        else nested_constants(child, owner)
        end
      end
    end

    def defines_through_call?(node)
      node.is_a?(Prism::CallNode) && node.receiver.nil? && node.block.nil? && node.arguments&.arguments&.grep(Prism::DefNode)&.any?
    end

    # +names+ is one name, or several for `LO, HI = 1, 9`, which share a
    # unit since a change to the line can't say which one it touched.
    def define_constant(statement, owner, names)
      Array(names).each do |name|
        @constants[name] = lines_of(statement)
        @computed << name if statement.respond_to?(:value) && !literal?(statement.value)
      end
      unit = statement_unit(:constant, owner, names, statement)
      mark(lines_of(statement), unit)
      walk_blocks(statement, owner, parent: unit, constant: Array(names).first)
    end

    def define_method(node, owner, statement, singleton: false)
      singleton ||= node.receiver.is_a?(Prism::SelfNode)
      name = "#{owner}#{singleton ? "." : "#"}#{node.name}"
      header_end = (node.rparen_loc || node.parameters&.location || node.name_loc).end_line
      header = node.location.start_line..header_end
      body = (header_end + 1)..node.location.end_line

      @methods[name] = Method.new(name: name, owner: owner, header: header, body: body)
      line = statement.location.start_line
      mark(header, Unit.new(kind: :method_header, owner: owner, name: name, line: line))
      mark(body, Unit.new(kind: :method_body, owner: owner, name: name, line: line))
    end

    def statement_unit(kind, owner, name, statement)
      head = Source.block_bodies(statement).empty? ? nil : Source.head_of(statement)
      Unit.new(kind: kind, owner: owner, name: name, line: statement.location.start_line, head: head)
    end

    # Block bodies inside a class-level statement. Methods and classes
    # defined in one, like Struct.new(...) do def x; end end, keep their
    # own kind.
    def walk_blocks(node, owner, parent:, constant: nil)
      node.compact_child_nodes.each do |child|
        unless (child.is_a?(Prism::BlockNode) || child.is_a?(Prism::LambdaNode)) && child.body
          walk_blocks(child, owner, parent: parent, constant: constant)
          next
        end

        block = child.location.start_line
        @block_starts[block] << block unless @block_starts[block].include?(block)
        mark(lines_of(child.body), Unit.new(kind: :block_body, owner: owner, line: parent.line, block: block, parent: parent))
        statements = child.body.is_a?(Prism::StatementsNode) ? child.body.body : [child.body]
        statements.each do |inner|
          case inner
          when Prism::DefNode then define_method(inner, constant || owner, inner)
          when Prism::ClassNode, Prism::ModuleNode then walk_namespace(inner, owner)
          else walk_blocks(inner, owner, parent: parent, constant: constant)
          end
        end
      end
    end

    def collect_references(node, nesting)
      case node
      when Prism::ClassNode, Prism::ModuleNode
        collect_references(node.superclass, nesting) if node.is_a?(Prism::ClassNode) && node.superclass
        name = namespace_name(nesting.last, node)
        inner = nesting + names_for(name).reverse
        collect_references(node.body, inner) if node.body
        return
      when Prism::ConstantReadNode
        record_reference(node, nesting, [node.name.to_s], absolute: false)
        return
      when Prism::ConstantPathNode
        parts = begin
          node.full_name_parts.map(&:to_s)
        rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
          nil
        end
        if parts
          absolute = parts.first.empty?
          record_reference(node, nesting, absolute ? parts.drop(1) : parts, absolute: absolute)
          return
        end
        record_reference(node, nesting, [node.name.to_s], absolute: false, dynamic: true)
      when Prism::CallNode
        name = CONSTANT_LOOKUPS.include?(node.name) && node.arguments&.arguments&.first
        if name.is_a?(Prism::SymbolNode) || name.is_a?(Prism::StringNode)
          record_reference(node, nesting, [name.unescaped.split("::").last], absolute: false, dynamic: true)
        end
      end
      node.compact_child_nodes.each { |child| collect_references(child, nesting) }
    end

    def record_reference(node, nesting, segments, absolute:, dynamic: false)
      @references[node.location.start_line] << Reference.new(nesting: nesting, segments: segments, absolute: absolute, dynamic: dynamic)
    end
  end
end
