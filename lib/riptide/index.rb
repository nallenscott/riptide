# frozen_string_literal: true

require "digest"
require "json"
require "set"

module Riptide
  # One unit's passing runs, stored the way selection reads them: from each
  # file version to the runs and shared sets that used each part of it.
  # Every directory is split into 256 shards, so a publish rewrites only the
  # shards whose contents moved.
  #
  #   meta                  the next free id
  #   tests/<ab>            per test, its file and its kept runs as [id, at]
  #   files/<ab>            per file version, per path, its postings
  #   listings/<ab>         per glob or absent name, its postings by value
  #   members/<ab>          per shared set, the runs that point at it
  #   names/<ab>            per constant name, the runs and sets that read it
  #   manifest/<ab>         per path, its recorded versions
  #   loads/<ab>            per file version, which classes each line ran for
  #   blobs/<ab>/<sha>      pins that keep recorded versions fetchable
  #
  # A posting list is sorted ids stored as gaps. Runs and sets share one
  # id space, and an id stays the same for as long as the unit keeps it.
  #
  # Failures aren't runs. They're open marks, kept in the unit's stamp and
  # handed in as +marks+: { test => Set of mark ids }.
  class Index
    FORMAT = 2
    FACETS = %w[methods blocks owners tables].freeze

    Run = Struct.new(:id, :test, :at, keyword_init: true)

    attr_reader :ref, :marks

    # +blobs+ returns a tree path's parsed content, or nil. +paths+ lists
    # every path the tree holds.
    def initialize(blobs:, paths:, ref: nil, marks: {})
      @blobs = blobs
      @paths = paths
      @ref = ref
      @marks = marks
      @cache = {}
      @postings = {}
      @members = {}
      @readers = {}
    end

    # An index over content already in memory, like the logs.
    def self.of(content, marks: {}) = new(blobs: content.method(:[]), paths: content.keys, marks: marks)

    # An index with no runs, for a unit whose runs can't be read here.
    def self.empty(ref: nil, marks: {}) = new(blobs: ->(_) {}, paths: [], ref: ref, marks: marks)

    def self.shard(key) = Digest::SHA1.hexdigest(key)[0, 2]
    def self.test_key(test) = JSON.generate(test)
    def self.id_shard(id) = format("%02x", id % 256)

    def self.gaps(ids)
      previous = 0
      ids.sort.map { |id| (id - previous).tap { previous = id } }
    end

    def self.ids(gaps)
      sum = 0
      gaps.map { |gap| sum += gap }
    end

    # { test => [Run, ...] }, newest first.
    def runs
      @runs ||= @paths.grep(%r{\Atests/}).each_with_object({}) do |path, result|
        blob(path).each do |klass, name, _file, test_runs|
          result[[klass, name]] = test_runs.map { |id, at| Run.new(id: id, test: [klass, name], at: at) }
        end
      end
    end

    def run_ids
      @run_ids ||= runs.values.flatten.to_set(&:id)
    end

    def manifest
      @manifest ||= @paths.grep(%r{\Amanifest/}).each_with_object({}) { |path, all| all.merge!(blob(path)) }
    end

    # { "all" => ids, "whole" => ids, facet => { name => ids } } for the
    # holders that recorded +path+ at +version+.
    def postings(path, version)
      @postings[[path, version]] ||= begin
        raw = Env.pseudo?(path) ? blob("listings/#{Index.shard(path)}")&.dig(path, version) : blob("files/#{version[0, 2]}")&.dig(version, path)
        raise Error, "#{@ref || "the logs"} has no postings for #{path} at #{version}" unless raw

        decode_postings(raw)
      end
    end

    def members(set_id)
      @members[set_id] ||= Index.ids(blob("members/#{Index.id_shard(set_id)}")&.fetch(set_id.to_s, nil) || [])
    end

    # The runs and sets that read the constant +name+.
    def readers(name)
      @readers[name] ||= Index.ids(blob("names/#{Index.shard(name)}")&.fetch(name, nil) || [])
    end

    # The runs among +holders+, plus the runs that point at the sets among
    # them.
    def runs_for(holders)
      holders.each_with_object(Set.new) do |id, result|
        run_ids.include?(id) ? result << id : result.merge(members(id))
      end
    end

    def load_facts(sha) = blob("loads/#{sha[0, 2]}")&.fetch(sha, nil)

    def pins = @paths.grep(%r{\Ablobs/}).to_set { |path| path.split("/").last }

    def model = Model.decode(self)

    # Yields each blob under +prefix+ with its content.
    def each_blob(prefix)
      @paths.each { |path| yield path, blob(path) if path.start_with?(prefix) }
    end

    def blob(path)
      return @cache[path] if @cache.key?(path)

      @cache[path] = @blobs.call(path)
    end

    private

    def decode_postings(raw)
      raw.to_h do |key, value|
        [key, value.is_a?(Hash) ? value.transform_values { |gaps| Index.ids(gaps) } : Index.ids(value)]
      end
    end

    # The forward form of an index, for publishing to change: runs and sets
    # by id, each with the files it recorded and the constants it read.
    class Model
      Holder = Struct.new(:test, :at, :sets, :files, :constants, keyword_init: true) do
        def run? = !test.nil?

        # What the run or set depended on directly. Two runs with the same
        # key and the same sets get selected the same way.
        def key = @key ||= Digest::SHA1.hexdigest(JSON.generate([files, constants.sort]))
      end

      attr_reader :holders, :loads, :pins, :test_files

      # Log facets carry the constants a file's code read. The model keeps
      # them per holder, since a changed constant matches a read anywhere.
      def self.split(inputs)
        constants = inputs.values.flat_map { |facets| facets["constants"] || [] }
        [inputs.transform_values { |facets| facets.except("constants") }, constants]
      end

      def initialize(holders: {}, loads: {}, pins: Set.new, next_id: 0, test_files: {})
        @holders = holders
        @loads = loads
        @pins = pins
        @next_id = next_id
        @test_files = test_files
        @set_ids = {}
        @tests = Hash.new { |h, k| h[k] = [] }
        holders.each { |id, holder| holder.run? ? @tests[holder.test] << id : @set_ids[holder.key] = id }
      end

      def set(id) = @holders.fetch(id)
      def runs = @tests.transform_values { |ids| ids.map { |id| [id, @holders[id]] } }

      # The id of a set with these files, adding it when it's new.
      def add_set(files, constants)
        holder = Holder.new(files: canonical(files), constants: constants.to_set)
        @set_ids[holder.key] ||= add(holder)
      end

      # Adds a passing run unless the test's newest run has the same
      # dependencies, which selects nothing differently. +file+ is where the
      # test is defined. Returns the run's id, or nil when it was dropped.
      def add_run(test:, at:, sets:, files:, constants:, file: nil)
        @test_files[test] = file if file
        holder = Holder.new(test: test, at: at, sets: sets.uniq.sort, files: canonical(files), constants: constants.to_set)
        newest = @tests[test].map { |id| @holders[id] }.max_by(&:at)
        return nil if newest && same_dependencies?(newest, holder)

        add(holder).tap { |id| @tests[test] << id }
      end

      def merge_loads(sha, lines)
        known = @loads[sha] ||= {}
        lines.each do |line, fact|
          had = known[line.to_s]
          known[line.to_s] = had ? { "owners" => (had["owners"] | fact["owners"]).sort, "called" => had["called"] || fact["called"] } : fact
        end
      end

      # Keeps each test's newest +count+ runs, and only the tests in +tests+
      # when given. Then drops the sets and load facts nothing refers to.
      def retain(count, tests: nil)
        keep = tests&.to_set
        @tests.each do |test, ids|
          kept = keep && !keep.include?(test) ? [] : ids.sort_by { |id| -@holders[id].at }.first(count)
          (ids - kept).each { |id| @holders.delete(id) }
          ids.replace(kept)
        end
        @tests.reject! { |_, ids| ids.empty? }
        @test_files.select! { |test, _| @tests.key?(test) }
        used = @tests.values.flatten.flat_map { |id| @holders[id].sets }.to_set
        @holders.select! { |id, holder| holder.run? || used.include?(id) }
        @set_ids.select! { |_, id| @holders.key?(id) }
        versions = self.versions
        @loads.select! { |sha, _| versions.include?(sha) }
      end

      # Every file version a run or set recorded.
      def versions
        @holders.values.flat_map { |holder| holder.files.filter_map { |path, facets| facets["sha"] unless Env.pseudo?(path) } }.to_set
      end

      # The tree's content as { path => JSON-ready value }, pins aside.
      def encode
        postings = Hash.new { |h, k| h[k] = {} }
        names = Hash.new { |h, k| h[k] = [] }
        members = Hash.new { |h, k| h[k] = [] }
        manifest = Hash.new { |h, k| h[k] = Set.new }

        @holders.each do |id, holder|
          holder.files.each do |path, facets|
            manifest[path] << facets["sha"]
            posting = postings[[path, facets["sha"]]]
            (posting["all"] ||= []) << id
            (posting["whole"] ||= []) << id if facets["whole"]
            FACETS.each { |facet| facets[facet]&.each { |name| ((posting[facet] ||= {})[name.to_s] ||= []) << id } }
          end
          holder.constants.each { |name| names[name] << id }
          holder.sets&.each { |set_id| members[set_id] << id }
        end

        content = {}
        postings.each do |(path, version), posting|
          if Env.pseudo?(path)
            ((content["listings/#{Index.shard(path)}"] ||= {})[path] ||= {})[version] = encode_posting(posting)
          else
            ((content["files/#{version[0, 2]}"] ||= {})[version] ||= {})[path] = encode_posting(posting)
          end
        end
        @tests.each do |test, ids|
          runs = ids.map { |id| [id, @holders[id].at] }.sort_by { |id, at| [-at, id] }
          (content["tests/#{Index.shard(Index.test_key(test))}"] ||= []) << [*test, @test_files[test], runs]
        end
        members.each { |id, runs| (content["members/#{Index.id_shard(id)}"] ||= {})[id.to_s] = Index.gaps(runs) }
        names.each { |name, ids| (content["names/#{Index.shard(name)}"] ||= {})[name] = Index.gaps(ids) }
        @loads.each { |sha, lines| (content["loads/#{sha[0, 2]}"] ||= {})[sha] = lines.sort_by { |line, _| line.to_i }.to_h }
        manifest.each { |path, versions| (content["manifest/#{Index.shard(path)}"] ||= {})[path] = versions.sort }
        content.transform_values! { |value| value.is_a?(Array) ? value.sort_by { |entry| entry.first(2) } : deep_sort(value) }
        content["meta"] = { "next" => @next_id }
        content
      end

      def self.decode(index)
        holders = Hash.new { |h, id| h[id] = Holder.new(files: {}, constants: Set.new) }
        test_files = {}
        index.each_blob("tests/") do |_, entries|
          entries.each do |klass, name, file, test_runs|
            test_files[[klass, name]] = file if file
            test_runs.each do |id, at|
              holder = holders[id]
              holder.test = [klass, name]
              holder.at = at
              holder.sets = []
            end
          end
        end
        index.each_blob("members/") do |_, sets|
          sets.each do |id, runs|
            # A set with no files still belongs to its runs.
            holders[id.to_i]
            Index.ids(runs).each { |run| holders[run].sets << id.to_i }
          end
        end
        index.each_blob("names/") do |_, names|
          names.each { |name, ids| Index.ids(ids).each { |id| holders[id].constants << name } }
        end
        index.each_blob("files/") do |_, by_version|
          by_version.each { |version, by_path| by_path.each { |file, posting| add_postings(holders, file, version, posting) } }
        end
        index.each_blob("listings/") do |_, by_path|
          by_path.each { |file, values| values.each { |value, posting| add_postings(holders, file, value, posting) } }
        end
        loads = {}
        index.each_blob("loads/") { |_, by_sha| loads.merge!(by_sha) }
        holders.default_proc = nil
        holders.each_value do |holder|
          holder.sets&.sort!
          holder.files = holder.files.sort.to_h { |path, facets| [path, facets.sort.to_h] }
        end
        new(holders: holders, loads: loads, pins: index.pins, next_id: index.blob("meta")&.fetch("next") || 0, test_files: test_files)
      end

      def self.add_postings(holders, path, version, posting)
        all = Index.ids(posting["all"])
        all.each { |id| holders[id].files[path] = { "sha" => version } }
        Index.ids(posting["whole"] || []).each { |id| holders[id].files[path]["whole"] = true }
        FACETS.each do |facet|
          posting[facet]&.each do |name, ids|
            value = facet == "blocks" ? Integer(name) : name
            Index.ids(ids).each { |id| (holders[id].files[path][facet] ||= []) << value }
          end
          all.each { |id| holders[id].files[path][facet]&.sort! }
        end
      end

      private

      def add(holder)
        id = @next_id
        @next_id += 1
        @holders[id] = holder
        id
      end

      def same_dependencies?(one, other)
        one.key == other.key && one.sets.map { |id| set(id).key }.sort == other.sets.map { |id| set(id).key }.sort
      end

      # Facet values deduplicated and sorted, with constants held apart.
      def canonical(files)
        files.sort.to_h do |path, facets|
          [path, facets.except("constants").sort.to_h { |facet, value| [facet, value.is_a?(Array) ? value.uniq.sort : value] }]
        end
      end

      def encode_posting(posting)
        posting.to_h { |key, value| [key, value.is_a?(Hash) ? value.transform_values { |ids| Index.gaps(ids) } : Index.gaps(value)] }
      end

      def deep_sort(value) = value.is_a?(Hash) ? value.sort.to_h { |key, inner| [key, deep_sort(inner)] } : value
    end
  end
end
