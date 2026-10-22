# frozen_string_literal: true

require "optparse"
require "riptide"

module Riptide
  # `riptide fetch` before tests and `riptide publish` after them, outside
  # the test process. Publishing writes to .git, so it runs wherever .git is
  # writable and the remote's credential is available.
  class CLI
    USAGE = "usage: riptide fetch|publish --suite NAME [--remote NAME] [--log-dir DIR] [--root DIR] [--prune]"

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
    end

    def call
      command = @argv.shift
      options = parse
      store = Store.new(root: options[:root], suite: options[:suite], log_dir: options[:log_dir], remote: options[:remote])

      case command
      when "fetch"
        store.fetch
        0
      when "publish"
        commit = store.publish(prune: options[:prune])
        @out.puts "[riptide] published #{store.ref} at #{commit[0, 12]}"
        0
      else
        @err.puts USAGE
        1
      end
    rescue OptionParser::ParseError, Error => e
      @err.puts "riptide: #{e.message}"
      1
    end

    private

    def parse
      options = { root: Dir.pwd, remote: "origin", prune: false }
      OptionParser.new do |parser|
        parser.banner = USAGE
        parser.on("--suite NAME") { |value| options[:suite] = value }
        parser.on("--remote NAME") { |value| options[:remote] = value }
        parser.on("--log-dir DIR") { |value| options[:log_dir] = value }
        parser.on("--root DIR") { |value| options[:root] = File.expand_path(value) }
        parser.on("--prune") { options[:prune] = true }
      end.parse!(@argv)
      raise OptionParser::MissingArgument, "--suite" unless options[:suite]

      options[:log_dir] = File.expand_path(options[:log_dir] || "tmp/riptide/#{options[:suite]}", options[:root])
      options
    end
  end
end
