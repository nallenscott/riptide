# frozen_string_literal: true

require "optparse"
require "riptide"

module Riptide
  # `riptide fetch` before tests and `riptide publish` after them, outside
  # the test process. Publishing writes to .git, so it runs wherever .git is
  # writable and the remote's credential is available.
  #
  # A PR build passes its number and the branch it merges into. A build of
  # a long-lived branch like main passes --harvest: it reads the runs of the
  # PRs that landed in it, keeps the ones that held, and deletes their
  # units. A release branch also reads main's with --upstream main.
  #
  # Riptide never fails a build: anything that goes wrong is a warning, and
  # the command still exits 0. Only a malformed command line exits 1.
  class CLI
    USAGE = "usage: riptide fetch [identity] | riptide publish --suite NAME [identity] [--log-dir DIR]\n" \
            "identity: --pr NUMBER --target BRANCH, or --branch NAME [--upstream BRANCH] [--harvest]\n" \
            "both take [--remote NAME] [--root DIR]"

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
    end

    def call
      command = @argv.shift
      unless %w[fetch publish].include?(command)
        @err.puts USAGE
        return 1
      end

      options = parse(command)
      run(command, options)
      0
    rescue OptionParser::ParseError => e
      @err.puts "riptide: #{e.message}"
      @err.puts USAGE
      1
    rescue StandardError => e
      @err.puts "[riptide] #{command} didn't finish, so this build reads or saves less: #{e.class}: #{e.message}"
      0
    end

    private

    def run(command, options)
      build = build_of(options)
      return Store.fetch(root: options[:root], build: build, remote: options[:remote]) if command == "fetch"

      suite = options[:suite]
      log_dir = File.expand_path(options[:log_dir] || "tmp/riptide/#{suite}", options[:root])
      store = Store.new(root: options[:root], suite: suite, log_dir: log_dir, remote: options[:remote])
      published = store.publish(build: build)
      @out.puts "[riptide] published #{published.ref}: #{published.runs} new runs, #{published.harvested} harvested"
      published.deleted.each { |ref| @out.puts "[riptide] deleted #{ref}" }
    end

    def build_of(options)
      return Store::Build.pr(options[:pr], target: options[:target]) if options[:pr]

      Store::Build.branch(options[:branch], upstream: options[:upstream], harvest: options[:harvest])
    end

    def parse(command)
      options = { root: Dir.pwd, remote: "origin", harvest: false }
      OptionParser.new do |parser|
        parser.banner = USAGE
        parser.on("--suite NAME") { |value| options[:suite] = value }
        parser.on("--pr NUMBER") { |value| options[:pr] = value }
        parser.on("--target BRANCH") { |value| options[:target] = value }
        parser.on("--branch NAME") { |value| options[:branch] = value }
        parser.on("--upstream BRANCH") { |value| options[:upstream] = value }
        parser.on("--harvest") { options[:harvest] = true }
        parser.on("--remote NAME") { |value| options[:remote] = value }
        parser.on("--log-dir DIR") { |value| options[:log_dir] = value }
        parser.on("--root DIR") { |value| options[:root] = File.expand_path(value) }
      end.parse!(@argv)
      raise OptionParser::MissingArgument, "--suite" if command == "publish" && !options[:suite]
      raise OptionParser::MissingArgument, "--pr or --branch" unless options[:pr] || options[:branch]
      raise OptionParser::InvalidOption, "--pr and --branch" if options[:pr] && options[:branch]
      raise OptionParser::MissingArgument, "--target" if options[:pr] && !options[:target]

      options
    end
  end
end
