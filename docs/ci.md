# CI integration

Riptide records dependencies while tests run and saves the results afterward. A CI build has three steps:

1. Fetch the test history available to this build.
2. Run the tests.
3. Publish the results, including failures.

The history lives in the application's Git repository, under `refs/riptide/`. CI needs permission to fetch and push those refs. Test processes can read the fetched refs with a read-only `.git`; the separate publishing step needs a writable Git directory and credentials to push.

## Configure the test suite

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

A suite is a distinct slice of the tests, such as a unit-test job or another CI stage. Use a different suite name for each slice, and pass the same name to `publish`.

Start with `:dry_run`. It runs the entire suite but reports which tests Riptide would select. After validating the decisions, `:enforce` runs only the selected tests. See [Configuration](configuration.md).

## Pull request builds

Pass the pull request number and its target branch:

```bash
bundle exec riptide fetch --pr 42 --target main
bundle exec rails test
bundle exec riptide publish --suite unit --pr 42 --target main
```

`fetch` retrieves the PR's recorded runs and its target branch's runs for every suite, if available. `publish` writes the current suite's passing runs and failure records to the PR's unit.

A PR targeting a release branch should pass that branch as `--target`, not `main`.

## Main and other long-lived branches

A build on main can harvest the history of PRs that have landed:

```bash
bundle exec riptide fetch --branch main --harvest
bundle exec rails test
bundle exec riptide publish --suite unit --branch main --harvest
```

A release branch can also read main's history:

```bash
bundle exec riptide fetch --branch stable --harvest --upstream main
bundle exec rails test
bundle exec riptide publish --suite unit --branch stable --harvest --upstream main
```

Use your repository's real branch names. `--upstream` identifies an additional long-lived branch whose recorded runs can be reused.

## How harvesting works

A harvesting build reads the small metadata records for PRs targeting its branch. For each candidate, Riptide uses `git merge-tree` to check whether the PR's recorded file changes are already present in the branch being tested.

If they are, Riptide fetches the PR's passing runs and reuses those whose recorded dependencies still hold. It does not rely on the original PR commits surviving in the target branch, so the same approach covers merge commits, squash merges, and rebases.

An unmerged PR is not harvested into main. After a landed PR's records are incorporated into the long-lived branch, its unit is removed. A unit that hasn't been written to for 30 days is also eligible for cleanup.

## Publish even when tests fail

The publishing step should execute after the test command regardless of its exit status. Riptide records failures and tests that started but never completed. A test with an open failure will continue to run until a later build passes it.

Don't hide the test command's failure from CI. For example, this shell pattern preserves the test exit code while still publishing:

```bash
set +e
bundle exec rails test
test_status=$?
bundle exec riptide publish --suite unit --branch main --harvest
exit "$test_status"
```

Use the appropriate `publish` identity for the build. The snippet assumes the matching `fetch --branch main --harvest` already ran.

Riptide is designed not to fail the build because its own fetch, selection, or publish logic encountered a problem. The CLI reports operational errors as warnings. Test failures still need to fail CI through the test command's exit status. Malformed CLI arguments are also reported as errors.

## Parallel execution and concurrent builds

Test processes append their results to local logs. A separate `publish` command folds those logs into a Git-backed unit. If you configure a custom `log_dir`, pass the matching directory to the publishing command with `--log-dir`.

Concurrent builds publishing the same unit use Git leases. If another build updates the ref first, Riptide reloads that unit, folds its records in again, and retries within a deadline. If publishing fails, the local logs are retained rather than discarded.

For CI systems that split the suite across separate jobs or machines, plan how those jobs name their suites, retain their logs, and publish their units. A single `publish` can only read the logs available on its own filesystem.

## Other options

`fetch` and `publish` accept `--remote NAME` to use a remote other than `origin`. They also accept `--root DIR` when the Rails application is in a subdirectory of a repository or the command runs elsewhere.

`publish` accepts `--retained-runs N` to control how many recorded runs Riptide keeps for each test. The default is four.

For the storage model and selection rules, see [Architecture](architecture.md). For cases where selection can't safely identify dependencies, see [Limitations](limitations.md).
