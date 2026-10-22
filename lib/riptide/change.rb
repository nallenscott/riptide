# frozen_string_literal: true

require "set"

module Riptide
  # What changed between two versions of one file, in the terms a recorded
  # run depends on: methods and blocks by their key in the old version,
  # constants, classes and tables by name. +suite+ means every test, like a
  # change to top-level code.
  class Change
    attr_reader :methods, :blocks, :constants, :owners, :tables

    def initialize
      @methods = Set.new
      @blocks = Set.new
      @constants = Set.new
      @owners = Set.new
      @tables = Set.new
      @whole = false
      @suite = false
    end

    def whole! = @whole = true
    def suite! = @suite = true
    def whole? = @whole || @suite
    def suite? = @suite

    def empty?
      !whole? && [@methods, @blocks, @constants, @owners, @tables].all?(&:empty?)
    end
  end
end
