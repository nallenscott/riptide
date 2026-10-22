# frozen_string_literal: true

module Riptide
  module Analysis
    # Classifies each changed line of a Ruby file by the unit it's in. A
    # change anywhere in a method or block changes that method or block,
    # since Ruby doesn't fire a line event for every line it runs: `else`,
    # `rescue`, or the second line of a multi-line call never show up.
    class Ruby
      # +load_facts+ is { line => { "owners", "called" } } for the old
      # version, or nil if nothing loaded it while riptide was watching.
      # +overrides+ says whether a new method takes over calls that used to
      # go somewhere else. +ancestors+ names a class's ancestors, which a
      # constant added to it can shadow.
      def initialize(old_text, new_text, load_facts:, overrides:, ancestors: ->(_) { [] })
        @old_text = old_text
        @new_text = new_text
        @facts = load_facts
        @overrides = overrides
        @ancestors = ancestors
      end

      def change
        @change = Change.new
        @old = Source.parse(@old_text)
        @new = Source.parse(@new_text)
        hunks = (Diff.hunks(@old_text, @new_text) if @old && @new)
        # Bytes that differ with no hunks to show for it, like a NUL byte
        # that makes git call the file binary, count as everything changing.
        if hunks.nil? || (hunks.empty? && @old_text.b != @new_text.b)
          @change.whole!
          return @change
        end

        hunks.each do |hunk|
          hunk.old_lines.each { |line| classify_old(hunk, line) }
          hunk.new_lines.each { |line| classify_new(hunk, line) }
        end
        @change
      end

      private

      def classify_old(hunk, line)
        unit = @old.unit_at(line)
        return unless unit

        case unit.kind
        when :method_header, :method_body then method_changed(unit.name)
        when :block_body then old_block(hunk, line, unit)
        else statement(@old, unit)
        end
      end

      def classify_new(hunk, line)
        unit = @new.unit_at(line)
        return unless unit

        case unit.kind
        when :method_header, :method_body
          if @old.methods.key?(unit.name)
            method_changed(unit.name)
          elsif @old.declares?(unit.owner, unit.name[/[#.](.+)\z/, 1]) || @overrides.call(unit.name)
            @change.owners.merge(@new.names_for(unit.owner))
          end
        when :block_body then new_block(hunk, line, unit)
        when :constant
          Array(unit.name).each { |name| @old.constants.key?(name) ? constant(@new, name) : added_constant(name) }
        else statement(@new, unit)
        end
      end

      # A method that ran as called code while a class loaded, like a macro
      # called from a class body, changes that class too.
      def method_changed(name)
        @change.methods << name
        method = @old.methods[name]
        ran_at_load(method.header.begin..method.body.end) if method
      end

      # Without load facts there's no telling whether a block ran at load. A
      # one-line declaration shares its line with its block, so the rest of
      # the statement has to match for it to count as a block change.
      def old_block(hunk, line, unit)
        return statement(@old, unit.parent) unless @facts
        return statement(@old, unit.parent) if starts_statement?(unit, line) && !same_head_in_new?(hunk, line, unit)

        block_changed(unit.block)
      end

      def new_block(hunk, line, unit)
        if starts_statement?(unit, line)
          return if hunk.old_count.positive? && same_head_in_old?(hunk, line, unit)

          return statement(@new, unit.parent, added: true)
        end
        return if old_side_decided?(hunk)

        existing = around(hunk).filter_map { |old_line| @old.unit_at(old_line) }.find { |old| old.kind == :block_body }
        existing && @facts ? block_changed(existing.block) : statement(@new, unit.parent)
      end

      # Old lines with no unit, like comments, leave the new side to say
      # what changed.
      def old_side_decided?(hunk)
        hunk.old_lines.any? { |old_line| @old.unit_at(old_line) }
      end

      def block_changed(block)
        @change.blocks << block
        ran_at_load(block..(@old_text.count("\n") + 1), block: block)
      end

      # Adds the classes any of +lines+ ran for as called code at load. For a
      # block, only the lines inside that block count.
      def ran_at_load(lines, block: nil)
        return unless @facts

        lines.each do |line|
          fact = @facts[line]
          next unless fact && fact["called"]
          next if block && @old.unit_at(line)&.block != block && line != block

          @change.owners.merge(fact["owners"])
        end
      end

      def statement(source, unit, added: false)
        case unit.kind
        when :constant then Array(unit.name).each { |name| added ? added_constant(name) : constant(source, name) }
        when :declaration then @change.owners.merge(source.names_for(unit.owner))
        when :top then @change.suite!
        when :data then @change.whole!
        end
      end

      def constant(source, name)
        @change.constants.merge(source.names_for(name))
      end

      # A new Card::LIMIT can shadow a top-level LIMIT, or a LIMIT Card
      # inherited, so every name it could have resolved to counts as changed.
      def added_constant(name)
        @new.names_for(name).each do |full|
          parts = full.split("::")
          parts.each_index { |i| @change.constants << parts.drop(i).join("::") }
          @ancestors.call(parts[0...-1].join("::")).each { |ancestor| @change.constants << "#{ancestor}::#{parts.last}" } if parts.size > 1
        end
      end

      def starts_statement?(unit, line)
        unit.line == line
      end

      def same_head_in_new?(hunk, line, unit)
        same_head?(@new.unit_at(hunk.new_start + (line - hunk.old_start)), unit)
      end

      def same_head_in_old?(hunk, line, unit)
        same_head?(@old.unit_at(hunk.old_start + (line - hunk.new_start)), unit)
      end

      def same_head?(counterpart, unit)
        return false unless counterpart

        head = ->(u) { (u.parent || u).head }
        !head.(unit).nil? && head.(counterpart) == head.(unit)
      end

      # The old lines a hunk replaces and the ones on either side of it. For
      # an insertion git's old_start is the line it follows.
      def around(hunk)
        (hunk.old_start - 1..hunk.old_start + [hunk.old_count, 1].max).to_a
      end
    end
  end
end
