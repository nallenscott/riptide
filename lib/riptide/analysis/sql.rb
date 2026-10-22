# frozen_string_literal: true

module Riptide
  module Analysis
    # A pg_dump structure file: each changed line maps to the statement it's
    # in, and the statement to its table. Migration versions are ignored,
    # and anything that isn't about one table changes the file as a whole.
    class Sql
      TABLE = /(?:CREATE (?:UNLOGGED )?TABLE|ALTER TABLE(?: ONLY)?|CREATE (?:UNIQUE )?INDEX .*? ON(?: ONLY)?|CREATE TRIGGER .*? ON|COMMENT ON (?:TABLE|COLUMN)|CREATE (?:MATERIALIZED )?VIEW)\s+(?:IF NOT EXISTS\s+)?((?:"?\w+"?\.)?"?\w+"?)/m
      OWNED_BY = /OWNED BY ((?:"?\w+"?\.)?"?\w+"?)\.\w+/
      MIGRATIONS = /\AINSERT INTO "?schema_migrations"?/

      def initialize(old_text, new_text)
        @old_text = old_text
        @new_text = new_text
      end

      def change
        change = Change.new
        old_statements = statements(@old_text)
        new_statements = statements(@new_text)
        Diff.hunks(@old_text, @new_text).each do |hunk|
          hunk.old_lines.each { |line| classify(change, old_statements[line]) }
          hunk.new_lines.each { |line| classify(change, new_statements[line]) }
        end
        change
      end

      private

      def classify(change, statement)
        return if statement.nil? || statement.match?(MIGRATIONS)

        table = statement[OWNED_BY, 1] || statement[TABLE, 1]
        table ? change.tables << table.delete('"').split(".").last : change.whole!
      end

      # { line => statement text }. Statements end with a semicolon at the
      # end of a line; comments and blank lines belong to none.
      def statements(text)
        result = {}
        current = []
        lines = text.lines
        lines.each.with_index(1) do |line, number|
          stripped = line.strip
          next if current.empty? && (stripped.empty? || stripped.start_with?("--"))

          current << number
          next unless stripped.end_with?(";")

          statement = current.map { |n| lines[n - 1] }.join
          current.each { |n| result[n] = statement }
          current = []
        end
        result
      end
    end
  end
end
