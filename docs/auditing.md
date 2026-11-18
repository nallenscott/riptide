# Auditing the test suite

Riptide records more than the dependencies needed for test selection. It also tracks each test body's top-level statements, execution time, assertions, and the values compared by those assertions. `riptide audit` uses that history to point out tests that may be redundant or difficult to maintain.

The audit **does not edit tests**. It reports candidates for review.

## Running an audit

First fetch the history you want to inspect:

```bash
bundle exec riptide fetch --branch main
bundle exec riptide audit --suite unit
```

The audit reads the history available in local Riptide refs and logs. Use the suite name that recorded those tests.

A test only counts if Riptide can read its current body and its newest passing run matches the current version of its test file. Failing tests, tests changed since their last passing run, and tests without enough recorded information are excluded from the corresponding analysis. This avoids reporting stale observations as facts about the current suite.

## Inherited tests

Minitest subclasses inherit test methods. This can cause the same inherited test to execute across multiple concrete test classes, sometimes because a class was nested or subclassed for organization.

The audit reports tests inherited from another class and shows the runtime associated with the copies. A base class test that only runs in its subclasses is treated as belonging to those subclasses; it isn't reported merely because the base class defines it.

Review these findings before removing any inheritance. The subclasses may intentionally run the same test under different class-level configuration.

## Duplicate tests

Riptide looks for multiple tests **within the same test class** that appear to run the same program. Its comparison includes:

- The source body, compared without irrelevant whitespace and comments.
- Which statements ran and what the assertions compared.
- Execution outside the body, including recorded setup dependencies.

The audit excludes cases where it can't safely compare behavior from the available source, such as a block reading a local variable captured from outside its body or code depending on the test's own name.

Tests in different classes are not treated as duplicates. Class settings can make identical bodies behave differently without executing an obvious extra line.

A reported duplicate is a strong candidate to inspect, not permission to delete blindly. Check the intent and edge cases of both tests.

## Tests that check nothing

The audit identifies tests whose recorded bodies contain no recognized assertion or mock expectation.

It checks assertion-style methods, including assertions reached through helpers, and supported Mocha expectations. A test can still have meaningful side effects or use an assertion mechanism Riptide doesn't recognize, so inspect the test before removing it.

The report includes the source file and line to make each finding easy to investigate.

## Large tests: “megaliths”

Riptide reports tests whose bodies contain **15 or more top-level statements**, sorted by recorded runtime, slowest first.

A large test generally falls into one of two categories:

**Steps that build on each other.** Assertions appear between statements that mutate state. Riptide identifies possible split points and estimates the extra execution time of splitting the test into separate cumulative steps. Splitting may improve failure isolation, but the repeated setup and earlier steps can make the build slower.

**One scenario.** The test exercises one larger flow that doesn't divide cleanly into independent steps. The audit reports its size and may identify repeated setup code shared with neighboring tests.

For shared setup, Riptide looks for at least five matching non-assertion lines among tests in the same file. It reports the source lines and a few of the other tests involved.

The timings come from recorded runs. Treat them as estimates, particularly for work affected by scheduling, I/O, or runtime variability.

## Reading the report

Each category includes test counts. Where the data supports it, the report also shows approximate runtime represented by the findings. Tests are identified by name and source location.

A practical review order is:

1. **Duplicates:** look for tests that can be consolidated without losing distinct behavior.
2. **Checks nothing:** confirm whether the test really validates an outcome.
3. **Inherited:** check whether accidental inheritance is multiplying work.
4. **Megaliths:** inspect slow, large tests for clearer boundaries or shared setup.

Don't optimize solely for the reported count or timing. The goal is a test suite that's easier to understand and maintain without losing useful coverage.

## How it relates to selection

Auditing and test selection use the same recorded history, but answer different questions. Selection asks whether a passing run still holds after a change. Auditing examines the body and observed behavior of current passing tests to identify maintenance opportunities.

The two features have different limits. A run may be usable for selection even when its test body can't be reconstructed well enough for auditing.

See [Architecture](architecture.md) for how Riptide records statements and dependencies, and [Limitations](limitations.md) for behavior it cannot reliably observe.
