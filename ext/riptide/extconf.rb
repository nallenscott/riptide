# frozen_string_literal: true

require "mkmf"
require "fileutils"
require "net/http"
require "rubygems/package"
require "stringio"
require "zlib"

# The tracer reaches into the VM, so it builds against the internal headers of
# the exact Ruby it runs on. Ruby doesn't install those, so they come from
# Ruby's source at this Ruby's own revision, with the few that Ruby generates
# while it builds generated the same way. RIPTIDE_RUBY_SOURCE points at a
# source tree instead, for a build with no way out to GitHub. Without the
# headers the gem still installs, and riptide stays off.
module RubySource
  # The minors whose VM the tracer is written for. Any other builds without
  # it, so a new Ruby leaves riptide off until someone checks its VM.
  MINORS = %w[4.0].freeze

  # What the headers and the generators for the missing ones need.
  KEEP = %r{\A(?:[^/]+\.h|(?:internal|ccan|prism)/.*|(?:tool|template|defs)/.*)\z}
  GENERATED = {
    "id.h" => ["tool/generic_erb.rb", "--output=id.h", "template/id.h.tmpl"],
    "prism/ast.h" => ["prism/templates/template.rb", "include/prism/ast.h", "prism/ast.h"],
    "prism/diagnostic.h" => ["prism/templates/template.rb", "include/prism/diagnostic.h", "prism/diagnostic.h"]
  }.freeze

  module_function

  def headers
    minor = RUBY_VERSION[/\A\d+\.\d+/]
    raise "riptide's tracer isn't written for Ruby #{minor} yet" unless MINORS.include?(minor)

    given = ENV["RIPTIDE_RUBY_SOURCE"]
    return File.expand_path(given) if given && !given.empty?

    # A full commit sha pins the exact source this Ruby was built from.
    raise "no full revision for this Ruby: #{RUBY_REVISION}" unless RUBY_REVISION.match?(/\A\h{40}\z/)

    dir = File.expand_path("ruby-#{RUBY_REVISION}")
    unless File.exist?(File.join(dir, "vm_core.h"))
      FileUtils.rm_rf(dir)
      extract(download("https://github.com/ruby/ruby/archive/#{RUBY_REVISION}.tar.gz"), dir)
    end
    generate(dir)
    dir
  end

  def download(url, redirects = 5)
    uri = URI(url)
    raise "won't download from #{url}" unless uri.scheme == "https" && %w[github.com codeload.github.com].include?(uri.host)

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 60) { |http| http.get(uri.request_uri) }
    case response
    when Net::HTTPRedirection
      raise "too many redirects from #{url}" if redirects.zero?

      download(response["location"], redirects - 1)
    when Net::HTTPSuccess then response.body
    else raise "#{url} answered #{response.code}"
    end
  end

  def extract(archive, dir)
    Gem::Package::TarReader.new(Zlib::GzipReader.new(StringIO.new(archive))) do |tar|
      tar.each do |entry|
        next unless entry.file?

        relative = entry.full_name.split("/", 2)[1]
        next unless relative&.match?(KEEP)

        path = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, entry.read)
      end
    end
  end

  def generate(dir)
    GENERATED.each do |header, (script, *args)|
      next if File.exist?(File.join(dir, header))

      system(RbConfig.ruby, script, *args, chdir: dir, out: File::NULL, exception: true)
    end
  end
end

off = nil
begin
  raise "riptide only traces CRuby" unless RUBY_ENGINE == "ruby"

  $INCFLAGS << " -I#{RubySource.headers}"
  $CFLAGS << " -Wno-unused-function -Wno-unused-parameter"
  # A struct that moved in a patch release turns riptide off, not the install.
  raise "the tracer doesn't compile against Ruby #{RUBY_VERSION}'s headers" unless try_compile(File.read(File.join(__dir__, "riptide_native.c")).sub(%(#include "riptide_build.h"\n), ""))
rescue StandardError => e
  off = e.message
  warn "riptide will stay off: #{off}"
end

# Why the tracer isn't built, when it isn't.
File.write("riptide_build.h", off ? "#define RIPTIDE_UNSUPPORTED #{off.dump}\n" : "")
create_makefile("riptide/riptide_native")
