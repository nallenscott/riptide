# frozen_string_literal: true

module Riptide
  # Where an app keeps the files riptide treats specially, and which
  # analysis each path gets.
  class Layout
    RUBY_EXTENSIONS = %w[.rb .rake .ru].freeze
    FIXTURE_MODEL = /^_fixture:\s*\n\s+model_class:\s*["']?([\w:]+)/

    attr_reader :root, :schema_path, :fixtures_path

    def initialize(root:, schema_path: nil, fixtures_path: "test/fixtures")
      @root = root
      @schema_path = schema_path || %w[db/structure.sql db/schema.rb].find { |path| File.exist?(File.join(root, path)) }
      @fixtures_path = fixtures_path
    end

    def kind(path)
      if path == schema_path then path.end_with?(".sql") ? :sql : :schema
      elsif fixture?(path) then :fixture
      elsif RUBY_EXTENSIONS.include?(File.extname(path)) then :ruby
      else :whole
      end
    end

    def fixture?(path)
      path.start_with?("#{fixtures_path}/") && path.end_with?(".yml")
    end

    # The table a fixture file fills: its model's table when it names one,
    # otherwise its path, the way Rails maps admin/users.yml to admin_users.
    def fixture_table(path, text)
      model = text[FIXTURE_MODEL, 1]
      table = model && Object.const_get(model).table_name rescue nil
      table || path.delete_prefix("#{fixtures_path}/").delete_suffix(".yml").tr("/", "_")
    end

    # { table => [fixture path, ...] } for every fixture file on disk.
    def fixtures_by_table
      @fixtures_by_table ||= Dir.glob("#{fixtures_path}/**/*.yml", base: root).group_by do |path|
        fixture_table(path, File.read(File.join(root, path)))
      end
    end
  end
end
