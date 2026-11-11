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
  # What the headers and the generators for the missing ones need.
  KEEP = %r{\A(?:[^/]+\.h|(?:internal|ccan|prism)/.*|(?:tool|template|defs)/.*)\z}
  GENERATED = {
    "id.h" => ["tool/generic_erb.rb", "--output=id.h", "template/id.h.tmpl"],
    "prism/ast.h" => ["prism/templates/template.rb", "include/prism/ast.h", "prism/ast.h"],
    "prism/diagnostic.h" => ["prism/templates/template.rb", "include/prism/diagnostic.h", "prism/diagnostic.h"]
  }.freeze

  module_function

  def headers
    given = ENV["RIPTIDE_RUBY_SOURCE"]
    return File.expand_path(given) if given && !given.empty?

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

begin
  raise "riptide only traces CRuby" unless RUBY_ENGINE == "ruby"

  $INCFLAGS << " -I#{RubySource.headers}"
  $CFLAGS << " -Wno-unused-function -Wno-unused-parameter"
rescue StandardError => e
  warn "riptide: can't get Ruby #{RUBY_VERSION}'s internal headers, so it'll stay off: #{e.message}"
  $defs << "-DRIPTIDE_UNSUPPORTED"
end

create_makefile("riptide/riptide_native")
