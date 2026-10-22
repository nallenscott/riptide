# frozen_string_literal: true

module Riptide
  module Analysis
    # A fixture file: any change changes its table.
    class Fixture
      def initialize(old_text, new_text, table:)
        @changed = old_text.b != new_text.b
        @table = table
      end

      def change
        change = Change.new
        change.tables << @table if @changed
        change
      end
    end
  end
end
