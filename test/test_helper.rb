# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "riptide"

require "minitest/autorun"
require "tmpdir"
require "fileutils"

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
