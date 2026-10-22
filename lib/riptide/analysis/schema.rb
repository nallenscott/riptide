# frozen_string_literal: true

require "prism"

module Riptide
  module Analysis
    # db/schema.rb: each changed line maps to the table its schema call
    # names. The schema version and anything not about one table change the
    # file as a whole.
    class Schema
      TABLE_CALLS = %i[create_table add_index add_foreign_key change_table create_join_table].freeze

      def initialize(old_text, new_text)
        @old_text = old_text
        @new_text = new_text
      end

      def change
        change = Change.new
        old_tables = tables_by_line(@old_text)
        new_tables = tables_by_line(@new_text)
        Diff.hunks(@old_text, @new_text).each do |hunk|
          hunk.old_lines.each { |line| classify(change, old_tables, line) }
          hunk.new_lines.each { |line| classify(change, new_tables, line) }
        end
        change
      end

      private

      def classify(change, tables, line)
        return unless tables.key?(line)

        names = tables[line]
        names.empty? ? change.whole! : change.tables.merge(names)
      end

      # { line => [table, ...] }, empty for lines in other statements.
      def tables_by_line(text)
        result = {}
        result.default = nil
        program = Prism.parse(text).value
        definition = program.statements.body.find { |node| node.is_a?(Prism::CallNode) && node.block }
        statements = definition&.block&.body&.body || []
        statements.each do |call|
          names = table_names(call)
          (call.location.start_line..call.location.end_line).each { |line| result[line] = names }
        end
        result
      end

      def table_names(call)
        return [] unless call.is_a?(Prism::CallNode) && TABLE_CALLS.include?(call.name)

        tables = call.arguments&.arguments&.grep(Prism::StringNode)&.map(&:unescaped) || []
        call.name == :add_foreign_key || call.name == :create_join_table ? tables.first(2) : tables.first(1)
      end
    end
  end
end
