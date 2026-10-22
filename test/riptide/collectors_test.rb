# frozen_string_literal: true

require "test_helper"

module Riptide
  class CollectorsTest < Minitest::Test
    include TracedFixture

    def teardown
      Collectors.close
    end

    def test_instantiated_classes_are_recorded_inside_a_window_only
      klass = Class.new { prepend Collectors::Instantiations }
      klass.new
      window = Collectors.open
      klass.new
      Collectors.close

      assert_equal [klass], window.classes.to_a
    end

    def test_tables_come_from_every_table_a_statement_names
      sql = 'SELECT "cards".* FROM "cards" INNER JOIN "users" ON 1=1 WHERE id IN (SELECT card_id FROM charges)'

      assert_equal %w[cards charges users], Collectors.tables_in(sql).sort
      assert_equal %w[cards], Collectors.tables_in('UPDATE "cards" SET x = 1')
      assert_equal %w[cards], Collectors.tables_in('INSERT INTO "cards" (id) VALUES (1)')
      assert_equal %w[cards], Collectors.tables_in('TRUNCATE TABLE "public"."cards"')
    end

    def test_every_table_in_a_comma_separated_from_list_counts
      sql = 'SELECT 1 FROM "cards" c, public.users AS u, charges WHERE c.id = u.id'

      assert_equal %w[cards charges users], Collectors.tables_in(sql).sort
    end

    def test_files_read_under_the_root_are_recorded
      path = File.join(TRACE_ROOT, "reads/data.txt")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "data")
      Collectors.install(TRACE_ROOT)
      window = Collectors.open
      File.read(path)
      File.read(__FILE__)

      assert_equal ["reads/data.txt"], window.reads.to_a
    end

    def test_reads_through_io_and_file_new_are_recorded
      path = File.join(TRACE_ROOT, "reads/io.txt")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "data")
      Collectors.install(TRACE_ROOT)
      window = Collectors.open
      IO.read(path)
      File.new(path, mode: "r").close

      assert_equal ["reads/io.txt"], window.reads.to_a
    end

    def test_opening_a_file_to_write_isnt_a_read
      path = File.join(TRACE_ROOT, "reads/written.txt")
      FileUtils.mkdir_p(File.dirname(path))
      Collectors.install(TRACE_ROOT)
      window = Collectors.open
      File.open(path, "w") { |file| file.write("x") }
      File.open(path, File::WRONLY | File::APPEND) { |file| file.write("y") }
      File.open(path) { |file| file.read }

      assert_equal ["reads/written.txt"], window.reads.to_a
      assert_equal 1, window.reads.size
    end

    # Only the app's own listings count, like test_helper globbing its
    # support files. Gems like Zeitwerk list every autoload directory.
    def test_reads_and_listings_before_frameworks_install_are_boot_reads
      path = File.join(TRACE_ROOT, "boot/settings.yml")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "a: 1")
      Collectors.install(TRACE_ROOT)
      File.new(path).close
      load_traced("boot/loader.rb", <<~RUBY)
        Dir[File.join(__dir__, "**/*.rb")]
        Dir.glob("support/*.rb", base: File.dirname(__dir__))
        Dir.children(File.join(__dir__, "plugins")) rescue nil
      RUBY
      Dir[File.join(TRACE_ROOT, "gem/**/*.rb")]

      assert_includes Collectors.boot_reads, "boot/settings.yml"
      assert_equal ["boot/**/*.rb", "boot/plugins/*", "support/*.rb"], Collectors.boot_globs.to_a.sort, "a gem's listings aren't the app's"
      Collectors.install_frameworks
      assert_nil Collectors.boot_reads
    end

    def test_a_translation_marks_the_window
      i18n = Object.new
      def i18n.translate(key) = key.to_s
      i18n.singleton_class.prepend(Collectors::Translations)
      window = Collectors.open
      i18n.translate(:hello)

      assert window.translated
    end
  end
end
