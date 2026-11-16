# frozen_string_literal: true

require "fileutils"
require "net/http"
require "rubygems/package"
require "stringio"
require "zlib"

# The tracer reaches into the VM, so it builds against the internal headers of
# the exact Ruby it runs on. Ruby doesn't install those, so they come from
# Ruby's source at this Ruby's own revision, with the few that Ruby generates
# while it builds generated the same way. RIPTIDE_RUBY_SOURCE points at a
# source tree instead, for a build with no way out to GitHub.
module RubySource
  # What the headers and the generators for the missing ones need.
  KEEP = %r{\A(?:[^/]+\.h|(?:internal|ccan|prism)/.*|(?:tool|template|defs)/.*)\z}
  GENERATED = {
    "id.h" => ->(out) { ["tool/generic_erb.rb", "--output=#{out}", "template/id.h.tmpl"] },
    "prism/ast.h" => ->(out) { ["prism/templates/template.rb", "include/prism/ast.h", out] },
    "prism/diagnostic.h" => ->(out) { ["prism/templates/template.rb", "include/prism/diagnostic.h", out] }
  }.freeze

  module_function

  # The directories to build against. A given tree is only read, so headers
  # it hasn't generated yet go in a directory of their own.
  def include_dirs(given = ENV["RIPTIDE_RUBY_SOURCE"])
    return [downloaded] if given.nil? || given.empty?

    source = File.expand_path(given)
    out = File.expand_path("ruby-generated")
    generate(source, out)
    [source, out]
  end

  # The tree only gets its name once it's complete, so a build that died
  # partway through starts over instead of building against half of it.
  def downloaded
    # A full commit sha pins the exact source this Ruby was built from.
    raise "no full revision for this Ruby: #{RUBY_REVISION}" unless RUBY_REVISION.match?(/\A\h{40}\z/)

    dir = File.expand_path("ruby-#{RUBY_REVISION}")
    return dir if File.directory?(dir)

    partial = "#{dir}.partial"
    FileUtils.rm_rf(partial)
    extract(download("https://github.com/ruby/ruby/archive/#{RUBY_REVISION}.tar.gz"), partial)
    generate(partial, partial)
    File.rename(partial, dir)
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
        raise "Ruby's source archive has a path that leaves it: #{entry.full_name}" if relative.split("/").include?("..")

        path = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, entry.read)
      end
    end
  end

  # Writes the headers +source+ is missing into +out+, with the generators
  # Ruby's own build runs.
  def generate(source, out)
    FileUtils.mkdir_p(out)
    GENERATED.each do |header, command|
      next if File.exist?(File.join(source, header))

      system(RbConfig.ruby, *command.(File.join(out, header)), chdir: source, out: File::NULL, exception: true)
    end
  end
end
