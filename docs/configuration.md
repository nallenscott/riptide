# Configuration

Configure Riptide before Rails loads so it can observe application boot and class loading.

```ruby
# test/test_helper.rb
require "riptide"

Riptide.configure do |c|
  c.suite = "unit"
  c.mode = :dry_run
end

require_relative "../config/environment"
require "rails/test_help"
require "minitest/riptide_plugin"
```

Minitest discovers installed plugins automatically, but Riptide does nothing in a process that hasn't called `Riptide.configure`.

## Requirements

- **Ruby 4.0 (CRuby):** the native tracer is currently written for Ruby 4.0. The gem can install on other versions, but Riptide stays disabled unless explicitly built for that runtime.
- **Minitest:** 5.26.1 or later, below 7.
- **Git:** 2.45 or later.

The native tracer depends on Ruby VM internals. During installation it retrieves internal headers from the exact Ruby source revision when needed. `RIPTIDE_RUBY_SOURCE` can point to an existing source tree instead. See [Native tracer options](#native-tracer-options).

## Options

| Option | Default | Description |
| --- | --- | --- |
| `root` | Current working directory | Application root used for file paths and Git operations. |
| `suite` | `"default"` | Name for this slice of tests. Separate CI stages that run different slices should have separate suite names. |
| `mode` | `:record` | `:record`, `:dry_run`, or `:enforce`. |
| `fallback_patterns` | Gemfile, Gemfile.lock, Rails application/environment files, and `config/initializers/**/*` | File paths and globs that every test depends on as a whole. |
| `source_patterns` | `[]` (all Git-known files) | Restrict dependency recording to matching file globs. Schema and fixture files remain included. |
| `locale_patterns` | `["config/locales/**/*"]` | Locale files used by tests that perform translations. |
| `schema_path` | Auto-detected: `db/structure.sql` or `db/schema.rb` | Schema file to analyze by table. |
| `fixtures_path` | `"test/fixtures"` | Fixture directory, analyzed by table. |
| `log_dir` | `tmp/riptide/<suite>` | Directory where test processes append records before publishing. |
| `plan_path` | `nil` | Optional JSON file containing the test-selection decision. |

All relative paths are resolved against the configured root where applicable.

### Modes

**`:record`** runs the complete suite and collects dependencies. It doesn't make a selection decision.

**`:dry_run`** computes and prints the selection but still runs the complete suite. Use this to compare Riptide's decisions against normal CI execution.

**`:enforce`** runs only the selected tests. A test with no usable passing history, an open failure, or ambiguous duplicate identity is selected.

Example:

```ruby
Riptide.configure do |c|
  c.suite = "unit"
  c.mode = ENV.fetch("RIPTIDE_MODE", "dry_run").to_sym
  c.plan_path = "tmp/riptide-plan.json"
end
```

The selector reports counts by change category, plus representative reasons and how the changes reached tests. `plan_path` writes the detailed decision, including test names and reasons, to JSON.

### Fallback patterns

Use `fallback_patterns` for files that can change test behavior across the whole suite without leaving an observable dependency.

```ruby
Riptide.configure do |c|
  c.fallback_patterns += ["config/feature_flags.yml"]
end
```

A change to one of these files selects all tests. Keep the list targeted; broad patterns can make selection much less useful. Directory matches are tracked, so adding a new file matching a fallback pattern can invalidate earlier history too.

### Source patterns

By default Riptide records dependencies on Git-known files under the application root. To restrict the recorded scope:

```ruby
Riptide.configure do |c|
  c.source_patterns = ["app/**/*.rb", "lib/**/*.rb"]
end
```

Restricting patterns can exclude dependencies you actually need. Schema and fixture files are always considered independently of `source_patterns`. Riptide never records ignored files.

### Logs and publishing

The test process writes local logs; the CLI publishes them separately. Match the suite and log directory in both steps:

```ruby
Riptide.configure do |c|
  c.suite = "unit"
  c.log_dir = "tmp/riptide-unit"
end
```

```bash
bundle exec riptide publish --suite unit --branch main --log-dir tmp/riptide-unit
```

The command assumes you already fetched the appropriate branch history and ran the suite. The complete sequence is in [CI integration](ci.md).

## CLI options

### `fetch`

```bash
bundle exec riptide fetch --pr 42 --target main
bundle exec riptide fetch --branch main --harvest
bundle exec riptide fetch --branch stable --harvest --upstream main
```

Pass `--pr NUMBER --target BRANCH` for a PR, or `--branch NAME` for a branch. `--harvest` collects landed PR history on a long-lived branch; `--upstream BRANCH` identifies an additional branch whose records should be read.

Optional: `--root DIR`, `--remote NAME`.

### `publish`

Use the same build identity as `fetch`, plus a suite name:

```bash
bundle exec riptide publish --suite unit --pr 42 --target main
```

Optional: `--root DIR`, `--remote NAME`, `--log-dir DIR`, `--retained-runs N`.

`--retained-runs` defaults to **4**. Keeping multiple valid runs can help reuse history across branches.

### `audit`

```bash
bundle exec riptide audit --suite unit
```

Optional: `--root DIR`, `--log-dir DIR`. It reads locally available history; fetch first if you want the records from a remote. See [Auditing](auditing.md).

## Native tracer options

The tracer uses Ruby's internal headers, which aren't part of a normal Ruby header installation. Riptide retrieves the matching source files from Ruby's repository at the runtime's exact revision, unless you provide a local source tree.

| Environment variable | Behavior |
| --- | --- |
| `RIPTIDE_RUBY_SOURCE=/path/to/ruby` | Use a local Ruby source tree instead of downloading it during extension build. |
| `RIPTIDE_TRACER=off` | Build without the native tracer; Riptide remains disabled. |
| `RIPTIDE_TRACER=on` | Attempt to build the tracer for a Ruby version not yet listed as supported. This is experimental and does not establish compatibility. |

If the tracer can't be compiled or linked, installation can still complete with Riptide disabled. Its warning explains why.

See [Limitations](limitations.md) for supported environments and situations where recording may be incomplete.
