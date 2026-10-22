# frozen_string_literal: true

module Riptide
  # Works out what changed in a file since a recorded version of it, once
  # per version however many tests depended on it.
  class Analyzer
    # +blobs+ returns a recorded version's content, or nil when this
    # repository doesn't have it. +load_facts+ returns a version's load
    # facts, or nil.
    def initialize(layout:, blobs:, load_facts:)
      @layout = layout
      @blobs = blobs
      @load_facts = load_facts
      @changes = {}
      @sources = {}
    end

    # The Change from +old_sha+ to what's on disk, or nil when the recorded
    # version isn't available.
    def change(path, old_sha)
      key = [path, old_sha]
      return @changes[key] if @changes.key?(key)

      old_text = @blobs.call(old_sha)
      @changes[key] = old_text && analyze(path, old_sha, text(old_text), text(File.binread(File.join(@layout.root, path))))
    end

    private

    # App source is UTF-8. Anything that isn't stays bytes, and only whole
    # files get compared that way.
    def text(bytes)
      utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : bytes.b
    end

    def analyze(path, old_sha, old_text, new_text)
      case @layout.kind(path)
      when :ruby
        Analysis::Ruby.new(old_text, new_text, load_facts: @load_facts.call(old_sha), overrides: ->(name) { overrides?(name, path) }, ancestors: method(:ancestors)).change
      when :sql then Analysis::Sql.new(old_text, new_text).change
      when :schema then Analysis::Schema.new(old_text, new_text).change
      when :fixture then Analysis::Fixture.new(old_text, new_text, table: @layout.fixture_table(path, new_text)).change
      else Change.new.tap { |change| change.whole! unless old_text.b == new_text.b }
      end
    end

    # Whether a method newly defined in +path+, like "Card#to_s" or
    # "Card.build", takes over calls that used to go somewhere else: an
    # inherited method, an attribute reader, method_missing, or the same
    # method defined in another file that reopens the class. A module's
    # method lands in every class that includes or extends it, ahead of
    # what comes after it there. A method added to a class from outside the
    # app, like String, always might, and so does anything riptide can't
    # check. A new test is only ever called by name.
    def overrides?(name, path)
      owner_name, separator, method_name = name.rpartition(/[#.]/)
      owner = Object.const_get(owner_name)
      method_name = method_name.to_sym
      return false if owner.is_a?(Class) && defined?(Minitest::Test) && owner < Minitest::Test && method_name.start_with?("test_")
      return true unless app_class?(owner_name)
      return true if defined_elsewhere?(owner, name, path)

      if owner.is_a?(Class) || separator == "."
        target = separator == "." ? owner.singleton_class : owner
        takes_over?(target, owner, method_name, after: target)
      else
        includers = ObjectSpace.each_object(Module).flat_map do |mod|
          next [] if mod.equal?(owner) || mod.singleton_class?

          [(mod if mod.ancestors.include?(owner)), (mod.singleton_class if mod.is_a?(owner))].compact
        end
        includers.empty? || includers.any? { |target| takes_over?(target, Tracer.attached(target), method_name, after: owner) }
      end
    rescue StandardError
      true
    end

    # Whether +method_name+ on +target+ used to resolve past +after+ in its
    # ancestry, or to an attribute or method_missing.
    def takes_over?(target, owner, method_name, after:)
      ancestors = target.ancestors
      ancestors.drop(ancestors.index(after) + 1).any? { |ancestor| defines?(ancestor, method_name) } ||
        attribute?(owner, method_name) || catches_missing?(target, owner, method_name)
    end

    def ancestors(name)
      Object.const_get(name).ancestors.drop(1).filter_map(&:name)
    rescue StandardError
      []
    end

    def app_class?(name)
      location = Object.const_source_location(name)&.first
      location&.start_with?("#{File.expand_path(@layout.root)}/")
    end

    def defined_elsewhere?(owner, name, path)
      (Tracer.files_for(owner) | Tracer.files_for(owner.singleton_class)).any? do |file|
        file != path && source(file)&.methods&.key?(name)
      end
    end

    def source(path)
      @sources.fetch(path) do
        full = File.join(@layout.root, path)
        @sources[path] = File.file?(full) ? Source.parse(File.read(full)) : nil
      end
    end

    # Ruby's own method_missing and respond_to_missing? catch nothing. The
    # app's own might catch anything. A gem's, like ActiveRecord's dynamic
    # finders, catches what its respond_to_missing? says it does.
    def catches_missing?(target, owner, method_name)
      missing = target.instance_method(:method_missing).owner
      responds = target.instance_method(:respond_to_missing?).owner
      return false if missing == BasicObject && responds == Kernel
      return true if app_code?(target.instance_method(:method_missing)) || app_code?(target.instance_method(:respond_to_missing?))

      receiver = target.singleton_class? ? owner : target.allocate
      responds.instance_method(:respond_to_missing?).bind_call(receiver, method_name, true)
    rescue StandardError
      true
    end

    def app_code?(method)
      method.source_location&.first&.start_with?("#{File.expand_path(@layout.root)}/")
    end

    def defines?(mod, method_name)
      mod.method_defined?(method_name, false) || mod.private_method_defined?(method_name, false)
    end

    def attribute?(owner, method_name)
      owner.respond_to?(:attribute_names) && owner.attribute_names.include?(method_name.to_s.delete_suffix("=").delete_suffix("?"))
    end
  end
end
