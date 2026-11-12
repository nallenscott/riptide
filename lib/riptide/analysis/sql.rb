# frozen_string_literal: true

module Riptide
  module Analysis
    # A pg_dump structure file: each changed line maps to the statement it's
    # in, and the statement to its tables. Migration versions are ignored,
    # and anything that isn't about a table changes the file as a whole.
    class Sql
      TABLE = /(?:CREATE (?:UNLOGGED )?TABLE|ALTER TABLE(?: ONLY)?|CREATE (?:UNIQUE )?INDEX .*? ON(?: ONLY)?|CREATE TRIGGER .*? ON|COMMENT ON (?:TABLE|COLUMN)|CREATE (?:MATERIALIZED )?VIEW)\s+(?:IF NOT EXISTS\s+)?((?:"?\w+"?\.)?"?\w+"?)/m
      OWNED_BY = /OWNED BY ((?:"?\w+"?\.)?"?\w+"?)\.\w+/
      # A foreign key changes what inserts and deletes on the table it points
      # at can do, so that table changes too.
      REFERENCES = /REFERENCES\s+((?:"?\w+"?\.)?"?\w+"?)/
      MIGRATIONS = /\AINSERT INTO "?schema_migrations"?/
      SEQUENCE = /(?:CREATE|ALTER) SEQUENCE\s+(?:IF NOT EXISTS\s+)?((?:"?\w+"?\.)?"?\w+"?)/
      NEXTVAL = /nextval\('((?:"?\w+"?\.)?"?\w+"?)'/

      def initialize(old_text, new_text)
        @old_text = old_text
        @new_text = new_text
      end

      def change
        change = Change.new
        old_statements = statements(@old_text)
        new_statements = statements(@new_text)
        @sequences = sequence_tables(old_statements.values + new_statements.values)
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
        return [table, *statement.scan(REFERENCES).flatten].each { |name| change.tables << bare(name) } if table

        # A sequence belongs to the tables that own it or take their ids
        # from it, like the one pg_dump writes for each new table.
        tables = statement[SEQUENCE, 1] && @sequences[bare(statement[SEQUENCE, 1])]
        tables ? change.tables.merge(tables) : change.whole!
      end

      # { sequence => Set of tables }, from OWNED BY and nextval defaults.
      def sequence_tables(statements)
        statements.uniq.each_with_object({}) do |statement, sequences|
          if (owner = statement[OWNED_BY, 1]) && (sequence = statement[SEQUENCE, 1])
            (sequences[bare(sequence)] ||= Set.new) << bare(owner)
          elsif (table = statement[TABLE, 1])
            statement.scan(NEXTVAL).flatten.each { |sequence| (sequences[bare(sequence)] ||= Set.new) << bare(table) }
          end
        end
      end

      def bare(name) = name.delete('"').split(".").last

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
