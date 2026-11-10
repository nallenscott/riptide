# :ocean: riptide

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.txt)

**Status: not production ready.** riptide is being validated against a large Rails app's CI. Treat any selection decision with suspicion until it's earned your trust.

Test impact analysis for Rails and Minitest. riptide records what each test depends on while it runs, then runs only the tests a change can affect, on pull requests, the main branch and release branches alike.

## How it works

riptide records what each test touches while it runs. When the code changes, it reruns only the tests whose recorded dependencies the change reaches.

Every recorded run names the exact file versions it depended on, and riptide compares them with the files on disk, never with a base commit. So a pull request, main and a release branch all work the same way, however a PR merged.

### What a test depends on

- **Code it ran:** the methods and blocks it ran, during setup, the test itself and teardown.
- **Constants:** the constants it read, and for a constant whose value ran code at load, that code too.
- **Classes:**
  - the ones it called methods on;
  - ActiveRecord models it created or loaded without running a line of their file;
  - the code that ran while those classes loaded, like a concern's `included` block, and the constants that code read.
- **The database:** the tables its SQL touched.
- **Files:** the files it read, the directories it listed, the files it checked for, and the locale files if it translated anything.
- **Names:** the classes it looked up by name, and the names it looked up that weren't there.
- **Shared setup:** what every test in the process shares. That's the code that ran at boot, the files boot read, and the files in any directory boot listed, like `Dir["test/support/**/*.rb"]`.

riptide only records files git tracks or would track, so an ignored file like a key never ends up in a recorded run.

### What a change selects

When a file differs from the version a test recorded, riptide works out what changed in it and selects the tests that used that part.

| Change | Tests it selects |
|---|---|
| Anything inside a method or block, including lines Ruby never reports running, like `else`, `rescue` or the second line of a call's arguments | The tests that ran it |
| A constant's value | The tests that read it, including through `self.class::LIMIT` or `const_get(:LIMIT)` |
| A declaration, like `belongs_to`, `validates` or `scope` | The tests that used the class |
| A new method that could take over a call, from an ancestor, an attribute, `method_missing`, another file reopening the class, or a core class like `String` | The tests that used the class |
| A table in `db/structure.sql` or `db/schema.rb`, or its fixtures | The tests that touched the table |
| A file a test read, a directory it listed, or a name it found missing that now exists | The tests that did that |
| A file in `fallback_patterns`, like `Gemfile.lock` or an initializer | Every test |
| Top-level code that runs at boot | Every test |
| A deleted file, or a recorded version git no longer has | The tests that recorded it |
| Comments, blank lines and moved code | Nothing |

A test that failed keeps running until a later build passes it, so a failure riptide can't trace back to code, like a flaky test, still reruns. A test with no recorded run always runs.

### How runs move between builds

1. A pull request build reads its own runs and its target branch's, and saves its own.
2. main and stable read the runs of the pull requests that landed in them, found with `git merge-tree`, and keep the ones that still hold. An unmerged pull request never reaches them.
3. Once main has a pull request's runs, it deletes that pull request's record. Anything nobody wrote to for 30 days goes too.

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
- git 2.45 or later

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
| `suite` | `"default"` | Names the refs runs are kept under, `refs/riptide/runs/<suite>/...`. A CI stage that runs a different slice of the tests is its own suite. |
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

Runs live in git in the app's own repository, under `refs/riptide/`. They never touch a branch, and a plain clone doesn't fetch them.

Each suite keeps a unit per build: `branches/<branch>` for a branch and `prs/<number>` for a pull request. A unit is two refs, written and deleted together. `refs/riptide/runs/<suite>/<key>` holds the passing runs as an index. `refs/riptide/stamps/<suite>/<key>` holds the open failures and, for a pull request, its landing record: the branch it merges into and the files it changed. Both point at tags wrapping trees, so a publish uploads only what changed.

A pull request build reads its own unit and its target's, and writes its own:

```bash
bundle exec riptide fetch --pr 42 --target main
bundle exec rails test
bundle exec riptide publish --suite unit --pr 42 --target main
```

A build of a long-lived branch like main harvests:

```bash
bundle exec riptide fetch --branch main --harvest
bundle exec rails test
bundle exec riptide publish --suite unit --branch main --harvest
```

A release branch cut from main also reads main's unit, with `--branch stable --harvest --upstream main`.

`fetch` runs once before the tests and brings in every suite's units for the build, and nothing else: test processes read every unit riptide has locally. They only read refs and append to their own log, so a read-only `.git` is enough while tests run.

A harvesting fetch also brings every pull request's stamp, a few KB each, and checks which landed. It replays each one's changed files onto the commit it's testing with `git merge-tree`. When that's clean and changes nothing, the pull request's changes are already there, however it merged, and only then does the build fetch its runs. A pull request that hasn't landed never reaches main's selection.

`publish` folds the logs into the build's unit. Passes of the tests selection picked become runs, and a test selection skipped already had one that holds. Failures, and tests that started and never finished, open failures. A pass closes the open failures the build saw when it fetched, never one another build opened meanwhile. With `--harvest`, it first copies the passing runs and open failures of the pull requests that landed, then deletes their units. It also deletes any unit nobody wrote for 30 days, like one for a pull request closed without merging. Deleting a unit never skips a test, it only means a test gets run again.

riptide never fails a build. A problem in `fetch` or `publish` prints a warning and exits 0, and means reading or saving less, so more tests run. Every git call has a deadline.

Each runs ref holds an index from file versions to the runs that used each part of them, split into 256 shards so a publish rewrites only the shards that changed. Ids stay put between publishes. The ref only pins file versions from the commit the build checked out, so nothing staged, stashed or uncommitted gets pushed. Two builds publishing the same unit at once push with a lease, and the one that lost the race folds its logs in again and retries.

## Development

Run `bin/setup` to install dependencies, then `rake test`.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
