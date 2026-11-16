# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "rbconfig"
require_relative "../../ext/riptide/ruby_source"

module Riptide
  class RubySourceTest < Minitest::Test
    EXT = File.expand_path("../../ext/riptide", __dir__)

    # The Ruby source the tracer was built against, which these tests copy
    # from instead of downloading.
    def tree
      given = ENV["RIPTIDE_RUBY_SOURCE"]
      found = given && !given.empty? ? given : Dir[File.expand_path("../../tmp/*/riptide_native/#{RUBY_VERSION}/ruby-#{RUBY_REVISION}", __dir__)].first
      skip "no Ruby source left from building the tracer" unless found && File.exist?(File.join(found, "vm_core.h"))
      found
    end

    # What GitHub's archive of +tree+ holds that riptide keeps: everything but
    # the headers Ruby's build generates. vm_core.h comes first.
    def kept_files
      files = Dir.glob("**/*", base: tree).select { |f| f.match?(RubySource::KEEP) && File.file?(File.join(tree, f)) }
      (files - RubySource::GENERATED.keys).sort_by { |f| [f == "vm_core.h" ? 0 : 1, f] }
    end

    def archive(files = kept_files, &each)
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io)
      Gem::Package::TarWriter.new(gz) do |tar|
        files.each do |f|
          body = each ? each.(f) : File.binread(File.join(tree, f))
          tar.add_file_simple("ruby-#{RUBY_REVISION}/#{f}", 0o644, body.bytesize) { |out| out.write(body) }
        end
      end
      gz.close
      io.string
    end

    def downloaded_from(archive)
      RubySource.stub(:download, archive) { RubySource.downloaded }
    end

    def in_build_dir(&block)
      Dir.mktmpdir { |dir| Dir.chdir(dir, &block) }
    end

    # A copy of +tree+ without the headers Ruby generates, that nothing can
    # write to.
    def bare_tree(dir)
      bare = File.join(dir, "bare")
      kept_files.each do |f|
        FileUtils.mkdir_p(File.dirname(File.join(bare, f)))
        FileUtils.cp(File.join(tree, f), File.join(bare, f))
      end
      FileUtils.chmod_R("a-w", bare)
      bare
    end

    def writable(dir)
      FileUtils.chmod_R("u+w", dir) if File.exist?(dir)
    end

    def test_a_download_generates_the_headers_ruby_generates
      in_build_dir do
        dir = downloaded_from(archive)

        assert_equal File.expand_path("ruby-#{RUBY_REVISION}"), dir
        RubySource::GENERATED.each_key { |header| assert_equal File.binread(File.join(tree, header)), File.binread(File.join(dir, header)), header }
      end
    end

    def test_a_download_that_dies_partway_starts_over
      in_build_dir do
        whole = archive
        assert_raises(Zlib::Error) { downloaded_from(whole.byteslice(0, whole.bytesize / 2)) }
        refute File.exist?("ruby-#{RUBY_REVISION}")

        dir = downloaded_from(whole)
        assert_empty kept_files.reject { |f| File.exist?(File.join(dir, f)) }
      end
    end

    def test_a_download_whose_headers_fail_to_generate_starts_over
      in_build_dir do
        capture_subprocess_io { assert_raises(RuntimeError) { downloaded_from(archive(kept_files - ["template/id.h.tmpl"])) } }
        refute File.exist?("ruby-#{RUBY_REVISION}")

        # A generator killed partway through its header.
        File.write("ruby-#{RUBY_REVISION}.partial/id.h", "#ifndef RUBY_ID_H\n")
        assert_equal File.binread(File.join(tree, "id.h")), File.binread(File.join(downloaded_from(archive), "id.h"))
      end
    end

    def test_an_archive_path_that_leaves_the_tree_is_refused
      in_build_dir do
        escaping = archive(["internal/../../escaped.h"]) { "int x;\n" }

        error = assert_raises(RuntimeError) { RubySource.extract(escaping, File.expand_path("source/out")) }
        assert_match(/leaves it/, error.message)
        assert_empty Dir.glob("**/escaped.h")
      end
    end

    def test_a_given_tree_gets_the_headers_it_lacks_without_being_written_to
      in_build_dir do |dir|
        bare = bare_tree(dir)

        dirs = RubySource.include_dirs(bare)
        assert_equal [bare, File.expand_path("ruby-generated")], dirs
        RubySource::GENERATED.each_key { |header| assert_equal File.binread(File.join(tree, header)), File.binread(File.join(dirs.last, header)), header }
        RubySource::GENERATED.each_key { |header| refute File.exist?(File.join(bare, header)), header }
      ensure
        writable(bare)
      end
    end

    def test_a_given_tree_that_has_its_headers_gets_none_generated
      in_build_dir do
        assert_empty Dir.children(RubySource.include_dirs(tree).last)
      end
    end

    # Runs a copy of the extension's extconf against +source+ and returns
    # why the tracer is off, or nil. The block can change the tracer's C.
    def configure(dir, source)
      ext = File.join(dir, "ext/riptide")
      FileUtils.mkdir_p([ext, File.join(dir, "lib/riptide"), File.join(dir, "build")])
      FileUtils.cp(Dir[File.join(EXT, "*.{c,rb}")], ext)
      FileUtils.cp(File.expand_path("../../lib/riptide/version.rb", __dir__), File.join(dir, "lib/riptide"))
      yield File.join(ext, "riptide_native.c") if block_given?
      env = { "RIPTIDE_RUBY_SOURCE" => source, "RIPTIDE_TRACER" => "on" }
      assert system(env, RbConfig.ruby, File.join(ext, "extconf.rb"), chdir: File.join(dir, "build"), out: File::NULL, err: File::NULL)
      File.read(File.join(dir, "build/riptide_build.h"))[/RIPTIDE_UNSUPPORTED "(.*)"/, 1]
    end

    def test_the_tracer_builds_against_a_tree_ruby_hasnt_built
      Dir.mktmpdir do |dir|
        bare = bare_tree(dir)

        assert_nil configure(dir, bare)
      ensure
        writable(bare)
      end
    end

    # A function the tracer calls that Ruby doesn't export compiles, and the
    # extension even loads, but the process dies on the call.
    def test_the_tracer_stays_off_on_a_ruby_missing_a_function_it_calls
      Dir.mktmpdir do |dir|
        off = configure(dir, tree) { |c| File.write(c, File.read(c) + "void riptide_missing(void);\nvoid riptide_calls_it(void) { riptide_missing(); }\n") }

        assert_equal "the tracer doesn't build against Ruby #{RUBY_VERSION}", off
      end
    end
  end
end
