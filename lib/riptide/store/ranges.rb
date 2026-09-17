# frozen_string_literal: true

module Riptide
  class Store
    # Compresses a set of line numbers into an ordered list of inclusive
    # [start, finish] pairs, merging consecutive lines into one range,
    # rather than storing one row per line.
    module Ranges
      module_function

      def compress(lines)
        sorted = lines.to_a.sort
        return [] if sorted.empty?

        ranges = []
        start = finish = sorted.first

        sorted.drop(1).each do |line|
          if line == finish + 1
            finish = line
          else
            ranges << [start, finish]
            start = finish = line
          end
        end
        ranges << [start, finish]
        ranges
      end
    end
  end
end
