# frozen_string_literal: true

require "set"

module Riptide
  # What a test touched besides the code it ran, gathered while its window
  # is open. File reads and directory listings are watched from the moment
  # riptide starts, so boot counts too: an initializer loading a YAML file,
  # or `Dir["test/support/**/*.rb"].each { require it }` picking up a new
  # file.
  module Collectors
    IDENTIFIER = /(?:"?\w+"?\.)?"?(\w+)"?/
    TABLE = /\b(?:JOIN|UPDATE|INTO|TRUNCATE(?:\s+TABLE)?)\s+(?:ONLY\s+)?#{IDENTIFIER}/i
    FROM_LIST = /\bFROM\s+((?:#{IDENTIFIER}(?:\s+(?:AS\s+)?"?\w+"?)?\s*,\s*)*#{IDENTIFIER})/i

    Window = Struct.new(:classes, :tables, :reads, :listings, :absent, :translated, keyword_init: true)

    class << self
      attr_reader :current, :boot_reads, :boot_globs

      def install(root)
        @root_prefix = "#{File.expand_path(root)}/"
        @boot_reads = Set.new
        @boot_globs = Set.new
        IO.singleton_class.prepend(Reads) unless IO.singleton_class < Reads
        File.singleton_class.prepend(Opens) unless File.singleton_class < Opens
        File.singleton_class.prepend(Checks) unless File.singleton_class < Checks
        Module.prepend(Lookups) unless Module < Lookups
        Dir.singleton_class.prepend(Listings) unless Dir.singleton_class < Listings
      end

      # ActiveRecord and I18n are only there once the app has loaded.
      def install_frameworks
        if defined?(::ActiveRecord::Base) && !(::ActiveRecord::Base < Instantiations)
          ::ActiveRecord::Base.prepend(Instantiations)
          ::ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| @current&.tables&.merge(tables_in(payload[:sql])) }
        end
        ::I18n.singleton_class.prepend(Translations) if defined?(::I18n) && !(::I18n.singleton_class < Translations)
        @boot_reads = nil
        @boot_globs = nil
      end

      def open
        @current = Window.new(classes: Set.new.compare_by_identity, tables: Set.new, reads: Set.new, listings: Set.new, absent: Set.new, translated: false)
      end

      def close
        window = @current
        @current = nil
        window
      end

      # Every table a statement names, schema-qualified or not, including
      # each table in a comma-separated FROM list.
      def tables_in(sql)
        tables = sql.scan(TABLE).flatten
        sql.scan(FROM_LIST).each do |list,|
          list.split(",").each { |item| tables << item.strip[/\A#{IDENTIFIER}/, 1] }
        end
        tables.compact.map(&:downcase).uniq
      end

      def read(path)
        target = @current&.reads || @boot_reads
        return unless target && @root_prefix

        full = File.expand_path(path.to_s)
        target << full.delete_prefix(@root_prefix) if full.start_with?(@root_prefix)
      end

      # A glob or listing under the root, so a file showing up there counts.
      # At boot only the app's own count: gems like Zeitwerk list every
      # autoload directory, and a new file there changes nothing until
      # something references it.
      def listed(patterns, base, depth: 2)
        target = @current&.listings || (@boot_globs if @boot_globs && caller_locations(depth, 1).first&.path&.start_with?(@root_prefix.to_s))
        return unless target && @root_prefix

        Array(patterns).flatten.each do |pattern|
          next unless pattern.is_a?(String) || pattern.respond_to?(:to_path)

          full = File.expand_path(pattern.to_s, base || Dir.pwd)
          target << full.delete_prefix(@root_prefix) if full.start_with?(@root_prefix)
        end
      end

      # A class found by name, like `"#{kind}Policy".constantize` or a
      # gem's `const_get`, is one the test used. A name that wasn't there
      # matters too: a file defining it later changes what the test does.
      def found(value)
        @current.classes << value if @current && value.is_a?(Module)
      end

      # Kept as the exact call, since `Card.const_defined?(:Config)` and
      # `Object.const_defined?("Card::Config")` answer differently when a
      # top-level Config exists.
      def missing(scope, name, inherit)
        return unless @current && scope.name && (name.is_a?(String) || name.is_a?(Symbol))

        @current.absent << [scope.name, name.to_s, inherit ? true : false]
      end

      # Whether a file exists is a listing of just that path.
      def checked(path)
        listed(path.to_s.gsub(/[*?\[\]{}\\]/) { "\\#{_1}" }, nil, depth: 3) if path.is_a?(String) || path.respond_to?(:to_path)
      end
    end

    module Instantiations
      def initialize(...)
        Collectors.current&.classes&.add(self.class)
        super
      end

      def init_with_attributes(...)
        Collectors.current&.classes&.add(self.class)
        super
      end
    end

    # On IO, so File, Pathname and YAML reach them too.
    module Reads
      %i[read binread readlines foreach].each do |reader|
        define_method(reader) do |path, *rest, **options, &block|
          Collectors.read(path) if path.is_a?(String) || path.respond_to?(:to_path)
          super(path, *rest, **options, &block)
        end
      end
    end

    # Writes aren't dependencies: a test that writes a tmp file doesn't
    # depend on what was there before.
    module Opens
      %i[open new].each do |opener|
        define_method(opener) do |path, *rest, **options, &block|
          mode = options.fetch(:mode) { rest.first.is_a?(Integer) || rest.first.is_a?(String) ? rest.first : "r" }
          Collectors.read(path) if (path.is_a?(String) || path.respond_to?(:to_path)) && Opens.reading?(mode)
          super(path, *rest, **options, &block)
        end
      end

      def self.reading?(mode)
        case mode
        when Integer then (mode & (File::WRONLY | File::RDWR)) != File::WRONLY
        else !mode.to_s.start_with?("w", "a")
        end
      end
    end

    # A directory read entry by entry counts as listing everything in it.
    module Listings
      def [](*patterns, base: nil, **options)
        Collectors.listed(patterns, base)
        super
      end

      def glob(patterns, *rest, base: nil, **options, &block)
        Collectors.listed(patterns, base)
        super
      end

      %i[children each_child entries foreach].each do |lister|
        define_method(lister) do |dir, *rest, **options, &block|
          Collectors.listed(File.join(dir.to_s, "*"), nil) if dir.is_a?(String) || dir.respond_to?(:to_path)
          super(dir, *rest, **options, &block)
        end
      end
    end

    module Checks
      %i[exist? file? directory?].each do |check|
        define_method(check) do |path|
          Collectors.checked(path)
          super(path)
        end
      end
    end

    module Lookups
      def const_get(name, inherit = true)
        super.tap { |value| Collectors.found(value) }
      rescue NameError
        Collectors.missing(self, name, inherit)
        raise
      end

      def const_defined?(name, inherit = true)
        super.tap { |defined| Collectors.missing(self, name, inherit) unless defined }
      end
    end

    module Translations
      %i[translate t translate! t! localize l exists?].each do |lookup|
        define_method(lookup) do |*args, **options, &block|
          Collectors.current&.translated = true
          super(*args, **options, &block)
        end
      end
    end
  end
end
