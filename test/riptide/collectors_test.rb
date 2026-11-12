# frozen_string_literal: true

require "test_helper"
require "pathname"

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

    def test_reads_through_kernel_open_and_copy_stream_are_recorded
      FileUtils.mkdir_p(File.join(TRACE_ROOT, "reads"))
      %w[kernel copied written].each { |name| File.write(File.join(TRACE_ROOT, "reads/#{name}.txt"), name) }
      Collectors.install(TRACE_ROOT)
      window = Collectors.open
      open(File.join(TRACE_ROOT, "reads/kernel.txt"), &:read)
      open(File.join(TRACE_ROOT, "reads/written.txt"), "w") { |file| file.write("x") }
      IO.copy_stream(File.join(TRACE_ROOT, "reads/copied.txt"), File::NULL)

      assert_equal ["reads/copied.txt", "reads/kernel.txt"], window.reads.to_a.sort
    end

    # Pathname's checks go through FileTest. How big a file is depends on
    # what's in it, so a size check is a read and not just a listing.
    def test_checks_through_pathname_filetest_and_dir_are_recorded
      FileUtils.mkdir_p(File.join(TRACE_ROOT, "checks/dir"))
      %w[a b c d e f].each { |name| File.write(File.join(TRACE_ROOT, "checks/#{name}.txt"), name) }
      file = ->(name) { File.join(TRACE_ROOT, "checks/#{name}.txt") }
      Collectors.install(TRACE_ROOT)
      window = Collectors.open
      Pathname(file["a"]).exist?
      FileTest.file?(file["b"])
      File.readable?(file["c"])
      Dir.exist?(File.join(TRACE_ROOT, "checks/dir"))
      Dir.empty?(File.join(TRACE_ROOT, "checks/dir"))
      File.size?(file["d"])
      Pathname(file["e"]).zero?
      FileTest.size(file["f"])

      assert_equal ["checks/a.txt", "checks/b.txt", "checks/c.txt", "checks/dir", "checks/dir/*"], window.listings.to_a.sort
      assert_equal ["checks/d.txt", "checks/e.txt", "checks/f.txt"], window.reads.to_a.sort
    end

    # Only the app's own listings count, like test_helper globbing its
    # support files. Gems like Zeitwerk list every autoload directory.
    def test_reads_and_listings_outside_every_window_are_the_processs
      path = File.join(TRACE_ROOT, "boot/settings.yml")
      later = File.join(TRACE_ROOT, "boot/worker.yml")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "a: 1")
      File.write(later, "b: 2")
      Collectors.install(TRACE_ROOT)
      File.new(path).close
      load_traced("boot/loader.rb", <<~RUBY)
        Dir[File.join(__dir__, "**/*.rb")]
        Dir.glob("support/*.rb", base: File.dirname(__dir__))
        Dir.children(File.join(__dir__, "plugins")) rescue nil
      RUBY
      Dir[File.join(TRACE_ROOT, "gem/**/*.rb")]

      Collectors.install_frameworks
      File.read(later)

      process = Collectors.drain
      assert_equal ["boot/settings.yml", "boot/worker.yml"], process.reads.to_a.sort, "a read after boot, like a worker's setup, counts too"
      assert_equal ["boot/**/*.rb", "boot/plugins/*", "support/*.rb"], process.listings.to_a.sort, "a gem's listings aren't the app's"
      assert_empty Collectors.drain.reads
    end

    def test_windows_nest_and_each_keeps_what_ran_while_it_was_innermost
      FileUtils.mkdir_p(File.join(TRACE_ROOT, "nested"))
      %w[a b c].each { |name| File.write(File.join(TRACE_ROOT, "nested/#{name}.yml"), name) }
      Collectors.install(TRACE_ROOT)
      outer = Collectors.open
      File.read(File.join(TRACE_ROOT, "nested/a.yml"))
      inner = Collectors.open
      File.read(File.join(TRACE_ROOT, "nested/b.yml"))
      assert_same inner, Collectors.close
      File.read(File.join(TRACE_ROOT, "nested/c.yml"))

      assert_same outer, Collectors.close
      assert_equal ["nested/a.yml", "nested/c.yml"], outer.reads.to_a.sort
      assert_equal ["nested/b.yml"], inner.reads.to_a
      assert_nil Collectors.current
      assert_empty Collectors.drain.reads
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
