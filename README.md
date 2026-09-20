# :ocean: riptide

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.txt)

**Status: not production ready.** riptide is early and unproven outside of small test fixtures. The core selection algorithm has tests and has been validated end to end against toy apps, but hasn't run against a large Rails codebase yet. Expect rough edges, and treat any selection decision with suspicion until it's earned your trust.

Local-first test impact analysis for Rails and Minitest: given a git diff, riptide figures out which tests are affected by what changed, and runs only those, instead of the whole suite.

## The problem

A large Rails app's test suite gets slower every year, and most of it has nothing to do with whatever line you just changed. CI ends up running thousands of tests to validate a one-line fix. riptide watches which lines of your app's code each test executes, at runtime, and uses that map to answer one question precisely: given this diff, which tests could possibly be affected?

## Mental model

riptide doesn't guess. It watches. Every time a test runs, riptide records exactly which lines of source it touched. The next time you have a diff, it doesn't ask "which files changed", it asks "did the code this test touched move", using git's diff to tell the difference between an unrelated line shifting around and a change. A shift gets ignored. A change selects the test.

Like a riptide, it runs beneath the surface, pulling narrowly and precisely rather than sweeping everything with it.

## Requirements

- Ruby >= 3.0
- Minitest >= 5.1, < 7
- SQLite3

Rails/Minitest only. No RSpec support.

**Compatibility.** Minitest's plugin API (`register_plugin`, `init_plugins`) is verified identical on 5.27, 6.0.0, and 6.0.6, the versions this has been checked against; the gem dependency caps below 7 so an untested future major fails at `bundle install` rather than silently at runtime. riptide doesn't depend on the `rails` gem itself, nothing in its code calls a Rails API, but its default file-path conventions (see "How selection works" below) are verified against Rails' app generator templates on 6.1, 7.0, and 8.1 directly, not inferred. Every one of those defaults is overridable via `Riptide.configure` for a different layout or an older/newer Rails.

## Installation

Not published to RubyGems yet. Add it straight from GitHub:

```ruby
group :test do
  gem "riptide", git: "https://github.com/nallenscott/riptide"
end
```

## Setup

Add one line to `test_helper.rb`:

```ruby
require "minitest/autorun"
require "minitest/riptide_plugin"
```

That's the entire setup. It's a standard Minitest plugin (`Minitest.register_plugin`, `plugin_riptide_init`), not a custom API, so it activates the same way for any Minitest run, `bin/rails test`, `rake test`, or riptide's CLI.

## Usage

```bash
bundle exec riptide run
```

First run bootstraps automatically: no map exists yet, so it runs the full suite and builds one. Every run after that computes a diff against `<default_remote>/<default_branch>` (both configurable, defaulting to `origin`/`main`) and runs only what that diff could affect.

```bash
bundle exec riptide rebuild
```

Wipes the map and rebuilds it from scratch with a full run. Use this if a map ever seems wrong and you don't want to reason about why.

## How selection works

For each file in the diff, riptide looks up every test that has touched it and diffs that test's last-known version of the file against the current one. If none of the hunks overlap the lines that test covered, the test gets skipped, even if the file moved around underneath it. If a hunk does overlap, or if riptide has no historical data for an existing file, the test gets selected, favoring false positives over false negatives always.

Some changes always trigger a full run regardless of the above, because they can affect app-wide behavior in ways line coverage can't be trusted to capture: `Gemfile`, `Gemfile.lock`, `test/test_helper.rb`, `config/application.rb`, `config/environment.rb`, and anything under `config/initializers/`. That list is `Riptide.configure`'s `fallback_patterns`, verified against Rails' generator conventions (see Compatibility above), not a guess, override it for a different layout.

A changed file with no historical coverage also triggers a full run by default, the same reasoning: an empty history could mean untested code, or it could mean an incomplete map, and the safe assumption is the latter. But that check only makes sense for files a test could plausibly cover in the first place. Left at its default (unset), it applies to every changed file, including things like CI config or a Dockerfile that no test execution could touch, which will always look "uncovered" and force a full run every single time. Set `source_patterns` once you have data from your Store showing which directories your tests exercise, and the check narrows to just that scope. There's no built-in default for this one: unlike the fixed Rails paths above, "where does this app's tested code live" isn't a convention riptide can verify against, it varies per app, and guessing at it is exactly the kind of assumption this gem exists to avoid making about a codebase it doesn't know.

## Known limitations

- `bundle exec riptide plan` and `bundle exec riptide why` are not implemented yet.
- No shared CI-caching story yet. The dependency map lives at `tmp/riptide/riptide.db` and needs to be persisted across CI runs (e.g. archived and restored as a build artifact) for riptide to have any benefit in CI; without that, every run bootstraps from scratch.
- Not tested against a large-scale Rails application yet.

## Development

After checking out the repo, run `bin/setup` to install dependencies, then `rake test` to run the suite.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/nallenscott/riptide.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
