# frozen_string_literal: true

module Riptide
  class Store
    # The rest of a harvesting build's fetch, once every stamp is local:
    # deletes units nobody wrote for EXPIRY, works out which PRs landed in
    # HEAD, and fetches their runs. Every other PR's stamp is dropped
    # locally, along with every other branch's, so their open failures
    # don't count here.
    class Harvest
      def initialize(git, build, remote)
        @git = git
        @build = build
        @remote = remote
        @own = [build.key, build.upstream_key].compact
      end

      def run
        stamps = @git.output("for-each-ref", "--format=%(refname) %(objectname) %(taggerdate:unix)", STAMPS).lines.map(&:split)
        now = Time.now.to_i
        aged, live = stamps.partition { |ref, _, at| !@own.include?(key_of(ref)) && now - at.to_i > EXPIRY }
        age(aged)
        prs = live.select { |ref, _, _| key_of(ref).start_with?("prs/") }
        targeting = prs.select { |_, tag, _| @git.read("#{tag}:landing/target") == @build.branch }
        landed = landed_of(targeting)
        keep = (landed || targeting).map(&:first)
        @git.delete_refs(stamps.map(&:first).reject { |ref| @own.include?(key_of(ref)) || keep.include?(ref) })
        fetch_runs(landed) if landed&.any?
      end

      private

      def key_of(stamp) = stamp.delete_prefix(STAMPS).split("/", 2).last

      def head_entries = @head_entries ||= @git.entries("HEAD")

      # The PRs whose changes HEAD already has. If the check itself fails,
      # nil: nothing is harvested, and every targeting PR's failures count.
      def landed_of(targeting)
        verdicts = {}
        targeting.select { |_, tag, _| verdicts[@git.resolve("#{tag}:landing")] ||= landed?(tag) }
      rescue StandardError => e
        warn "[riptide] couldn't tell which PRs landed, so none are harvested: #{e.message}"
        nil
      end

      # Replays the PR's changed paths onto HEAD's, from the merge base. If
      # that's clean and changes nothing, HEAD has the PR's changes however
      # it merged. Only the PR's paths take part, so every other path is
      # the same on all three sides.
      def landed?(tag)
        base = @git.entries(@git.resolve("#{tag}:landing/base"))
        tested = @git.entries(@git.resolve("#{tag}:landing/tested"))
        paths = base.keys | tested.keys
        head = @git.write_tree(head_entries.slice(*paths))
        @git.merge_tree(@git.write_tree(base), head, @git.write_tree(tested)) == head
      end

      # Deletes idle units in one atomic push. Each stamp is leased, which
      # covers its runs too, since every write rewrites the stamp. A unit
      # revived meanwhile fails the push, so it's retried once without.
      def age(aged)
        units = aged.map { |stamp, tag, _| [stamp, tag] }
        until units.empty?
          leases = units.map { |stamp, tag| "--force-with-lease=#{stamp}:#{tag}" }
          deletes = units.flat_map { |stamp, _| [":#{stamp}", ":#{stamp.sub(STAMPS, RUNS)}"] }
          out, status = @git.run("push", "--porcelain", "--atomic", *leases, @remote, *deletes, allow: [0, 1])
          break if status.zero?

          moved = out.lines.grep(/stale info/).map { |line| line.split("\t")[1].to_s.split(":").last }
          break if moved.empty?

          units.reject! { |stamp, _| moved.include?(stamp) }
        end
      rescue Error => e
        warn "[riptide] couldn't age out idle units: #{e.message}"
      end

      def fetch_runs(landed)
        specs = landed.map { |stamp, _, _| runs = stamp.sub(STAMPS, RUNS); "+#{runs}:#{runs}" }
        @git.run("fetch", "--quiet", "--atomic", "--no-tags", "--refmap=", "--no-write-fetch-head", @remote, *specs)
      rescue Error => e
        warn "[riptide] couldn't fetch the runs of PRs that landed, so none are harvested: #{e.message}"
      end
    end
  end
end
