# frozen_string_literal: true

require "test_helper"
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

    # What Ruby's build generates each header from. A Ruby that checks one of
    # them in has no template for it.
    TEMPLATES = {
      "id.h" => "template/id.h.tmpl",
      "prism/ast.h" => "prism/templates/include/prism/ast.h.erb",
      "prism/diagnostic.h" => "prism/templates/include/prism/diagnostic.h.erb"
    }.freeze

    # The headers riptide generates that this Ruby's build generates too.
    def generated
      RubySource::GENERATED.keys.select { |header| File.exist?(File.join(tree, TEMPLATES.fetch(header))) }
    end

    # The files in +tree+ that riptide checks out: everything under PATHS
    # but the headers Ruby's build generates.
    def kept_files
      dirs, files = RubySource::PATHS.map { |path| path.delete_prefix("/") }.partition { |path| path.end_with?("/") }
      headers = generated
      Dir.glob("**/*", base: tree).select do |f|
        File.file?(File.join(tree, f)) && !headers.include?(f) &&
          (dirs.any? { |dir| f.start_with?(dir) } || files.any? { |glob| File.fnmatch?(glob, f, File::FNM_PATHNAME) })
      end
    end

    # A repository holding +files+ from +tree+ in one commit, plus +extra+
    # files by content, served the way GitHub serves Ruby's. Returns its URL
    # and the commit's sha.
    def origin(dir, files = kept_files, extra: {})
      repo = File.join(dir, "origin-#{files.size}")
      files.each do |f|
        FileUtils.mkdir_p(File.dirname(File.join(repo, f)))
        FileUtils.cp(File.join(tree, f), File.join(repo, f))
      end
      extra.each do |f, content|
        FileUtils.mkdir_p(File.dirname(File.join(repo, f)))
        File.write(File.join(repo, f), content)
      end
      git = ->(*args) { system("git", "-C", repo, *args, exception: true, out: File::NULL) }
      git.("init", "-q")
      git.("config", "uploadpack.allowFilter", "true")
      git.("config", "uploadpack.allowAnySHA1InWant", "true")
      git.("add", "-A")
      git.("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "ruby")
      ["file://#{repo}", IO.popen(["git", "-C", repo, "rev-parse", "HEAD"], &:read).strip]
    end

    def in_build_dir(&block)
      Dir.mktmpdir { |dir| Dir.chdir(dir) { block.call(dir) } }
    end

    # Yields a copy of +tree+ without the headers Ruby generates, that
    # nothing can write to, and makes it writable again so it can be removed.
    def with_bare_tree(dir)
      bare = File.join(dir, "bare")
      kept_files.each do |f|
        FileUtils.mkdir_p(File.dirname(File.join(bare, f)))
        FileUtils.cp(File.join(tree, f), File.join(bare, f))
      end
      FileUtils.chmod_R("a-w", bare)
      yield bare
    ensure
      FileUtils.chmod_R("u+w", bare) if File.exist?(bare)
    end

    def test_a_download_checks_out_the_source_and_generates_the_headers_ruby_generates
      in_build_dir do |dir|
        url, sha = origin(dir, extra: { "lib/unused.rb" => "x = 1\n", "ext/unused.h" => "int x;\n" })
        downloaded = RubySource.downloaded(revision: sha, repository: url)

        assert_equal File.expand_path("ruby-#{sha}"), downloaded
        assert_empty kept_files.reject { |f| File.exist?(File.join(downloaded, f)) }
        refute File.exist?(File.join(downloaded, "lib/unused.rb")), "only the paths the headers need are checked out"
        refute File.exist?(File.join(downloaded, "ext/unused.h"))
        RubySource::GENERATED.each_key { |header| assert_equal File.binread(File.join(tree, header)), File.binread(File.join(downloaded, header)), header }
        refute File.exist?(File.join(downloaded, ".git"))
      end
    end

    def test_a_download_that_fails_partway_starts_over
      in_build_dir do |dir|
        url, sha = origin(dir)
        error = assert_raises(RuntimeError) { RubySource.downloaded(revision: sha, repository: "file://#{dir}/nowhere") }
        assert_match(/couldn't get Ruby's source/, error.message)
        refute File.exist?("ruby-#{sha}")

        # A generator killed partway through its header.
        File.write("ruby-#{sha}.partial/id.h", "#ifndef RUBY_ID_H\n")
        assert_equal File.binread(File.join(tree, "id.h")), File.binread(File.join(RubySource.downloaded(revision: sha, repository: url), "id.h"))
      end
    end

    # A user's git config, like a URL rewrite, can't send the fetch
    # somewhere else.
    def test_a_download_ignores_the_user_s_git_config
      in_build_dir do |dir|
        url, sha = origin(dir)
        config = File.join(dir, "gitconfig")
        File.write(config, "[url \"file://#{dir}/nowhere/\"]\n\tinsteadOf = #{url}\n")
        previous = ENV["GIT_CONFIG_GLOBAL"]
        ENV["GIT_CONFIG_GLOBAL"] = config

        assert File.exist?(File.join(RubySource.downloaded(revision: sha, repository: url), "vm_core.h"))
      ensure
        ENV["GIT_CONFIG_GLOBAL"] = previous
      end
    end

    def test_a_download_whose_headers_fail_to_generate_isnt_kept
      in_build_dir do |dir|
        url, sha = origin(dir, kept_files - ["template/id.h.tmpl"])

        capture_subprocess_io { assert_raises(RuntimeError) { RubySource.downloaded(revision: sha, repository: url) } }
        refute File.exist?("ruby-#{sha}")
      end
    end

    def test_a_given_tree_gets_the_headers_it_lacks_without_being_written_to
      in_build_dir do |dir|
        with_bare_tree(dir) do |bare|
          dirs = RubySource.include_dirs(bare)
          assert_equal [bare, File.expand_path("ruby-generated")], dirs
          generated.each { |header| assert_equal File.binread(File.join(tree, header)), File.binread(File.join(dirs.last, header)), header }
          generated.each { |header| refute File.exist?(File.join(bare, header)), header }
        end
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
      err = File.join(dir, "configure.err")
      assert system(env, RbConfig.ruby, File.join(ext, "extconf.rb"), chdir: File.join(dir, "build"), out: File::NULL, err: err)
      @configure_err = File.read(err)
      File.read(File.join(dir, "build/riptide_build.h"))[/RIPTIDE_UNSUPPORTED "(.*)"/, 1]
    end

    def test_the_tracer_builds_against_a_tree_ruby_hasnt_built
      Dir.mktmpdir do |dir|
        with_bare_tree(dir) { |bare| assert_nil configure(dir, bare) }
      end
    end

    # A function the tracer calls that Ruby doesn't export compiles, and the
    # extension even loads, but the process dies on the call.
    def test_the_tracer_stays_off_on_a_ruby_missing_a_function_it_calls
      Dir.mktmpdir do |dir|
        off = configure(dir, tree) { |c| File.write(c, File.read(c) + "void riptide_missing(void);\nvoid riptide_calls_it(void) { riptide_missing(); }\n") }

        assert_equal "the tracer doesn't build against Ruby #{RUBY_VERSION}", off
        assert_match(/riptide's tracer didn't compile:\n.*riptide_missing/m, @configure_err, "the install says what failed")
      end
    end
  end
end
