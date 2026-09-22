# frozen_string_literal: true

require "riptide/riptide_native"
require "set"

module Riptide
  # Records which lines of project source execute while a block of code
  # runs: initialize(root:), #start, #stop, #capture -> { relative_path
  # => Set<Integer> } for the lines touched inside the window. Backed by
  # a native event hook (rb_add_event_hook2 + RUBY_EVENT_LINE with
  # RUBY_EVENT_HOOK_FLAG_RAW_ARG), not TracePoint -- see
  # ext/riptide/riptide_native.c for the collection mechanism itself;
  # #start/#stop/the scope classification live there.
  class Collector
    def initialize(root: Dir.pwd)
      _native_initialize(File.expand_path(root))
    end

    def capture
      start
      yield
      stop
    end
  end
end
