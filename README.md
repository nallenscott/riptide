# riptide

**Run the tests your changes can affect.**

Riptide is a test impact analysis engine for Rails and Minitest. It records what each test depends on at runtime, then uses that history to determine which tests need to run when the code changes.

It understands Ruby methods, constants, class loading, ActiveRecord, database queries, fixtures, and file access. It also tracks the code and files loaded during application and test setup.

Test history lives in Git and can be reused across pull requests, main, and release branches, regardless of how changes were merged. No external services or changes to your tests required.

<!-- TODO: Replace this placeholder with the approved Riptide demo GIF.
     Suggested path: docs/assets/riptide-demo.gif
     Demo: Change a Ruby method, run Riptide, see the selected tests. -->

## Why Riptide?

Large Rails applications can spend a lot of CI time running tests that have nothing to do with the changes being tested.

Selecting tests by filename only gets you so far. Ruby's dynamic behavior makes it difficult to know what a test actually depends on without running it.

Riptide records those dependencies as tests execute. When something changes, it compares the changed code with what each test previously used.

The result is a smaller test run, with an explanation of why each test was selected.

## How it works

Riptide builds a dependency history from passing test runs. Each run records the exact versions of the files and code it used.

When those files change, Riptide analyzes the differences and determines which recorded runs are still valid.

For example, consider three tests:

- `test_widget` calls `Widget#size`.
- `test_other` calls `Other#size`.
- `test_both` calls both methods.

Changing the implementation of `Widget#size` selects `test_widget` and `test_both`. The recorded run for `test_other` is still valid.

This example comes from Riptide's own end-to-end tests, which also verify that passing runs can be reused after pull requests are merged, including squash merges.

### What Riptide tracks

Riptide records dependencies on executed methods and blocks, constants, classes, database tables, fixtures, files, and directories. It also accounts for code executed during application boot, test setup, and class loading.

Source changes are analyzed with Prism. Changes to unrelated methods, comments, or whitespace don't automatically invalidate every test associated with a file.

### Test history across branches

Each passing run records the versions of its dependencies. Riptide checks those versions against the current files, rather than calculating changes from a Git diff base.

A run recorded on one branch can still be valid on another.

Records are stored in Git refs under `refs/riptide/`. Builds fetch the history they need and publish new results when they finish.

## Getting started

Riptide currently supports Ruby 4.0, Minitest 5.26.1 or later (below 7), and Git 2.45 or later.

Add it to your Gemfile:

```ruby
group :test do
  gem "riptide", git: "https://github.com/nallenscott/riptide"
end
```

Configure Riptide at the beginning of `test_helper.rb`, before Rails loads:

```ruby
require "riptide"

Riptide.configure do |c|
  c.suite = "unit"
  c.mode = :dry_run
end

require_relative "../config/environment"
require "rails/test_help"
require "minitest/riptide_plugin"
```

Run your tests normally:

```bash
bundle exec rails test
```

Riptide supports three modes:

| Mode | Behavior |
|---|---|
| `:record` | Runs the full suite and records dependencies. |
| `:dry_run` | Runs the full suite and reports which tests would have been selected. |
| `:enforce` | Runs only the selected tests. |

Start with `:dry_run` to check selection decisions against your existing suite.

## CI integration

Riptide shares test history between CI builds using Git refs.

For a pull request:

```bash
bundle exec riptide fetch --pr 42 --target main
bundle exec rails test
bundle exec riptide publish --suite unit --pr 42 --target main
```

On main:

```bash
bundle exec riptide fetch --branch main --harvest
bundle exec rails test
bundle exec riptide publish --suite unit --branch main --harvest
```

Riptide can identify which pull requests have landed, reuse their passing runs, and remove records that are no longer needed.

See the [CI guide](docs/ci.md) for release branches, parallel test processes, and configuration options.

## Auditing your test suite

Riptide also uses recorded test execution to find tests that may be worth removing or restructuring.

```bash
bundle exec riptide fetch --branch main
bundle exec riptide audit --suite unit
```

The audit reports inherited tests, potential duplicates, tests that perform no assertions or mock expectations, and large tests that may benefit from being split up.

It uses recorded execution, assertions, and statement-level dependencies to support its findings. The command is read-only and doesn't modify your tests.

## Status and limitations

Riptide is under active development and is being validated against a large Rails application's CI.

Test selection is conservative when there's insufficient history or a previous test failure. Tests with no recorded run are executed, and failures continue running until a later build passes them.

Some dependencies cannot be observed reliably, including external services, time-dependent behavior, and code executed in child processes. These may require additional fallback configuration.

Review the [limitations](docs/limitations.md) before enabling `:enforce` in CI.

## Documentation

- [Architecture and dependency tracking](docs/architecture.md)
- [CI integration and Git storage](docs/ci.md)
- [Configuration reference](docs/configuration.md)
- [Test auditing](docs/auditing.md)
- [Limitations and fallback behavior](docs/limitations.md)

## Development

Run `bin/setup` to install dependencies, then `rake test`.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
