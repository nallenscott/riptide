# frozen_string_literal: true

require "fileutils"
require "open3"

# The tracer reaches into the VM, so it builds against the internal headers of
# the exact Ruby it runs on. Ruby doesn't install those, so they come from
# Ruby's source at this Ruby's own revision, with the few that Ruby generates
# while it builds generated the same way. RIPTIDE_RUBY_SOURCE points at a
# source tree instead, for a build with no way out to GitHub.
module RubySource
  REPOSITORY = "https://github.com/ruby/ruby.git"
  # What the headers and the generators for the missing ones need.
  PATHS = %w[/*.h /internal/ /ccan/ /prism/ /tool/ /template/ /defs/].freeze
  GENERATED = {
    "id.h" => ->(out) { ["tool/generic_erb.rb", "--output=#{out}", "template/id.h.tmpl"] },
    "prism/ast.h" => ->(out) { ["prism/templates/template.rb", "include/prism/ast.h", out] },
    "prism/diagnostic.h" => ->(out) { ["prism/templates/template.rb", "include/prism/diagnostic.h", out] }
  }.freeze
  # Only what's asked for here decides how git behaves, so a user's config
  # can't change the fetch. A fetch that stalls gives up after a minute.
  GIT_ENV = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0" }.freeze
  GIT_CONFIG = %w[-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60].freeze

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
  def downloaded(revision: RUBY_REVISION, repository: REPOSITORY)
    # A full commit sha pins the exact source this Ruby was built from.
    raise "no full revision for this Ruby: #{revision}" unless revision.match?(/\A\h{40}\z/)

    dir = File.expand_path("ruby-#{revision}")
    return dir if File.directory?(dir)

    partial = "#{dir}.partial"
    FileUtils.rm_rf(partial)
    fetch(repository, revision, partial)
    generate(partial, partial)
    File.rename(partial, dir)
    dir
  end

  # Checks out only PATHS at +revision+, fetching just that commit and the
  # files it needs.
  def fetch(repository, revision, dir)
    git("init", "-q", dir)
    git("-C", dir, "sparse-checkout", "set", "--no-cone", *PATHS)
    git("-C", dir, "fetch", "-q", "--depth", "1", "--filter=blob:none", repository, revision)
    git("-C", dir, "checkout", "-q", "FETCH_HEAD")
    FileUtils.rm_rf(File.join(dir, ".git"))
  end

  def git(*args)
    output, status = Open3.capture2e(GIT_ENV, "git", *GIT_CONFIG, *args)
    raise "couldn't get Ruby's source: #{output.lines.last&.strip}" unless status.success?
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
