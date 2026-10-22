# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "riptide"
require "minitest/autorun"
require "tmpdir"
require "fileutils"

# The tracer is process-wide, so the suite installs it once, rooted where
# TracedFixture writes the source it loads. It's a git repository because
# riptide only records files git knows about.
TRACE_ROOT = File.realpath(Dir.mktmpdir("riptide-trace"))
system("git", "init", "-q", TRACE_ROOT, exception: true)
Riptide::Tracer.install(TRACE_ROOT)

module GitFixture
  def in_repo
    Dir.mktmpdir do |root|
      Dir.chdir(root) do
        system("git", "init", "-q", ".", exception: true)
        system("git", "config", "user.email", "test@test.com", exception: true)
        system("git", "config", "user.name", "Test", exception: true)
        yield root
      end
    end
  end

  def write_and_commit(root, relative_path, content, message:)
    full_path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
    commit(root, message)
  end

  def commit(root, message)
    system("git", "-C", root, "add", "-A", exception: true)
    system("git", "-C", root, "commit", "-q", "-m", message, exception: true)
  end
end

module TracedFixture
  # Writes +source+ under the tracer's root and loads it, so its lines are
  # in scope. Returns the path relative to that root.
  def load_traced(relative, source)
    full = File.join(TRACE_ROOT, relative)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, source)
    load full
    relative
  end

  # The lines a block ran, as a closed window.
  def traced
    Riptide::Tracer.open_window
    begin
      yield
    ensure
      lines = Riptide::Tracer.close_window.lines
    end
    lines
  end
end
