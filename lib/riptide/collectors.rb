# frozen_string_literal: true

require "set"

module Riptide
  # What a test touched besides the code it ran, gathered in windows that
  # nest the way the tracer's do: a test's, a test class's, and the
  # process's, which is always open. The process's keeps file reads,
  # listings and tables, from the moment riptide starts, so boot counts too:
  # an initializer loading a YAML file, or `Dir["test/support/**/*.rb"].each
  # { require it }` picking up a new file.
  #
  # A test's body splits into a window per statement, the way the tracer's
  # does, and each statement also keeps its data flow: what it wrote, what it
  # read, and what its assertions compared.
  module Collectors
    IDENTIFIER = /(?:"?\w+"?\.)?"?(\w+)"?/
    TABLE = /\b(?:JOIN|UPDATE|INTO|TRUNCATE(?:\s+TABLE)?)\s+(?:ONLY\s+)?#{IDENTIFIER}/i
    FROM_LIST = /\bFROM\s+((?:#{IDENTIFIER}(?:\s+(?:AS\s+)?"?\w+"?)?\s*,\s*)*#{IDENTIFIER})/i

    # What a window gathers into, besides whether it translated anything.
    GATHERED = %i[classes tables reads listings absent].freeze

    Window = Struct.new(:classes, :tables, :reads, :listings, :absent, :translated, keyword_init: true) do
      def self.blank = new(classes: Set.new.compare_by_identity, tables: Set.new, reads: Set.new, listings: Set.new, absent: Set.new, translated: false)

      def gathered? = translated || GATHERED.any? { |field| !self[field].empty? }

      # Takes in what +other+ gathered, and says whether that added anything.
      def absorb(other)
        grew = other.translated && !translated
        self.translated ||= other.translated
        GATHERED.each do |field|
          mine = self[field]
          size = mine.size
          mine.merge(other[field])
          grew ||= mine.size != size
        end
        grew
      end
    end

    # A statement's data flow. +wrote+ are tables it inserted into, updated
    # or deleted from. +changed+ are tables an update, a delete or an insert
    # outside a record touched, any of which can change what a later query
    # finds. +counted+ are tables it read without loading their rows, like a
    # count, an exists? or a join. +made+ and +loaded+ are [table, id]
    # records, and +compared+ a digest per assertion or mock expectation.
    Flow = Struct.new(:wrote, :changed, :counted, :made, :loaded, :compared, keyword_init: true) do
      def self.blank = new(wrote: Set.new, changed: Set.new, counted: Set.new, made: Set.new, loaded: Set.new, compared: [])
    end

    WRITE = /\A\s*(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(?:ONLY\s+)?#{IDENTIFIER}/i
    # A record load reads one table's own columns.
    RECORDS = /\A\s*SELECT\s+(?:DISTINCT\s+)?#{IDENTIFIER}\.\*\s+FROM\s+(?:ONLY\s+)?#{IDENTIFIER}/i
    TRANSACTION = /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i

    # What a drain gives back when nothing was gathered, which is most of
    # the time.
    NOTHING = Window.blank.tap { |window| GATHERED.each { |field| window[field].freeze } }.freeze

    @process = Window.blank
    @enclosing = []

    class << self
      # The innermost window inside the process's, or nil, which it also is
      # while riptide's own work runs. Inside a split body, the running
      # statement's.
      def current
        return if @aside
        return @current unless @body && (start = Tracer.statement)

        (@body[start] ||= [Window.blank, Flow.blank]).first
      end

      # The running statement's data flow, or nil.
      def flow
        return if @aside || !@body

        start = Tracer.statement
        start && (@body[start] ||= [Window.blank, Flow.blank]).last
      end

      # Splits the test's window by statement until close_body.
      def open_body
        @body = {}
        @asserting = 0
      end

      # { statement's first line => [Window, Flow] } since open_body, or nil.
      def close_body
        body = @body
        @body = nil
        body
      end

      # Riptide's own file reads, listings and lookups aren't the app's, so
      # nothing gathers them.
      def aside
        was = @aside
        @aside = true
        yield
      ensure
        @aside = was
      end

      def install(root)
        @root_prefix = "#{File.expand_path(root)}/"
        @process = Window.blank
        @enclosing = []
        IO.singleton_class.prepend(Reads) unless IO.singleton_class < Reads
        File.singleton_class.prepend(Opens) unless File.singleton_class < Opens
        File.singleton_class.prepend(Checks) unless File.singleton_class < Checks
        FileTest.singleton_class.prepend(Checks) unless FileTest.singleton_class < Checks
        Kernel.prepend(KernelOpens) unless Kernel < KernelOpens
        Module.prepend(Lookups) unless Module < Lookups
        Dir.singleton_class.prepend(Listings) unless Dir.singleton_class < Listings
      end

      # ActiveRecord and I18n are only there once the app has loaded.
      def install_frameworks
        if defined?(::ActiveRecord::Base) && !(::ActiveRecord::Base < Instantiations)
          ::ActiveRecord::Base.prepend(Instantiations)
          ::ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
            tables = tables_in(payload[:sql])
            (current || process)&.tables&.merge(tables)
            flowed(payload[:sql], tables) if @body && payload[:name] != "SCHEMA"
          end
        end
        ::I18n.singleton_class.prepend(Translations) if defined?(::I18n) && !(::I18n.singleton_class < Translations)
      end

      def open
        @enclosing << @current if @current
        @current = Window.blank
      end

      def close
        closed = @current
        @current = @enclosing.pop
        closed
      end

      # What the innermost window gathered since it opened or was last
      # drained, leaving it open.
      def drain
        return NOTHING unless (@current || @process).gathered?

        if @current
          drained = @current
          @current = Window.blank
        else
          drained = @process
          @process = Window.blank
        end
        drained
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

      # Where +sql+, which names +tables+, took the running statement's data.
      def flowed(sql, tables = tables_in(sql))
        return if sql.match?(TRANSACTION) || !(at = flow)

        if (write = sql.match(WRITE))
          table = write[2].downcase
          at.wrote << table
          at.changed << table unless @creating && write[1].upcase.start_with?("INSERT")
          tables -= [table]
        elsif (own = sql.match(RECORDS)) && own[1].casecmp?(own[2])
          tables -= [own[2].downcase]
        end
        at.counted.merge(tables)
      end

      # A record's own insert is a row the statement made, not a change to
      # what other queries find.
      def creating
        was = @creating
        @creating = true
        yield
      ensure
        @creating = was
      end

      def made(record) = flow&.made&.<<([record.class.table_name, record.id])
      def loaded(record) = flow&.loaded&.<<([record.class.table_name, record.id])

      # Whether an assertion starting now counts for the running statement:
      # one inside another doesn't count again.
      def comparing? = !flow.nil? && @asserting.zero?

      # Notes what an assertion was handed, as a digest, or nil when it
      # doesn't count. What runs inside it, like assert_difference's block, is
      # still the statement's.
      def compared(digest)
        flow.compared << digest if digest && comparing?
        @asserting += 1 if @body
        yield
      ensure
        @asserting -= 1 if @body
      end

      def read(path)
        target = (current || process)&.reads
        return unless target && @root_prefix

        full = File.expand_path(path)
        target << full.delete_prefix(@root_prefix) if full.start_with?(@root_prefix)
      end

      # A glob or listing under the root, so a file showing up there counts.
      # Outside a test or class only the app's own count: gems like Zeitwerk
      # list every autoload directory at boot, and a new file there changes
      # nothing until something references it.
      def listed(patterns, base, depth: 2)
        target = current&.listings || (process.listings if process && caller_locations(depth, 1).first&.path&.start_with?(@root_prefix.to_s))
        return unless target && @root_prefix

        Array(patterns).flatten.each do |pattern|
          next unless pattern.is_a?(String) || pattern.respond_to?(:to_path)

          full = File.expand_path(pattern.to_s, base)
          target << full.delete_prefix(@root_prefix) if full.start_with?(@root_prefix)
        end
      end

      # A class found by name, like `"#{kind}Policy".constantize` or a
      # gem's `const_get`, is one the test used. A name that wasn't there
      # matters too: a file defining it later changes what the test does.
      def found(value)
        current.classes << value if current && value.is_a?(Module)
      end

      # Kept as the exact call, since `Card.const_defined?(:Config)` and
      # `Object.const_defined?("Card::Config")` answer differently when a
      # top-level Config exists.
      def missing(scope, name, inherit)
        return unless current && scope.name && (name.is_a?(String) || name.is_a?(Symbol))

        current.absent << [scope.name, name.to_s, inherit ? true : false]
      end

      def process = (@process unless @aside)

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
        super.tap { Collectors.loaded(self) }
      end

      def _create_record(...)
        Collectors.creating { super.tap { Collectors.made(self) } }
      end
    end

    # On IO, so File, Pathname and YAML reach them too.
    module Reads
      # copy_stream reads its first argument, so a path there counts.
      %i[read binread readlines foreach copy_stream].each do |reader|
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
          Opens.opened(path, rest, options)
          super(path, *rest, **options, &block)
        end
      end

      def self.opened(path, rest, options)
        mode = options.fetch(:mode) { rest.first.is_a?(Integer) || rest.first.is_a?(String) ? rest.first : "r" }
        Collectors.read(path) if (path.is_a?(String) || path.respond_to?(:to_path)) && reading?(mode)
      end

      def self.reading?(mode)
        case mode
        when Integer then (mode & (File::WRONLY | File::RDWR)) != File::WRONLY
        else !mode.to_s.start_with?("w", "a")
        end
      end
    end

    # Kernel#open opens a file without going through File.open.
    module KernelOpens
      private

      def open(path, *rest, **options, &block)
        Opens.opened(path, rest, options)
        super
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

      %i[children each_child entries foreach empty?].each do |lister|
        define_method(lister) do |dir, *rest, **options, &block|
          Collectors.listed(File.join(dir.to_s, "*"), nil) if dir.is_a?(String) || dir.respond_to?(:to_path)
          super(dir, *rest, **options, &block)
        end
      end

      def exist?(path)
        Collectors.checked(path)
        super
      end
    end

    # On File and FileTest, which Pathname's checks go through. Whether a
    # file is there is a listing of it. How big it is depends on what's in
    # it, so that's a read.
    module Checks
      %i[exist? file? directory? symlink? readable? executable?].each do |check|
        define_method(check) do |path|
          Collectors.checked(path)
          super(path)
        end
      end

      %i[size size? zero? empty?].each do |check|
        define_method(check) do |path|
          Collectors.read(path) if path.is_a?(String) || path.respond_to?(:to_path)
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
