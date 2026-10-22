# :ocean: riptide

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.txt)

**Status: not production ready.** riptide is being validated against a large Rails app's CI. Treat any selection decision with suspicion until it's earned your trust.

Test impact analysis for Rails and Minitest. riptide records what each test depends on while it runs, then runs only the tests a change can affect, on pull requests, the main branch and release branches alike.

## How it works

A recorded run is a fact about exact file versions: which parts of which git blobs a test depended on, and whether it passed. A test is skipped when a passing run it kept still holds, meaning nothing it depended on has changed in a way that reaches it. Selection compares against the working tree, never a base commit, so every branch works the same way. When a pull request merges, main's files are the PR's files, and the runs the PR recorded already match.

A test depends on:

- the methods and blocks it ran, during setup, the test itself and teardown
- the constants it read, and for a constant whose value ran code at load, that code too
- the classes it used: the ones it called methods on, and ActiveRecord models it created or loaded without running a line of their file
- the code that ran while those classes loaded, like a concern's `included` block, and the constants that code read
- the database tables its SQL touched
- the files it read, the directories it listed, the files it checked for, and the locale files if it translated anything
- the classes it looked up by name, and the names it looked up that weren't there
- what every test in the process shares: the code that ran at boot, the files boot read, and the files in any directory the app's boot code listed, like `Dir["test/support/**/*.rb"]`

When a file changes, riptide compares the recorded version with the one on disk and works out what changed. A change anywhere in a method or block selects the tests that ran it, including lines Ruby never reports running, like `else`, `rescue` or the second line of a call's arguments. A constant selects the tests that read it, including through `self.class::LIMIT` or `const_get(:LIMIT)`, which match any constant of that name in a file the test used. A declaration like `belongs_to` or `validates` selects the tests that used the class. A new method selects the tests that used its class when it could take over a call, from an ancestor, an attribute, `method_missing`, another file that reopens the class, or a class from outside the app like `String`. A schema change selects the tests that touched the table. Comments and moved lines select nothing.

riptide only records files git tracks or would track, so an ignored file like a key never ends up in a recorded run.

### What it can't see

- Behavior that depends on the clock, the network, randomness or the environment.
- Code run in a process a test spawns.
- A new method a test only probed with `respond_to?` or `try`.
- State a class body writes into another class, like registering itself with a registry, read through that other class.
- `defined?(Foo)` and failed lexical constant reads. Lookups through `const_get` and `const_defined?` are covered.
- Assets a browser loads during a system test. List them in `fallback_patterns` for suites that drive a browser.

## Requirements

- Ruby >= 3.3
- Minitest >= 5.1, < 7
- git

## Setup

```ruby
group :test do
  gem "riptide", git: "https://github.com/nallenscott/riptide"
end
```

Configure riptide at the very top of `test_helper.rb`, before the app loads. It has to see class bodies run.

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

Minitest 5 loads every installed plugin file by itself, so riptide does nothing until `Riptide.configure` is called.

## Configuration

| Option | Default | Meaning |
|---|---|---|
| `suite` | `"default"` | Names the ref runs are kept under, `refs/riptide/<suite>`. A CI stage that runs a different slice of the tests is its own suite. |
| `mode` | `:record` | `:record` records only. `:dry_run` also prints what it would run. `:enforce` runs only the selected tests. |
| `fallback_patterns` | Gemfile, Gemfile.lock, config/application.rb, config/environment.rb, config/environments/test.rb, config/initializers/** | Files every test depends on as a whole. |
| `source_patterns` | every file git knows about | Globs of the files dependencies are recorded on. |
| `locale_patterns` | `config/locales/**/*` | Locale files a test that translated anything depends on. |
| `schema_path` | `db/structure.sql` or `db/schema.rb` | The schema file, analyzed per table. |
| `fixtures_path` | `test/fixtures` | Fixture files, analyzed per table. |
| `retained_runs` | `4` | Runs kept per test. Any of them can make a test skippable, so moving between branches reuses earlier runs. |
| `log_dir` | `tmp/riptide/<suite>` | Where test processes write runs until they're published. |
| `plan_path` | none | Also writes the selection as JSON. |

## Sharing runs

Runs live in git, under `refs/riptide/<suite>` in the app's own repository. They never touch a branch, and a plain clone doesn't fetch them.

```bash
bundle exec riptide fetch --suite unit     # before the tests
bundle exec rails test
bundle exec riptide publish --suite unit   # after them
```

Test processes only read the ref and append to their own log, so a read-only `.git` is enough while tests run. `publish` folds the logs into a new commit and pushes it. Runs describe immutable file versions, so two builds publishing at once merge by union, and the one that lost the race retries. The ref only pins file versions from the commit the build checked out, so nothing staged, stashed or uncommitted gets pushed.

Pass `--prune` on builds that discover the whole suite, like main, to drop runs of tests that no longer exist. A test that ran in the last two weeks stays, since it may only exist on a branch that hasn't merged yet.

## Development

Run `bin/setup` to install dependencies, then `rake test`.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
