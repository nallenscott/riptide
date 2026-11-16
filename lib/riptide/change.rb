# frozen_string_literal: true

require "set"

module Riptide
  # What changed between two versions of one file, in the terms a recorded
  # run depends on: methods and blocks by their key in the old version,
  # constants, classes and tables by name. +suite+ means every test, like a
  # change to top-level code.
  class Change
    attr_reader :methods, :blocks, :constants, :tables

    # { class name => why it changed }: :declaration, :override for a new
    # method that could take over a call, or :code for a method that ran
    # while the class loaded.
    attr_reader :causes

    def initialize
      @methods = Set.new
      @blocks = Set.new
      @constants = Set.new
      @causes = {}
      @tables = Set.new
      @whole = false
      @suite = false
    end

    def owners = @causes.keys

    def owned(names, cause) = names.each { |name| @causes[name] ||= cause }

    def whole! = @whole = true
    def suite! = @suite = true
    def whole? = @whole || @suite
    def suite? = @suite

    def empty?
      !whole? && [@methods, @blocks, @constants, owners, @tables].all?(&:empty?)
    end
  end
end
