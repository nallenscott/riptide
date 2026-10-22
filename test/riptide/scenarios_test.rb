# frozen_string_literal: true

require "test_helper"

module Riptide
  # Whole recordings against real edits: load the files, record one test,
  # edit, and check that riptide selects the test exactly when the edit
  # changes what it does. Each runs in a fork, so its classes never reach
  # this process.
  class ScenariosTest < Minitest::Test
    Outcome = Struct.new(:before, :after, :reasons) do
      def changed? = before != after
    end

    FakeTest = Struct.new(:name) do
      def class = Struct.new(:name).new("ScenarioTest")
    end

    FakeResult = Struct.new(:passed) do
      def skipped? = false
      def passed? = passed
    end

    def write(path, content)
      full = File.join(TRACE_ROOT, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
      full
    end

    def commit_all
      system("git", "-C", TRACE_ROOT, "add", "-A", exception: true)
      system("git", "-C", TRACE_ROOT, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "scenario", "--allow-empty", exception: true)
    end

    # +files+ are written and committed, and the Ruby ones load in order
    # before the test runs, the way an app boots, unless +boot+ names the
    # ones that do. +body+ is the test, either a lambda or test source that
    # lives in a traced test file. +edits+ map paths to new content, nil to
    # delete. Edited Ruby files load again afterwards, or +reload+ names the
    # files a fresh process would load.
    def scenario(**options)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        writer.write(Marshal.dump(run_scenario(**options)))
        exit!(0)
      rescue Exception => e
        writer.write(Marshal.dump(e.full_message))
        exit!(1)
      end
      writer.close
      result = Marshal.load(reader.read)
      Process.wait(pid)
      raise result if result.is_a?(String)

      result
    end

    def run_scenario(files:, edits:, body: nil, test_source: nil, fallback: {}, boot: nil, reload: nil, before_record: nil)
      Collectors.install(TRACE_ROOT)
      Tracer.drain_boot_lines
      Tracer.drain_load_facts
      files.merge(fallback).each { |path, source| write(path, source) }
      commit_all
      (boot || ruby(files.keys)).each { |path| load File.join(TRACE_ROOT, path) }
      if test_source
        load write("test/scenario_test.rb", "SCENARIO_BODY = -> do\n  #{test_source}\nend\n")
        body = Object.const_get(:SCENARIO_BODY)
      end
      layout = Layout.new(root: TRACE_ROOT)
      inputs = Inputs.new(layout: layout, files: Git.new(TRACE_ROOT).files)
      store = Store.new(root: TRACE_ROOT, suite: "scenario", log_dir: Dir.mktmpdir)
      env = Env.capture(inputs: inputs, layout: layout, fallback_patterns: fallback.empty? ? [] : ["config/initializers/**/*"], locale_patterns: [],
                        boot_lines: Tracer.drain_boot_lines, boot_reads: Collectors.boot_reads.to_a, boot_globs: Collectors.boot_globs.to_a)
      store.append_set(Store.set_id(env), env)
      recorder = Recorder.new(store: store, inputs: inputs, env_set: Store.set_id(env))
      recorder.absorb_load_facts
      before_record&.call(self)
      before = nil
      recorder.record(FakeTest.new("test_it")) { before = body.call; FakeResult.new(true) }

      edits.each { |path, source| source ? write(path, source) : File.delete(File.join(TRACE_ROOT, path)) }
      # Reloading redefines methods on purpose.
      $VERBOSE = nil
      (reload || ruby(edits.compact.keys)).each { |path| load File.join(TRACE_ROOT, path) }
      after = begin
        body.call
      rescue StandardError => e
        e.class
      end

      analyzer = Analyzer.new(layout: layout, blobs: store.method(:read_blob), load_facts: store.method(:load_facts))
      listing = Inputs.new(layout: layout, files: Git.new(TRACE_ROOT).files).method(:listing)
      decision = Selector.new(store: store, analyzer: analyzer, root: TRACE_ROOT, tests: [%w[ScenarioTest test_it]], listing: listing).select
      Outcome.new(before, after, decision.selected.map { |entry| entry[:reason] })
    end

    def ruby(paths) = paths.select { |path| path.end_with?(".rb") }

    def assert_skipped(outcome)
      assert_empty outcome.reasons
    end

    def assert_selected(outcome)
      assert outcome.changed?, "the edit was supposed to change the outcome, #{outcome.before.inspect} both times"
      refute_empty outcome.reasons, "the outcome went from #{outcome.before.inspect} to #{outcome.after.inspect} and the test was skipped"
    end

    # Lines no event fires for: a guard clause added at the top, a second
    # line of arguments, `else`, `rescue`, `when`, a chained call.

    GUARD = "class Guard\n  def price(n)\n    total = n * 2\n    total + 1\n  end\nend\n"

    def test_a_guard_clause_added_to_a_method
      assert_selected scenario(files: { "app/guard.rb" => GUARD }, body: -> { Guard.new.price(3) },
                               edits: { "app/guard.rb" => GUARD.sub("  def price(n)\n", "  def price(n)\n    return 0 if n > 1\n") })
    end

    def test_a_multi_line_call_argument
      call = "class Call\n  def run\n    compute(1,\n            2)\n  end\n\n  def compute(a, b) = a + b\nend\n"
      assert_selected scenario(files: { "app/call.rb" => call }, body: -> { Call.new.run }, edits: { "app/call.rb" => call.sub("            2)", "            5)") })
    end

    def test_a_multi_line_hash_value
      conf = "class Conf\n  def settings\n    {\n      retries: 3,\n      timeout: 10,\n    }\n  end\nend\n"
      assert_selected scenario(files: { "app/conf.rb" => conf }, body: -> { Conf.new.settings }, edits: { "app/conf.rb" => conf.sub("timeout: 10", "timeout: 99") })
    end

    def test_an_else_split_into_elsif
      branch = "class Branch\n  def kind(x)\n    if x > 10\n      :big\n    else\n      :small\n    end\n  end\nend\n"
      assert_selected scenario(files: { "app/branch.rb" => branch }, body: -> { Branch.new.kind(1) },
                               edits: { "app/branch.rb" => branch.sub("    else\n", "    elsif x > 0\n      :positive\n    else\n") })
    end

    def test_a_rescued_class
      res = "class Res\n  def go\n    raise ArgumentError\n  rescue ArgumentError\n    :rescued\n  end\nend\n"
      body = -> { Res.new.go rescue $!.class }
      assert_selected scenario(files: { "app/res.rb" => res }, body: body, edits: { "app/res.rb" => res.sub("rescue ArgumentError", "rescue TypeError") })
    end

    def test_a_chained_call_on_its_own_line
      chain = "class Chain\n  def run\n    [3, 1, 2]\n      .sort\n      .first\n  end\nend\n"
      assert_selected scenario(files: { "app/chain.rb" => chain }, body: -> { Chain.new.run }, edits: { "app/chain.rb" => chain.sub(".first", ".last") })
    end

    def test_a_when_clause
      switch = "class Sw\n  def kind(x)\n    case x\n    when 1 then :one\n    when 2, 3\n      :few\n    end\n  end\nend\n"
      assert_selected scenario(files: { "app/sw.rb" => switch }, body: -> { Sw.new.kind(3) }, edits: { "app/sw.rb" => switch.sub("when 2, 3", "when 2") })
    end

    def test_a_multi_line_keyword_argument
      kw = "class Kw\n  def run\n    build(\n      name: \"a\",\n      size: 1\n    )\n  end\n\n  def build(name:, size:) = [name, size]\nend\n"
      assert_selected scenario(files: { "app/kw.rb" => kw }, body: -> { Kw.new.run }, edits: { "app/kw.rb" => kw.sub("size: 1", "size: 2") })
    end

    def test_a_block_header
      blk = "class Blk\n  def run\n    [1, 2].map do |x|\n      x * 2\n    end\n  end\nend\n"
      assert_selected scenario(files: { "app/blk.rb" => blk }, body: -> { Blk.new.run }, edits: { "app/blk.rb" => blk.sub("map do", "each do") })
    end

    def test_an_endless_method_body
      assert_selected scenario(files: { "app/endless.rb" => "class Endless\n  def calc(x) = x * 2\nend\n" }, body: -> { Endless.new.calc(2) },
                               edits: { "app/endless.rb" => "class Endless\n  def calc(x) = x * 3\nend\n" })
    end

    # New methods that take over a call.

    def test_a_concern_gains_a_method_its_includer_inherited
      assert_selected scenario(files: { "app/base_model.rb" => "class BaseModel\n  def label = \"base\"\nend\n",
                                        "app/auditable.rb" => "module Auditable\n  def audited? = true\nend\n",
                                        "app/card.rb" => "class Card < BaseModel\n  include Auditable\nend\n" },
                               body: -> { Card.new.label },
                               edits: { "app/auditable.rb" => "module Auditable\n  def audited? = true\n\n  def label = \"audited\"\nend\n" })
    end

    def test_a_class_with_method_missing_gains_the_real_method
      proxy = "class Proxy\n  def method_missing(name, *) = name == :size ? 1 : super\n  def respond_to_missing?(name, p = false) = name == :size || super\nend\n"
      assert_selected scenario(files: { "app/proxy.rb" => proxy }, body: -> { Proxy.new.size },
                               edits: { "app/proxy.rb" => proxy.delete_suffix("end\n") + "\n  def size = 2\nend\n" })
    end

    def test_an_extended_module_gains_a_class_method_the_class_inherited
      assert_selected scenario(files: { "app/finder_base.rb" => "class FinderBase\n  def self.find(id) = [:base, id]\nend\n",
                                        "app/finders.rb" => "module Finders\n  def other = 1\nend\n",
                                        "app/thing.rb" => "class Thing < FinderBase\n  extend Finders\nend\n" },
                               body: -> { Thing.find(1) },
                               edits: { "app/finders.rb" => "module Finders\n  def other = 1\n\n  def find(id) = [:finders, id]\nend\n" })
    end

    def test_an_alias_pointed_at_another_method
      assert_selected scenario(files: { "app/al.rb" => "class Al\n  def real = 1\n  alias fake real\nend\n" }, body: -> { Al.new.fake },
                               edits: { "app/al.rb" => "class Al\n  def real = 1\n  def other = 2\n  alias fake other\nend\n" })
    end

    def test_a_private_method_in_a_singleton_class
      sc = "class Sc\n  class << self\n    def go = helper\n    private def helper = 1\n  end\nend\n"
      assert_selected scenario(files: { "app/sc.rb" => sc }, body: -> { Sc.go }, edits: { "app/sc.rb" => sc.sub("helper = 1", "helper = 2") })
    end

    # Reloading a file keeps its old methods, so the outcome here can't
    # change in-process. In a fresh process the old name is gone.
    def test_renaming_an_empty_hook_its_caller_uses
      hooky = "class Hooky\n  def before_charge; end\n\n  def charge\n    before_charge\n    :charged\n  end\nend\n"
      refute_empty scenario(files: { "app/hooky.rb" => hooky }, test_source: "Hooky.new.before_charge\n  :ok",
                               edits: { "app/hooky.rb" => hooky.sub("def before_charge; end", "def before_charge!; end").sub("    before_charge\n", "    before_charge!\n") }).reasons
    end

    # Code outside the app.

    def test_a_new_initializer_that_patches_app_code
      assert_selected scenario(files: { "app/money.rb" => "class Money\n  def self.round(x) = x.round\nend\n" },
                               fallback: { "config/initializers/existing.rb" => "X = 1\n" },
                               body: -> { Money.round(1.5) },
                               edits: { "config/initializers/patch.rb" => "class Money\n  def self.round(x) = x.floor\nend\n" })
    end

    def test_a_boot_time_method_that_seeds_state
      seed = "module Seed\n  def self.value\n    10\n  end\nend\nSEEDED = Seed.value\n"
      outcome = scenario(files: { "test/support/seed.rb" => seed }, test_source: "SEEDED", edits: { "test/support/seed.rb" => seed.sub("10", "20") })
      refute_empty outcome.reasons
    end

    def test_an_assertion_added_to_the_test_itself
      source = "class CardTest\n  def test_total\n    total = 1 + 1\n    total == 2\n  end\nend\n"
      assert_selected scenario(files: { "test/card_test.rb" => source }, body: -> { CardTest.new.test_total },
                               edits: { "test/card_test.rb" => source.sub("  def test_total\n", "  def test_total\n    return false if 1 + 1 != 3\n") })
    end

    # Boot already pinned the version that loaded, so a run recorded after
    # an edit still names the version that ran.
    def test_a_file_edited_mid_run_records_the_version_that_ran
      price = "class Price\n  def amount\n    1\n  end\nend\n"
      edited = price.sub("    1\n", "    22\n")
      outcome = scenario(files: { "app/price.rb" => price }, body: -> { Price.new.amount },
                         before_record: ->(test) { test.write("app/price.rb", edited) }, edits: { "app/price.rb" => edited })

      assert_selected outcome
    end

    # Constants whose value ran code at load, or that are looked up by name.

    def test_a_constant_computed_by_a_method_at_load
      assert_selected scenario(files: { "app/calc.rb" => "module Calc\n  def self.base = 5\nend\n", "app/foo.rb" => "class Foo\n  LIMIT = Calc.base * 2\nend\n" },
                               test_source: "Foo::LIMIT", edits: { "app/calc.rb" => "module Calc\n  def self.base = 6\nend\n" }, reload: ["app/calc.rb", "app/foo.rb"])
    end

    def test_a_constant_computed_from_another_constant
      assert_selected scenario(files: { "app/base_n.rb" => "module BaseN\n  N = 5\nend\n", "app/foo.rb" => "class Foo\n  LIMIT = BaseN::N * 2\nend\n" },
                               test_source: "Foo::LIMIT", edits: { "app/base_n.rb" => "module BaseN\n  N = 6\nend\n" }, reload: ["app/base_n.rb", "app/foo.rb"])
    end

    def test_a_subclass_constant_read_through_self_class
      assert_selected scenario(files: { "app/lim_base.rb" => "class LimBase\n  LIMIT = 1\n\n  def limit = self.class::LIMIT\nend\n",
                                        "app/lim_child.rb" => "class LimChild < LimBase\n  LIMIT = 2\nend\n" },
                               body: -> { LimChild.new.limit }, edits: { "app/lim_child.rb" => "class LimChild < LimBase\n  LIMIT = 3\nend\n" })
    end

    def test_a_constant_looked_up_with_const_get
      assert_selected scenario(files: { "app/lookup.rb" => "class Lookup\n  def limit = self.class.const_get(:LIMIT)\nend\n",
                                        "app/sized.rb" => "class Sized < Lookup\n  LIMIT = 2\nend\n" },
                               body: -> { Sized.new.limit }, edits: { "app/sized.rb" => "class Sized < Lookup\n  LIMIT = 3\nend\n" })
    end

    # Methods that replace one defined somewhere riptide didn't record.

    def test_a_reopened_class_overrides_a_method_from_another_file
      assert_selected scenario(files: { "app/card.rb" => "class Card\n  def label = \"a\"\nend\n", "app/card_ext.rb" => "class Card\n  def other = 1\nend\n" },
                               body: -> { Card.new.label }, edits: { "app/card_ext.rb" => "class Card\n  def other = 1\n\n  def label = \"b\"\nend\n" })
    end

    def test_a_core_method_redefined_in_a_core_ext
      assert_selected scenario(files: { "lib/core_ext.rb" => "class String\n  def shout = squeeze + \"!\"\nend\n" }, body: -> { "aa".shout },
                               edits: { "lib/core_ext.rb" => "class String\n  def shout = squeeze + \"!\"\n\n  def squeeze = \"Z\"\nend\n" })
    end

    def test_a_comment_in_a_class_level_block_replaced_with_code
      scoped = "class Scoped\n  ACTIVE = lambda do\n    # note\n    :active\n  end\nend\n"
      assert_selected scenario(files: { "app/scoped.rb" => scoped }, body: -> { Scoped::ACTIVE.call }, edits: { "app/scoped.rb" => scoped.sub("    # note\n", "    next :changed\n") })
    end

    # Files the test read, and directories boot listed.

    def test_a_data_file_read_with_file_new
      reader = "class Reader\n  def self.value = File.new(File.join(__dir__, \"../data/value.txt\")).read\nend\n"
      assert_selected scenario(files: { "data/value.txt" => "one\n", "app/reader.rb" => reader }, body: -> { Reader.value }, edits: { "data/value.txt" => "two\n" })
    end

    def test_a_data_file_read_with_io_read
      reader = "class Reader\n  def self.value = IO.read(File.join(__dir__, \"../data/value.txt\"))\nend\n"
      assert_selected scenario(files: { "data/value.txt" => "one\n", "app/reader.rb" => reader }, body: -> { Reader.value }, edits: { "data/value.txt" => "two\n" })
    end

    def test_a_plugin_directory_boot_lists_gains_a_file
      boot = "PLUGINS = []\nDir.children(File.join(__dir__, \"../app/plugins\")).sort.each { |f| load File.join(__dir__, \"../app/plugins\", f) }\n"
      assert_selected scenario(files: { "app/plugins/a.rb" => "PLUGINS << :a\n", "config/boot_plugins.rb" => boot }, boot: ["config/boot_plugins.rb"],
                               test_source: "PLUGINS.dup", edits: { "app/plugins/b.rb" => "PLUGINS << :b\n" }, reload: ["config/boot_plugins.rb"])
    end

    def test_a_constant_assigned_in_a_class_level_if
      cfg = "class Cfg\n  if true\n    MAX = 5\n  else\n    MAX = 100\n  end\nend\n"
      assert_selected scenario(files: { "app/cfg.rb" => cfg }, test_source: "Cfg::MAX", edits: { "app/cfg.rb" => cfg.sub("MAX = 5", "MAX = 6") })
    end

    def test_a_constant_set_by_multiple_assignment
      pair = "class Range2\n  LO, HI = 1, 9\nend\n"
      assert_selected scenario(files: { "app/range2.rb" => pair }, test_source: "Range2::HI", edits: { "app/range2.rb" => pair.sub("1, 9", "1, 8") })
    end

    def test_a_new_constant_shadowing_an_inherited_one
      assert_selected scenario(files: { "app/l_base.rb" => "class LBase\n  LIMIT = 1\nend\n", "app/l_child.rb" => "class LChild < LBase\n  def limit = LIMIT\nend\n" },
                               body: -> { LChild.new.limit }, edits: { "app/l_child.rb" => "class LChild < LBase\n  LIMIT = 2\n\n  def limit = LIMIT\nend\n" })
    end

    def test_a_new_constant_shadowing_an_included_one
      assert_selected scenario(files: { "app/limits.rb" => "module Limits\n  LIMIT = 1\nend\n", "app/l_card.rb" => "class LCard\n  include Limits\n  def limit = LIMIT\nend\n" },
                               body: -> { LCard.new.limit }, edits: { "app/l_card.rb" => "class LCard\n  include Limits\n  LIMIT = 2\n  def limit = LIMIT\nend\n" })
    end

    def test_a_def_replacing_an_attr_accessor
      card = "class ACard\n  attr_accessor :status\n\n  def initialize\n    @status = nil\n  end\nend\n"
      assert_selected scenario(files: { "app/a_card.rb" => card }, body: -> { ACard.new.status },
                               edits: { "app/a_card.rb" => card.sub("  end\nend\n", "  end\n\n  def status = @status || \"draft\"\nend\n") })
    end

    def test_a_source_file_that_isnt_utf8
      latin = "# encoding: iso-8859-1\nclass Latin\n  def name = \"caf\xE9\".bytesize\nend\n".b
      assert_selected scenario(files: { "app/latin.rb" => latin }, body: -> { Latin.new.name }, edits: { "app/latin.rb" => latin.sub("caf", "cafe") })
    end

    def test_a_directory_the_test_globbed_gains_a_file
      themes = "class Themes\n  def self.all = Dir[File.join(__dir__, \"../config/themes/*.yml\")].map { |f| File.read(f) }\nend\n"
      assert_selected scenario(files: { "config/themes/a.yml" => "a\n", "app/themes.rb" => themes }, body: -> { Themes.all.size }, edits: { "config/themes/b.yml" => "b\n" })
    end

    def test_a_file_the_test_checked_for_shows_up
      flag = "class Flag\n  def self.on? = File.exist?(File.join(__dir__, \"../config/flag.txt\"))\nend\n"
      assert_selected scenario(files: { "app/flag.rb" => flag }, body: -> { Flag.on? }, edits: { "config/flag.txt" => "x\n" })
    end

    # Classes found by name, the way Pundit or an association's class_name
    # finds them, with a loader outside the app listing the directory like
    # Zeitwerk does.
    LOADER = File.join(Dir.tmpdir, "riptide-scenario-loader.rb")
    GEM = File.join(Dir.tmpdir, "riptide-scenario-gem.rb")

    def test_a_new_class_a_test_looked_up_by_name_and_didnt_find
      File.write(LOADER, "module ScenarioLoader\n  def self.setup(dir) = Dir.children(dir).sort.each { |f| load File.join(dir, f) }\nend\n")
      finder = "class Finder\n  def self.policy(name) = Object.const_defined?(\"\#{name}Policy\") ? Object.const_get(\"\#{name}Policy\").new.allowed? : :default\nend\n"
      boot = "require #{LOADER.inspect}\nScenarioLoader.setup(File.join(__dir__, \"../app/policies\"))\n"
      assert_selected scenario(files: { "app/policies/user_policy.rb" => "class UserPolicy\n  def allowed? = true\nend\n", "app/finder.rb" => finder, "config/boot_policies.rb" => boot },
                               boot: ["config/boot_policies.rb", "app/finder.rb"], body: -> { Finder.policy("Card") },
                               edits: { "app/policies/card_policy.rb" => "class CardPolicy\n  def allowed? = false\nend\n" }, reload: ["config/boot_policies.rb"])
    end

    def test_a_class_setting_a_gem_read_by_name
      File.write(GEM, "module ScenarioGem\n  def self.limit_for(name) = Object.const_get(name).limit\nend\n")
      require GEM
      card = "class GCard\n  @limit = 5\n  class << self\n    attr_reader :limit\n  end\nend\n"
      assert_selected scenario(files: { "app/g_card.rb" => card }, body: -> { ScenarioGem.limit_for("GCard") }, edits: { "app/g_card.rb" => card.sub("@limit = 5", "@limit = 6") })
    end

    # And the other direction: edits that can't change the test leave it
    # skipped.

    def test_editing_a_method_the_test_never_called_skips_it
      pair = "class Pair\n  def left\n    1\n  end\n\n  def right\n    2\n  end\nend\n"
      outcome = scenario(files: { "app/pair.rb" => pair }, body: -> { Pair.new.left }, edits: { "app/pair.rb" => pair.sub("    2\n", "    3\n") })

      assert_empty outcome.reasons
    end

    def test_a_new_concern_method_nothing_else_defines_skips_it
      assert_skipped scenario(files: { "app/auditable.rb" => "module Auditable\n  def audited? = true\nend\n", "app/card.rb" => "class Card\n  include Auditable\n  def label = \"a\"\nend\n" },
                              body: -> { Card.new.label }, edits: { "app/auditable.rb" => "module Auditable\n  def audited? = true\n\n  def brand_new_thing = 1\nend\n" })
    end

    def test_a_new_test_beside_the_recorded_one_skips_it
      flow = "class CardsFlowTest < Minitest::Test\n  def test_index = :index\nend\n"
      assert_skipped scenario(files: { "test/cards_flow_test.rb" => flow }, body: -> { CardsFlowTest.new("test_index").test_index },
                              edits: { "test/cards_flow_test.rb" => flow.sub("end\n", "  def test_show = :show\nend\n") })
    end

    # A gem's method_missing only catches what its respond_to_missing? says,
    # like ActiveRecord's dynamic finders.
    FRAMEWORK = File.join(Dir.tmpdir, "riptide-scenario-framework.rb")

    def framework_base
      File.write(FRAMEWORK, "class ScenarioBase\n  def method_missing(name, *) = name == :get ? :caught : super\n  def respond_to_missing?(name, p = false) = name == :get || super\nend\n")
      require FRAMEWORK
      "class Page < ScenarioBase\n  def title = get\nend\n"
    end

    def test_a_new_method_a_gems_method_missing_would_have_caught
      page = framework_base
      assert_selected scenario(files: { "app/page.rb" => page }, body: -> { Page.new.title }, edits: { "app/page.rb" => page.sub("end\n", "  def get = :own\nend\n") })
    end

    def test_a_new_method_a_gems_method_missing_wouldnt_catch_skips_it
      page = framework_base
      assert_skipped scenario(files: { "app/page.rb" => page }, body: -> { Page.new.title }, edits: { "app/page.rb" => page.sub("end\n", "  def brand_new = 1\nend\n") })
    end

    def test_a_lookup_that_skips_ancestors_isnt_satisfied_by_a_top_level_constant
      files = { "app/settings.rb" => "class Settings\nend\n", "app/config_value.rb" => "Config = :top\n", "app/other.rb" => "class Other\n  def x = 1\nend\n" }
      assert_skipped scenario(files: files, body: -> { [Settings.const_defined?(:Config, false), Object.const_defined?("Settings::Config")] }, edits: { "app/other.rb" => "class Other\n  def x = 2\nend\n" })
    end

    def test_a_name_that_turned_up_during_the_test_isnt_kept
      files = { "app/late.rb" => "class Late\n  def self.define = const_set(:Thing, 1)\nend\n", "app/other.rb" => "class Other\n  def x = 1\nend\n" }
      assert_skipped scenario(files: files, body: -> { Late.const_defined?(:Thing).tap { Late.define } }, edits: { "app/other.rb" => "class Other\n  def x = 2\nend\n" })
    end

    def test_editing_a_lambda_the_test_never_called_skips_it
      scopes = "class Scoped\n  ACTIVE = -> { :active }\n  ARCHIVED = -> { :archived }\nend\n"
      outcome = scenario(files: { "app/scoped.rb" => scopes }, body: -> { Scoped::ACTIVE.call }, edits: { "app/scoped.rb" => scopes.sub(":archived", ":gone") })

      assert_empty outcome.reasons
    end
  end
end
