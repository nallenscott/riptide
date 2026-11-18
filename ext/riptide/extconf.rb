# frozen_string_literal: true

require "mkmf"
require_relative "ruby_source"
require_relative "../../lib/riptide/version"

# Without the headers the tracer needs, or on a Ruby that doesn't have
# everything it calls, the gem still installs and riptide stays off.
#
# RIPTIDE_TRACER=on builds the tracer on a Ruby it isn't written for yet, to
# see whether it works there, and RIPTIDE_TRACER=off builds without it.

# The errors from mkmf's last check, which only its log keeps. The compiler's
# output sits between the command and the program it checked, warnings and
# all, so this keeps the lines that say what failed.
def compiler_errors
  lines = File.exist?("mkmf.log") ? File.readlines("mkmf.log") : []
  checked = lines.rindex("checked program was:\n") or return []
  command = lines[0...checked].rindex { |line| line.rstrip.end_with?('"') } || -1
  lines[(command + 1)...checked].grep(/error|undefined|Undefined|referenced from|\A\s+"/).first(20)
end

off = nil
begin
  raise "riptide only traces CRuby" unless RUBY_ENGINE == "ruby"
  raise "RIPTIDE_TRACER is off" if ENV["RIPTIDE_TRACER"] == "off"

  minor = RUBY_VERSION[/\A\d+\.\d+/]
  raise "riptide's tracer isn't written for Ruby #{minor} yet" unless ENV["RIPTIDE_TRACER"] == "on" || Riptide::TRACED_RUBIES.include?(minor)

  RubySource.include_dirs.each { |dir| $INCFLAGS << " -I#{dir}" }
  $CFLAGS << " -Wno-unused-function -Wno-unused-parameter"
  # A struct that moved in a patch release, or a function this Ruby doesn't
  # export, turns riptide off, not the install. Only linking catches the
  # second, since the extension loads fine and dies when the tracer calls it.
  source = File.read(File.join(__dir__, "riptide_native.c")).sub(%(#include "riptide_build.h"\n), "")
  unless try_link(source + MAIN_DOES_NOTHING)
    errors = compiler_errors
    warn "riptide's tracer didn't compile:\n#{errors.join}" if errors.any?
    raise "the tracer doesn't build against Ruby #{RUBY_VERSION}"
  end
rescue StandardError => e
  off = e.message
  warn "riptide will stay off: #{off}"
end

# Why the tracer isn't built, when it isn't.
File.write("riptide_build.h", off ? "#define RIPTIDE_UNSUPPORTED #{off.dump}\n" : "")
create_makefile("riptide/riptide_native")
