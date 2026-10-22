# frozen_string_literal: true

require "digest"
require "json"
require "set"

module Riptide
  # Turns what one test touched into the files it depended on. Facets name
  # the parts of a file version it relied on: methods, blocks, constants,
  # tables, or the whole file. What a class's own loading ran is the same
  # for every test that uses the class, so it comes back as one shared set
  # per class.
  class Inputs
    attr_reader :root

    # A file changed on disk after Ruby loaded it, so there's no knowing
    # which version a test ran.
    class Stale < Error; end

    def initialize(layout:, files:, source_patterns: [], locale_patterns: ["config/locales/**/*"])
      @layout = layout
      @root = layout.root
      @files = files
      @source_patterns = source_patterns
      @locale_patterns = locale_patterns
      @resolver = Resolver.new(root: @root)
      @sources = {}
      @shas = {}
      @ancestors = {}.compare_by_identity
      @load_constants = Hash.new { |h, k| h[k] = Set.new }
      @owner_sets = {}
      @listings = {}
    end

    # Remembers which constants each class's loading read. A test that uses
    # the class depends on them too: changing STATES matters to every test
    # that saves a model whose `validates :state, inclusion: STATES` read it.
    def absorb(load_facts)
      load_facts.each do |path, lines|
        source = source_for(path)
        next unless source

        lines.each do |line, fact|
          constants = source.references_at(line).filter_map { |reference| @resolver.resolve(reference) }
          fact["owners"].each { |owner| @load_constants[owner].merge(constants) }
        end
      end
    end

    # [{ path => facets }, { class name => { path => facets } }] for one
    # test. +traced+ is a closed Tracer window, +window+ the collectors'.
    def for_test(traced, window)
      entries = Hash.new { |h, path| h[path] = {} }
      owners = Set.new

      traced.lines.each do |path, numbers|
        next unless recordable?(path)

        source = @layout.kind(path) == :ruby && source_for(path)
        source ? ran(entries[path], entries, owners, numbers, source) : entries[path]["whole"] = true
      end
      (window.classes.to_a + traced.receivers).each do |klass|
        name = Tracer.name_of(klass)
        owners << name if name
      end
      tables(entries, window.tables)
      window.reads.each { |path| entries[path]["whole"] = true if recordable?(path) }
      locales.each { |path| entries[path]["whole"] = true } if window.translated

      sets = expand(owners).each_with_object({}) do |owner, result|
        files = owner_set(owner)
        result[owner] = files unless files.empty?
      end
      inputs = finish(entries)
      window.listings.each { |pattern| inputs["#{Env::GLOB}#{pattern}"] = { "sha" => listing(pattern) } }
      # A name that turned up by the end of the test, like one an autoloader
      # registered once its namespace loaded, was never up to a new file.
      window.absent.each do |scope, name, inherit|
        key = "#{inherit ? Env::CONSTANT : Env::OWN_CONSTANT}#{scope} #{name}"
        inputs[key] = { "sha" => Env::ABSENT } if Env.presence(key) == Env::ABSENT
      end
      [inputs, sets]
    end

    # The files a glob matches now, as one value to compare. Files outside
    # the source patterns count: a support file boot requires matters
    # whether or not riptide records dependencies on it.
    def listing(pattern)
      @listings[pattern] ||= Digest::SHA1.hexdigest(JSON.generate(Dir.glob(pattern, base: @root).select { |path| known?(path) }.sort))
    end

    # { path => facets } for what boot ran: the methods, blocks and
    # constants every test in the process shares. +boot_lines+ is
    # { path => { line => true } }.
    def for_boot(boot_lines)
      entries = Hash.new { |h, path| h[path] = {} }
      boot_lines.each do |path, lines|
        next unless recordable?(path)

        source = @layout.kind(path) == :ruby && source_for(path)
        source ? ran(entries[path], entries, Set.new, lines.keys, source) : entries[path]["whole"] = true
      end
      finish(entries)
    end

    def sha(path)
      @shas[path] ||= begin
        verify_unchanged(path)
        Diff.blob_sha(File.join(@root, path))
      end
    end

    # In scope and known to git, tracked or at least not ignored. An ignored
    # file, like a key or a log, is never recorded, so it can never be
    # pinned into the store and pushed.
    def recordable?(path)
      known?(path) && in_scope?(path)
    end

    def known?(path) = @files.include?(path)

    def source_for(path)
      return @sources[path] if @sources.key?(path)

      full = File.join(@root, path)
      @sources[path] = File.file?(full) ? Source.parse(File.read(full)) : nil
    end

    private

    def in_scope?(path)
      @source_patterns.empty? || @source_patterns.any? { |pattern| File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
    end

    def verify_unchanged(path)
      compiled = Tracer.compiled_stat(path)
      return unless compiled

      stat = File.stat(File.join(@root, path))
      raise Stale, "#{path} changed after it loaded" unless [stat.mtime.to_r, stat.size] == compiled
    end

    def ran(entry, entries, owners, numbers, source)
      numbers.each do |line|
        source.blocks_starting_at(line).each { |block| add(entry, "blocks", block) }
        unit = source.unit_at(line)
        next unless unit

        case unit.kind
        when :method_header, :method_body then add(entry, "methods", unit.name)
        when :block_body then add(entry, "blocks", unit.block)
        end
        owners.merge(source.names_for(unit.owner)) if unit.owner
        source.references_at(line).each do |reference|
          # A dynamic read can't be resolved, so it matches a change to any
          # constant with that name.
          next add(entry, "constants", "*::#{reference.segments.last}") if reference.dynamic

          constant = @resolver.resolve(reference)
          referenced(entries, owners, constant) if constant
        end
      end
      entry
    end

    # A constant whose value ran code at load depends on that code too,
    # which is what its class's shared set holds.
    def referenced(entries, owners, constant)
      add(entries[constant.path], "constants", constant.name) if constant.path && recordable?(constant.path)
      if constant.value.is_a?(Module)
        owners << constant.value.name if constant.value.name
      elsif constant.path && (namespace = constant.name.rpartition("::").first) != "" && source_for(constant.path)&.computed?(constant.name)
        owners << namespace
      end
    end

    # Every named class or module the test's owners are built from: their
    # ancestors, and the modules they extend.
    def expand(owners)
      owners.each_with_object(Set.new) do |name, all|
        all << name
        mod = @resolver.module_named(name)
        all.merge(ancestry(mod)) if mod
      end
    end

    def ancestry(mod)
      @ancestors[mod] ||= (mod.ancestors + mod.singleton_class.ancestors).filter_map { |ancestor| Tracer.name_of(ancestor) }.uniq
    end

    # The files whose code ran while +owner+ loaded, plus the constants its
    # loading read. Rebuilt only when more of the class loads.
    def owner_set(owner)
      mod = @resolver.module_named(owner)
      files = mod ? Tracer.files_for(mod) : []
      files = [@resolver.relative(Object.const_source_location(owner)&.first)].compact if files.empty? && mod
      constants = @load_constants[owner]
      key = [files.size, constants.size]
      cached = @owner_sets[owner]
      return cached.last if cached&.first == key

      entries = Hash.new { |h, path| h[path] = {} }
      files.each { |path| add(entries[path], "owners", owner) if recordable?(path) }
      constants.each { |constant| add(entries[constant.path], "constants", constant.name) if constant.path && recordable?(constant.path) }
      @owner_sets[owner] = [key, finish(entries)]
      @owner_sets[owner].last
    rescue NameError
      {}
    end

    def tables(entries, tables)
      return if tables.empty?

      entries[@layout.schema_path]["tables"] = tables.to_a.sort if @layout.schema_path && recordable?(@layout.schema_path)
      tables.each do |table|
        @layout.fixtures_by_table.fetch(table, []).each { |path| add(entries[path], "tables", table) if recordable?(path) }
      end
    end

    def locales
      @locales ||= @locale_patterns.flat_map { |pattern| Dir.glob(pattern, base: @root) }.select { |path| recordable?(path) && File.file?(File.join(@root, path)) }
    end

    def add(entry, facet, value)
      (entry[facet] ||= []) << value unless entry[facet]&.include?(value)
    end

    def finish(entries)
      entries.each_with_object({}) do |(path, facets), result|
        next unless File.file?(File.join(@root, path))

        result[path] = { "sha" => sha(path) }.merge(facets)
      end
    end
  end
end
