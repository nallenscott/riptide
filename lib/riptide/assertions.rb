# frozen_string_literal: true

require "digest"
require "set"

module Riptide
  # Notes what each assertion and mock expectation in a test body compared,
  # for the statement that ran it.
  module Assertions
    NAME = /\A(assert|refute)/

    class << self
      # Each assertion is wrapped in the module that defines it, so the
      # wrapper reaches every class that includes it, like ActiveSupport's
      # assert_difference, which one on Minitest::Test would sit behind.
      # +runnables+ are the test classes, loaded by now.
      def install(runnables)
        owners = Hash.new { |h, owner| h[owner] = Set.new }
        runnables.each do |klass|
          next unless klass <= ::Minitest::Test

          klass.public_instance_methods.grep(NAME).each { |name| owners[klass.instance_method(name).owner] << name }
        end
        owners.each { |owner, names| owner.prepend(wrapper(names)) unless wrapped?(owner) }
        ::Mocha::Expectation.prepend(Expectations) if defined?(::Mocha::Expectation) && !(::Mocha::Expectation < Expectations)
      end

      # 32 bits of what a comparison saw, with what changes from run to run
      # left out: a record's id and timestamps, and times themselves.
      # Nothing here queries, so a relation that hasn't loaded counts by its
      # SQL. Only worked out when it counts, and a value riptide can't
      # describe never fails the assertion: its digest is 0.
      def digest(values)
        return unless Collectors.comparing?

        Digest::SHA1.hexdigest(shape(values).inspect)[0, 8].to_i(16)
      rescue StandardError
        0
      end

      private

      def wrapped?(owner) = owner.ancestors.take_while { |mod| !mod.equal?(owner) }.any? { |mod| mod.is_a?(Wrapper) }

      def wrapper(names)
        Wrapper.new do
          names.each do |name|
            define_method(name) { |*args, **options, &block| Collectors.compared(Assertions.digest(args)) { super(*args, **options, &block) } }
          end
        end
      end

      def shape(value)
        case value
        when Array then value.map { shape(_1) }
        when Hash then value.to_h { |key, inner| [shape(key), shape(inner)] }
        when Time, Proc, Method then value.class.name
        else
          if defined?(::ActiveRecord::Base) && value.is_a?(::ActiveRecord::Base)
            [value.class.name, value.attributes.except(value.class.primary_key).reject { |name, _| name.end_with?("_at") }.transform_values { shape(_1) }]
          elsif defined?(::ActiveRecord::Relation) && value.is_a?(::ActiveRecord::Relation)
            value.loaded? ? value.to_a.map { shape(_1) } : value.to_sql
          elsif defined?(::Date) && value.is_a?(::Date)
            value.class.name
          else
            value.inspect[0, 500]
          end
        end
      end
    end

    # The modules install prepends, so installing twice wraps nothing twice.
    class Wrapper < Module; end

    # What a mock expects to be called with is what it checks.
    module Expectations
      def with(*args, **options, &block)
        Collectors.compared(Assertions.digest([args, options])) { super }
      end
    end
  end
end
