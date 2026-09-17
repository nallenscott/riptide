# frozen_string_literal: true

module Riptide
  class Configuration
    # Path to the SQLite dependency map, relative to the host app's root.
    attr_accessor :db_path

    def initialize
      @db_path = "tmp/riptide/riptide.db"
    end
  end
end
