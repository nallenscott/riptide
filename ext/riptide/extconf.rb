# frozen_string_literal: true

require "mkmf"

# The tracer reaches into the VM, so it builds against the internal headers
# of the exact Ruby it runs on. Without them it builds to report that.
headers = File.join(__dir__, "ruby", RUBY_VERSION)
revision = File.read(File.join(headers, "REVISION")).strip if File.exist?(File.join(headers, "REVISION"))
if RUBY_ENGINE == "ruby" && revision && RUBY_REVISION.start_with?(revision)
  $INCFLAGS << " -I#{headers}"
  $CFLAGS << " -Wno-unused-function -Wno-unused-parameter"
else
  $defs << "-DRIPTIDE_UNSUPPORTED"
end

create_makefile("riptide/riptide_native")
