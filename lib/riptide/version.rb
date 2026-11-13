# frozen_string_literal: true

module Riptide
  VERSION = "0.1.0"

  # The Ruby minors whose VM the tracer is written for. riptide installs on
  # any other and stays off there, until someone checks the new VM.
  TRACED_RUBIES = %w[4.0].freeze
end
