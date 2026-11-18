# Architecture

Riptide selects tests from recorded execution, not from a list of changed filenames. A passing run records the exact versions of the code and other inputs it used. When a later build starts, Riptide checks whether any of those inputs have changed in a way that could affect the test.

This document explains how recording, change analysis, selection, and persistence fit together.

## Recording a test

Riptide starts tracing when `Riptide.configure` runs, before Rails loads. The native tracer observes Ruby execution and class loading. Collectors record other dependencies, including SQL tables, file reads, directory listings, and constant lookups.

When Minitest starts, Riptide's plugin installs a recorder around `Minitest::Test#run`. A recording covers setup, the test body, and teardown. A test's top-level body statements are also recorded separately when Riptide can locate their source. Those statement records include execution time, assertion comparisons, and dependencies between statements.

Code executed outside a test is recorded in shared scopes:

- **Process setup:** application boot, support-file loading, and code executed before tests, including worker setup.
- **Test-class setup:** code run around a particular test class, such as `before_all`.
- **Class loading:** code and constants used while classes or concerns load, shared by tests that use those classes.

These scopes matter because changing a shared setup dependency can affect tests even if their individual bodies never execute the changed code.

See [`tracer.rb`](../lib/riptide/tracer.rb), [`collectors.rb`](../lib/riptide/collectors.rb), [`recorder.rb`](../lib/riptide/recorder.rb), and [`scope.rb`](../lib/riptide/scope.rb).

## From events to dependencies

The recorder turns execution into dependencies on parts of particular file versions. For Ruby, those parts include methods, blocks, classes, and constants. ActiveRecord queries are associated with tables; schema and fixture changes can then invalidate tests that touched those tables.

Riptide also records whole-file reads, directory listings, locale usage, and lookups for names that did not exist. A newly created file or constant can therefore invalidate a test that previously checked for its absence.

Only files Git tracks or would track are eligible to be recorded. Ignored files aren't pinned into published history.

The resulting dependencies are stored with Git blob identifiers. Riptide checks that a file did not change after Ruby compiled it, rather than attributing execution to a version it may not have used.

See [`inputs.rb`](../lib/riptide/inputs.rb), [`env.rb`](../lib/riptide/env.rb), and [`resolver.rb`](../lib/riptide/resolver.rb).

## Analyzing changes

Riptide compares each recorded file version with the current file. It uses Prism to interpret Ruby source and classify the changed regions.

A change to a method or block invalidates runs that used it. This is intentionally coarser than line coverage: Ruby doesn't report every line that affects execution, including some `else` and `rescue` lines. Declarations, constants, and new methods that might override existing behavior have their own invalidation rules.

Class-level code can affect many tests. If a change alters top-level code executed during application boot, Riptide can select the full suite. Comments, whitespace, and certain method reorderings don't need to invalidate a run.

Schema and fixture analysis works at the table level, including foreign-key relationships.

See [`analysis/ruby.rb`](../lib/riptide/analysis/ruby.rb), [`analysis/schema.rb`](../lib/riptide/analysis/schema.rb), [`analysis/fixture.rb`](../lib/riptide/analysis/fixture.rb), and [`analyzer.rb`](../lib/riptide/analyzer.rb).

## Selecting tests

The selector reads the available run indexes and checks the recorded versions of their dependencies against the working tree. It does **not** need a comparison branch or a Git diff base.

A test can be skipped if at least one recorded passing run still holds for the current files. Older valid runs can be useful when moving between branches. A test runs when no passing run holds, when it has no recorded history, or when it has an open failure. Tests sharing the same class-and-method identity also run because their histories cannot be distinguished reliably.

Selection reports the cause of invalidation and whether it reached the test through its own execution, class setup, or process setup. With `plan_path` configured, that decision is also written as JSON.

`:record` records without selecting. `:dry_run` reports the decision but still runs the full suite. `:enforce` restricts Minitest to the selected tests.

See [`selector.rb`](../lib/riptide/selector.rb), [`runner.rb`](../lib/riptide/runner.rb), and [`session.rb`](../lib/riptide/session.rb).

## Keeping history in Git

Riptide stores passing runs under `refs/riptide/runs/<suite>/...` and build metadata and open failures under `refs/riptide/stamps/<suite>/...`. These refs are separate from ordinary branches; a normal clone doesn't download them.

Each build publishes a unit identified by a branch or pull request. The run index maps file versions and changed parts to recorded runs and shared dependency sets. Its content is sharded so a publish can rewrite only the index entries that changed. Riptide stores the file versions needed to analyze future changes.

Test processes append local logs. A separate `riptide publish` folds those logs into the build's unit and pushes it. Concurrent publishers use leases and retry when another build updates the same unit.

On long-lived branches, harvesting recognizes pull requests whose changes are already present and carries forward passing history that still holds. This works without requiring the PR's original commits to survive a squash merge.

See [`index.rb`](../lib/riptide/index.rb), [`store.rb`](../lib/riptide/store.rb), and [`harvest.rb`](../lib/riptide/harvest.rb). [CI integration](ci.md) covers the commands.

## What this design doesn't guarantee

The selector can only act on dependencies Riptide managed to observe or conservatively cover. A successful selection is not proof that every possible behavioral dependency was captured. Use dry-run mode and full-suite comparisons while validating an application.

See [Limitations](limitations.md) for specific gaps and fallback options.
