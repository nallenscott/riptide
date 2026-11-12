# frozen_string_literal: true

require "test_helper"

module Riptide
  class AnalysisTest < Minitest::Test
    CARD = <<~RUBY
      class Card
        LIMIT = 5
        UUID = ->(value) { value.delete("-") }

        belongs_to :user
        scope :primary, -> { where(primary: true) }

        def limit
          LIMIT
        end

        def charge(amount)
          amount * 2
        end

        def noop; end
      end
    RUBY

    # The class body's statements ran at load; method and lambda bodies didn't.
    LOADED = [2, 3, 5, 6, 8, 12, 16].to_h { |line| [line, { "owners" => ["Card"], "called" => false }] }

    def ruby(from, to, text: CARD, facts: LOADED, overrides: ->(_) { false })
      changes(text, text.sub(from, to), facts: facts, overrides: overrides)
    end

    def changes(old_text, new_text, facts: {}, overrides: ->(_) { false })
      Analysis::Ruby.new(old_text, new_text, load_facts: facts, overrides: overrides).change
    end

    # Card with charge moved to the end, written as +definition+.
    def charge_moved(definition = "  def charge(amount)\n    amount * 2\n  end\n")
      CARD.sub("  def charge(amount)\n    amount * 2\n  end\n\n", "").sub("  def noop; end\n", "  def noop; end\n\n#{definition}")
    end

    def test_a_method_body_edit_changes_that_method
      change = ruby("    LIMIT\n", "    LIMIT + 1\n")

      assert_equal ["Card#limit"], change.methods.to_a
      assert_empty change.owners
    end

    # Ruby fires no line event for `else`, `rescue` or an argument on its
    # own line, so a test can't have recorded them. Changing one still
    # changes the method that holds it.
    def test_an_edit_on_a_line_that_never_fires_an_event_changes_its_method
      text = <<~RUBY
        class Billing
          def total(amount)
            if amount.positive?
              amount
            else
              0
            end
          rescue ArgumentError
            log(
              amount,
              :warn
            )
          end
        end
      RUBY

      [["    else\n      0\n", "    elsif amount.zero?\n      0\n"], ["  rescue ArgumentError", "  rescue TypeError"], ["      :warn\n", "      :error\n"]].each do |from, to|
        assert_equal ["Billing#total"], ruby(from, to, text: text, facts: {}).methods.to_a, "editing #{from.strip}"
      end
    end

    def test_a_method_header_edit_changes_that_method_even_though_it_ran_at_load
      change = ruby("def charge(amount)", "def charge(amount, currency)")

      assert_equal ["Card#charge"], change.methods.to_a
      assert_empty change.owners
    end

    def test_removing_a_method_changes_that_method
      change = ruby("  def charge(amount)\n    amount * 2\n  end\n", "")

      assert_includes change.methods, "Card#charge"
    end

    def test_reordering_methods_changes_nothing
      assert changes(CARD, charge_moved).empty?
    end

    def test_a_moved_method_that_changed_still_changes
      assert_equal ["Card#charge"], changes(CARD, charge_moved("  def charge(amount)\n    amount * 3\n  end\n")).methods.to_a
    end

    def test_a_comment_that_moved_with_a_method_changes_nothing
      assert changes(CARD, charge_moved("  # Twice over.\n  def charge(amount)\n\n    amount * 2\n  end\n")).empty?
    end

    # Moving a method below `private` changes who can call it.
    def test_a_method_moved_across_a_class_level_line_changes
      text = "class Card\n  def total\n    1\n  end\n\n  def fee\n    2\n  end\n\n  private\n\n  def secret\n    3\n  end\nend\n"
      moved = text.sub("  def total\n    1\n  end\n\n", "").sub("  def secret\n", "  def total\n    1\n  end\n\n  def secret\n")

      assert_includes changes(text, moved).methods, "Card#total"
    end

    # An alias names the method as it stands when the class body reaches
    # it, so moving the method past one changes what loads.
    def test_a_method_moved_past_an_alias_of_it_changes
      text = "class Card\n  def total\n    1\n  end\n\n  alias_method :sum, :total\n\n  def fee\n    2\n  end\nend\n"
      moved = text.sub("  def total\n    1\n  end\n\n", "").sub("  def fee\n    2\n  end\n", "  def fee\n    2\n  end\n\n  def total\n    1\n  end\n")

      assert_includes changes(text, moved).methods, "Card#total"
    end

    # The same line twice is still two places: a move from after the first
    # `private` to after the second crosses the `public` between them.
    def test_a_method_moved_between_identical_class_level_lines_changes
      text = "class Card\n  private\n\n  def total\n    1\n  end\n\n  public\n\n  def fee\n    2\n  end\n\n  private\n\n  def secret\n    3\n  end\nend\n"
      moved = text.sub("  def total\n    1\n  end\n\n", "").sub("  def secret\n", "  def total\n    1\n  end\n\n  def secret\n")

      assert_includes changes(text, moved).methods, "Card#total"
    end

    # A `sig` or `desc` applies to the method right after it, so swapping
    # that method with another changes both.
    def test_swapping_the_method_right_after_a_class_level_line_changes_both
      text = "class Card\n  sig { returns(Integer) }\n  def total\n    1\n  end\n\n  def fee\n    2\n  end\nend\n"
      moved = "class Card\n  sig { returns(Integer) }\n  def fee\n    2\n  end\n\n  def total\n    1\n  end\nend\n"

      assert_equal ["Card#fee", "Card#total"], changes(text, moved).methods.to_a.sort
    end

    def test_a_new_method_between_a_sig_and_its_method_changes_that_method
      text = "class Card\n  sig { returns(Integer) }\n  def total\n    1\n  end\nend\n"
      added = "class Card\n  sig { returns(Integer) }\n  def fresh\n    0\n  end\n\n  def total\n    1\n  end\nend\n"

      assert_equal ["Card#total"], changes(text, added).methods.to_a
    end

    def test_editing_a_class_level_line_leaves_the_methods_after_it_alone
      assert_empty ruby("LIMIT = 5", "LIMIT = 6").methods
      assert_empty ruby("scope :primary, -> { where(primary: true) }", "scope :primary, -> { where(primary: false) }").methods
    end

    def test_reordering_methods_after_the_first_one_past_a_line_changes_nothing
      text = "class Card\n  private\n\n  def total\n    1\n  end\n\n  def fee\n    2\n  end\n\n  def secret\n    3\n  end\nend\n"
      moved = "class Card\n  private\n\n  def total\n    1\n  end\n\n  def secret\n    3\n  end\n\n  def fee\n    2\n  end\nend\n"

      assert changes(text, moved).empty?
    end

    # Only the last definition is compared, but an alias between two can
    # still call the first.
    def test_editing_a_method_defined_twice_changes_it
      text = "class Card\n  def total\n    1\n  end\n\n  alias_method :sum, :total\n\n  def total\n    3\n  end\nend\n"
      moved = text.sub("    1\n", "    2\n")

      assert_equal ["Card#total"], changes(text, moved).methods.to_a
    end

    # Reopening a class in the same file gives it a second body, and the
    # first one runs before the second defines anything.
    def test_a_method_moved_to_another_body_of_its_class_changes
      text = "class Card\n  def total\n    1\n  end\n\n  def fee\n    2\n  end\nend\n\nclass Card\n  def secret\n    3\n  end\nend\n"
      moved = "class Card\n  def fee\n    2\n  end\nend\n\nclass Card\n  def total\n    1\n  end\n\n  def secret\n    3\n  end\nend\n"

      assert_includes changes(text, moved).methods, "Card#total"
    end

    def test_a_method_moved_to_another_class_changes
      text = "class Card\n  def total\n    1\n  end\n\n  def fee\n    2\n  end\nend\n\nclass Bill\n  def secret\n    3\n  end\nend\n"
      moved = "class Card\n  def fee\n    2\n  end\nend\n\nclass Bill\n  def total\n    1\n  end\n\n  def secret\n    3\n  end\nend\n"
      change = changes(text, moved, overrides: ->(name) { name == "Bill#total" })

      assert_includes change.methods, "Card#total"
      assert_equal ["Bill"], change.owners.to_a
    end

    def test_reordering_methods_in_a_block_changes_them
      text = "class Card\n  Row = Struct.new(:a) do\n    def total\n      1\n    end\n\n    def fee\n      2\n    end\n  end\nend\n"
      moved = "class Card\n  Row = Struct.new(:a) do\n    def fee\n      2\n    end\n\n    def total\n      1\n    end\n  end\nend\n"

      assert_includes changes(text, moved).methods, "Card::Row#total"
    end

    def test_adding_a_method_that_overrides_nothing_changes_nothing
      change = ruby("  def noop; end\n", "  def noop; end\n\n  def fresh\n    :new\n  end\n")

      assert change.empty?
    end

    def test_adding_a_method_that_overrides_one_changes_the_owner
      change = ruby("  def noop; end\n", "  def noop; end\n\n  def to_s\n    :card\n  end\n", overrides: ->(name) { name == "Card#to_s" })

      assert_equal ["Card"], change.owners.to_a
    end

    # Calling an empty method still fires its call event, so a test that
    # called one recorded it.
    def test_adding_a_body_to_an_empty_method_changes_that_method
      change = ruby("  def noop; end\n", "  def noop\n    :now\n  end\n")

      assert_equal ["Card#noop"], change.methods.to_a
      assert_empty change.owners
    end

    def test_a_constant_edit_changes_that_constant_even_though_it_ran_at_load
      change = ruby("LIMIT = 5", "LIMIT = 6")

      assert_equal ["Card::LIMIT"], change.constants.to_a
      assert_empty change.owners
    end

    def test_a_new_constant_also_changes_every_name_it_could_shadow
      change = ruby("  LIMIT = 5\n", "  LIMIT = 5\n  MAX = 9\n")

      assert_equal %w[Card::MAX MAX], change.constants.to_a.sort
    end

    def test_a_one_line_lambda_whose_statement_ran_at_load_changes_only_its_block
      change = ruby('value.delete("-")', 'value.delete("_")')

      assert_equal [3], change.blocks.to_a
      assert_empty change.constants
    end

    def test_renaming_a_one_line_lambda_constant_changes_the_constant
      change = ruby("UUID = ->", "UID = ->")

      assert_includes change.constants, "Card::UUID"
      assert_includes change.constants, "UID"
    end

    def test_a_scope_lambda_edit_changes_its_block_and_a_scope_rename_changes_the_owner
      lambda_only = ruby("where(primary: true)", "where(primary: false)")
      renamed = ruby("scope :primary", "scope :main")

      assert_equal [6], lambda_only.blocks.to_a
      assert_empty lambda_only.owners
      assert_equal ["Card"], renamed.owners.to_a
    end

    def test_a_block_that_ran_at_load_also_changes_the_owner
      ran = LOADED.merge(6 => { "owners" => ["Card"], "called" => true })
      change = ruby("where(primary: true)", "where(primary: false)", facts: ran)

      assert_equal [6], change.blocks.to_a
      assert_equal ["Card"], change.owners.to_a
    end

    def test_a_block_with_no_load_facts_falls_back_to_the_owner
      change = ruby("where(primary: true)", "where(primary: false)", facts: nil)

      assert_equal ["Card"], change.owners.to_a
    end

    def test_a_declaration_edit_changes_the_owner
      change = ruby("belongs_to :user", "belongs_to :user, optional: true", facts: {})

      assert_equal ["Card"], change.owners.to_a
    end

    def test_a_method_that_ran_at_load_changes_itself_and_the_classes_it_ran_for
      macro = "module Auditing\n  def has_audit\n    @audit = true\n  end\nend\n"
      change = Analysis::Ruby.new(macro, macro.sub("true", ":full"), load_facts: { 3 => { "owners" => %w[Card Invoice], "called" => true } }, overrides: ->(_) { false }).change

      assert_equal %w[Card Invoice], change.owners.to_a.sort
      assert_equal ["Auditing#has_audit"], change.methods.to_a
    end

    def test_a_top_level_edit_changes_the_whole_suite
      text = "require 'csv'\n\nclass Report\nend\n"

      assert ruby("require 'csv'", "require 'json'", text: text, facts: {}).suite?
    end

    def test_comment_and_blank_line_edits_change_nothing
      assert ruby("  LIMIT = 5\n", "  # the limit\n\n  LIMIT = 5\n").empty?
    end

    def test_adding_a_magic_comment_changes_the_whole_file
      text = "class Buf\n  def build\n    s = +\"a\"\n  end\nend\n"
      change = Analysis::Ruby.new(text, "# frozen_string_literal: true\n\n#{text}", load_facts: nil, overrides: ->(_) { false }).change

      assert change.whole?
    end

    def test_a_file_that_no_longer_parses_changes_as_a_whole
      assert ruby("def charge(amount)", "def charge(amount").whole?
    end

    STRUCTURE = <<~SQL
      SET statement_timeout = 0;

      CREATE TABLE public.cards (
          id bigint NOT NULL,
          user_id bigint
      );

      CREATE INDEX index_cards_on_user_id ON public.cards USING btree (user_id);

      CREATE FUNCTION public.touch() RETURNS trigger
          LANGUAGE plpgsql;

      INSERT INTO "schema_migrations" (version) VALUES
      ('20260101000000');
    SQL

    def sql(from, to) = Analysis::Sql.new(STRUCTURE, STRUCTURE.sub(from, to)).change

    def test_a_column_change_changes_its_table
      assert_equal ["cards"], sql("user_id bigint\n", "user_id bigint,\n    name text\n").tables.to_a
    end

    def test_an_index_change_changes_its_table
      assert_equal ["cards"], sql("btree (user_id)", "btree (user_id, id)").tables.to_a
    end

    def test_a_foreign_key_changes_the_table_it_points_at_too
      key = "CREATE INDEX index_cards_on_user_id ON public.cards USING btree (user_id);\n\n" \
            "ALTER TABLE ONLY public.cards\n    ADD CONSTRAINT fk_cards_user FOREIGN KEY (user_id) REFERENCES public.users(id);\n"

      assert_equal %w[cards users], sql("CREATE INDEX index_cards_on_user_id ON public.cards USING btree (user_id);\n", key).tables.to_a.sort
      assert_equal %w[cards users], sql("user_id bigint\n", "user_id bigint REFERENCES public.users(id)\n").tables.to_a.sort
    end

    def test_a_new_migration_version_changes_nothing
      assert sql("('20260101000000');", "('20260101000000'),\n('20260102000000');").empty?
    end

    def test_a_statement_about_no_one_table_changes_the_file
      assert sql("LANGUAGE plpgsql", "LANGUAGE sql").whole?
    end

    SCHEMA = <<~RUBY
      ActiveRecord::Schema[7.1].define(version: 2026_01_01_000000) do
        create_table "cards", force: :cascade do |t|
          t.bigint "user_id"
        end

        add_foreign_key "cards", "users"
      end
    RUBY

    def schema(from, to) = Analysis::Schema.new(SCHEMA, SCHEMA.sub(from, to)).change

    def test_a_schema_column_change_changes_its_table
      assert_equal ["cards"], schema('t.bigint "user_id"', 't.bigint "owner_id"').tables.to_a
    end

    def test_a_schema_foreign_key_change_changes_both_tables
      assert_equal %w[cards users], schema('add_foreign_key "cards", "users"', 'add_foreign_key "cards", "users", on_delete: :cascade').tables.to_a.sort
    end

    def test_a_schema_version_bump_changes_nothing
      assert schema("2026_01_01_000000", "2026_01_02_000000").empty?
    end

    def test_a_fixture_change_changes_its_table
      change = Analysis::Fixture.new("one:\n  id: 1\n", "one:\n  id: 2\n", table: "cards").change

      assert_equal ["cards"], change.tables.to_a
    end
  end
end
