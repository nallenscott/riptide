# frozen_string_literal: true

require "test_helper"

module Riptide
  class ResolverTest < Minitest::Test
    include TracedFixture

    def reference(nesting, segments, absolute: false)
      Source::Reference.new(nesting: nesting, segments: segments, absolute: absolute)
    end

    def resolver = Resolver.new(root: TRACE_ROOT)

    def test_a_relative_reference_resolves_through_the_nesting
      load_traced("resolve/nested.rb", "module ResolveOuter\n  LIMIT = 3\n  class Reader\n  end\nend\n")

      constant = resolver.resolve(reference(%w[ResolveOuter ResolveOuter::Reader], ["LIMIT"]))

      assert_equal "ResolveOuter::LIMIT", constant.name
      assert_equal "resolve/nested.rb", constant.path
    end

    def test_a_constant_from_an_included_module_resolves_to_that_module
      load_traced("resolve/concern.rb", "module ResolveConcern\n  ROLES = %w[admin].freeze\nend\n")
      load_traced("resolve/model.rb", "class ResolveModel\n  include ResolveConcern\nend\n")

      constant = resolver.resolve(reference(["ResolveModel"], ["ROLES"]))

      assert_equal "ResolveConcern::ROLES", constant.name
      assert_equal "resolve/concern.rb", constant.path
    end

    def test_an_absolute_reference_skips_the_nesting
      load_traced("resolve/top.rb", "RESOLVE_TOP = 1\nmodule ResolveInner\n  RESOLVE_TOP = 2\nend\n")

      assert_equal "RESOLVE_TOP", resolver.resolve(reference(["ResolveInner"], ["RESOLVE_TOP"], absolute: true)).name
      assert_equal "ResolveInner::RESOLVE_TOP", resolver.resolve(reference(["ResolveInner"], ["RESOLVE_TOP"])).name
    end

    def test_a_class_resolves_with_its_value
      load_traced("resolve/klass.rb", "class ResolveKlass\nend\n")

      assert_equal ResolveKlass, resolver.resolve(reference([], ["ResolveKlass"])).value
    end

    def test_an_autoload_is_never_triggered
      path = File.join(TRACE_ROOT, "resolve/lazy.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "class ResolveLazy\nend\n")
      Object.autoload(:ResolveLazy, path)

      assert_nil resolver.resolve(reference([], ["ResolveLazy"]))
      assert Object.autoload?(:ResolveLazy)
    end

    def test_an_undefined_constant_resolves_to_nil
      assert_nil resolver.resolve(reference(["Nowhere"], ["Nothing"]))
    end
  end
end
