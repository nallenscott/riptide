# frozen_string_literal: true

module Riptide
  # Resolves constant references the way Ruby's lexical lookup would, to the
  # module that defines each constant. Card::ROLES defined in a concern
  # resolves to Auditable::ROLES, the name a change to that concern
  # produces. Never triggers an autoload.
  class Resolver
    Constant = Struct.new(:name, :path, :value, keyword_init: true)

    def initialize(root:)
      @root_prefix = "#{File.expand_path(root)}/"
      @cache = {}
    end

    # The Constant a Source::Reference reads, or nil when it isn't defined
    # or isn't loaded.
    def resolve(reference)
      @cache[[reference.nesting, reference.segments, reference.absolute]] ||= candidates(reference).lazy.filter_map { |candidate| constant(candidate) }.first
    end

    # The module a name like "Billing::Card" refers to, if it's loaded.
    def module_named(name)
      value = loaded(name.split("::"))
      value.is_a?(Module) ? value : nil
    end

    def relative(path)
      path&.start_with?(@root_prefix) ? path.delete_prefix(@root_prefix) : nil
    end

    private

    def candidates(reference)
      path = reference.segments.join("::")
      return [path] if reference.absolute

      reference.nesting.reverse.map { |scope| "#{scope}::#{path}" } << path
    end

    def constant(candidate)
      *scope_names, name = candidate.split("::")
      scope = scope_names.empty? ? Object : loaded(scope_names)
      return nil unless scope.is_a?(Module)

      definer = scope.ancestors.find { |ancestor| ancestor.const_defined?(name, false) }
      definer = Object if definer.nil? && scope_names.empty? && Object.const_defined?(name, false)
      return nil unless definer && !definer.autoload?(name)

      location = definer.const_source_location(name, false)
      prefix = definer.equal?(Object) ? nil : definer.name
      Constant.new(name: [prefix, name].compact.join("::"), path: relative(location&.first), value: definer.const_get(name, false))
    rescue NameError
      nil
    end

    def loaded(segments)
      segments.reduce(Object) do |scope, segment|
        return nil unless scope.is_a?(Module) && scope.const_defined?(segment, false) && !scope.autoload?(segment)

        scope.const_get(segment, false)
      end
    rescue NameError
      nil
    end
  end
end
