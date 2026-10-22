# frozen_string_literal: true

require "test_helper"

module Riptide
  class SourceTest < Minitest::Test
    MODEL = <<~RUBY
      module Billing
        class Card < Base
          LIMIT = 5
          UUID = ->(value) { value.delete("-") }

          belongs_to :user
          scope :primary, -> { where(primary: true) }
          included do
            validates :name
          end

          def limit
            LIMIT
          end

          def self.build(attrs,
                         extra)
            new(attrs)
          end

          def noop; end

          class << self
            def finder = :found
          end
        end
      end
    RUBY

    def source(text = MODEL) = Source.parse(text)

    def kind(line, text = MODEL) = source(text).unit_at(line)&.kind

    def test_class_headers_and_class_level_statements_are_declarations
      assert_equal :declaration, kind(2)
      assert_equal "Billing::Card", source.unit_at(2).owner
      assert_equal :declaration, kind(6)
      assert_equal :declaration, kind(8)
    end

    def test_constants_are_named_with_their_owner
      assert_equal :constant, kind(3)
      assert_equal "Billing::Card::LIMIT", source.unit_at(3).name
      assert_equal 3..3, source.constants.fetch("Billing::Card::LIMIT")
    end

    def test_block_bodies_inside_statements_are_their_own_kind
      assert_equal :block_body, kind(9)
      assert_equal :block_body, kind(4)
      assert_equal :block_body, kind(7)
    end

    def test_method_headers_and_bodies
      assert_equal :method_header, kind(12)
      assert_equal :method_body, kind(13)
      assert_equal "Billing::Card#limit", source.unit_at(13).name
    end

    def test_a_multi_line_header_runs_to_its_closing_paren
      method = source.methods.fetch("Billing::Card.build")

      assert_equal 16..17, method.header
      assert_equal 18..19, method.body
    end

    def test_methods_in_a_singleton_class_are_class_methods
      assert source.methods.key?("Billing::Card.finder")
    end

    def test_methods_defined_in_a_block_belong_to_the_constant
      text = <<~RUBY
        class Report
          Row = Struct.new(:a) do
            def total
              a * 2
            end
          end
        end
      RUBY

      assert_equal :method_body, kind(4, text)
      assert source(text).methods.key?("Report::Row#total")
    end

    def test_top_level_statements_and_methods
      text = "require 'csv'\n\ndef helper\n  :ok\nend\n"

      assert_equal :top, kind(1, text)
      assert source(text).methods.key?("Object#helper")
    end

    def test_comments_and_blank_lines_belong_to_nothing
      text = "class Note\n  # why\n\n  def go\n    # inside\n    :went\n  end\nend\n"

      assert_nil source(text).unit_at(2)
      assert_nil source(text).unit_at(3)
      assert_nil source(text).unit_at(5)
    end

    def test_heredoc_content_counts_even_when_it_looks_blank_or_commented
      text = "class Note\n  TEXT = <<~T\n    a\n\n    # b\n  T\nend\n"

      assert_equal :constant, kind(4, text)
      assert_equal :constant, kind(5, text)
    end

    def test_anything_after_end_is_data
      text = "class Note\n  def go = DATA.read\nend\n__END__\nhello\n"

      assert_equal :data, kind(5, text)
    end

    def test_constant_references_carry_their_lexical_nesting
      text = <<~RUBY
        module Outer
          class Inner::Deep
            def go
              [LIMIT, ::Top::Thing, Other::Thing]
            end
          end
        end
      RUBY

      references = source(text).references_at(4)

      # Inner::Deep is whichever of the two names exists at runtime.
      assert_equal [%w[Outer Inner::Deep Outer::Inner::Deep]] * 3, references.map(&:nesting)
      assert_equal [%w[LIMIT], %w[Top Thing], %w[Other Thing]], references.map(&:segments)
      assert_equal [false, true, false], references.map(&:absolute)
    end

    def test_a_superclass_reference_resolves_outside_the_class
      references = source.references_at(2)

      assert_equal [[%w[Billing], %w[Base]]], references.map { |r| [r.nesting, r.segments] }
    end

    def test_a_statement_with_blocks_keeps_its_head_with_the_bodies_blanked
      head = ->(text) { Source.parse(text).unit_at(7).parent.head }

      assert_equal head.(MODEL), head.(MODEL.sub("where(primary: true)", "where(primary: false)"))
      refute_equal head.(MODEL), head.(MODEL.sub("scope :primary", "scope :main"))
    end

    def test_a_head_is_cut_by_bytes_around_non_ascii_text
      text = "class Note\n  scope :café, -> { where(name: \"crème\") }\nend\n"

      assert_equal "scope :café, -> {  }".b, Source.parse(text).unit_at(2).parent.head
    end

    def test_a_statement_without_blocks_keeps_no_head
      assert_nil source.unit_at(6).head
    end

    def test_parse_returns_nil_for_source_that_does_not_parse
      assert_nil Source.parse("def (")
    end

    def test_a_leading_double_colon_names_a_top_level_class
      text = "module Admin\n  class ::Widget\n    include Foo\n  end\nend\n"

      assert_equal "Widget", source(text).unit_at(3).owner
    end

    def test_a_method_defined_inside_a_call_is_still_a_method
      text = "class Card\n  private def secret\n    1\n  end\nend\n"

      assert_equal :method_body, source(text).unit_at(3).kind
      assert_equal ["Card#secret"], source(text).methods.keys
    end

    def test_a_literal_top_level_constant_is_a_constant_and_a_computed_one_is_top_level
      text = "MAX = 5\nLIMIT = Config.load(MAX)\n"

      assert_equal :constant, source(text).unit_at(1).kind
      assert_equal :top, source(text).unit_at(2).kind
    end

    def test_a_constant_that_ran_code_is_computed
      text = "class Foo\n  LIMIT = Calc.base * 2\n  NAMES = %w[a b].freeze\n  MAX = 5\n  NOW = current_time\nend\n"

      assert source(text).computed?("Foo::LIMIT")
      assert source(text).computed?("Foo::NOW")
      refute source(text).computed?("Foo::NAMES"), "freeze runs Ruby's code, not the app's"
      refute source(text).computed?("Foo::MAX")
    end

    def test_dynamic_constant_reads_keep_their_last_segment
      text = "class Lookup\n  def a = self.class::LIMIT\n  def b = const_get(:SIZE)\nend\n"

      assert_equal [[["LIMIT"], true]], source(text).references_at(2).map { |reference| [reference.segments, reference.dynamic] }
      assert_equal [[["SIZE"], true]], source(text).references_at(3).map { |reference| [reference.segments, reference.dynamic] }
    end
  end
end
