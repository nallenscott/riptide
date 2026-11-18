# Limitations

Riptide selects tests using the dependencies it recorded from earlier passing runs. That can reduce unnecessary execution, but dynamic Ruby applications have behaviors no runtime tracer can reliably infer from a previous run.

This document describes the known gaps and what to do about them. Read it before enabling `:enforce` in CI.

## Validate before enforcing

Start with `:dry_run`. It records dependencies, computes a selection, and still runs the full suite:

```ruby
Riptide.configure do |c|
  c.suite = "unit"
  c.mode = :dry_run
  c.plan_path = "tmp/riptide-plan.json"
end
```

Compare selection decisions with full-suite outcomes over real code changes and across PR, main, and release-branch builds. Where selection misses an important dependency, either add a suitable fallback pattern or keep the affected suite running in full while the gap is investigated.

Riptide's selection reasons explain which **recorded** changes caused a test to run. They cannot prove that every influence on that test was observed.

## Dependencies outside the application

Riptide doesn't infer dependencies on the current time, randomness, network responses, external services, or other environment state. A test whose result depends on those inputs can change without any recorded application file changing.

It also cannot attribute code executed in a process spawned by a test to the parent test's recorded dependencies.

Keep tests that depend on these inputs in an appropriate full-run stage, make the inputs deterministic when possible, or use a conservative fallback strategy.

## Dynamic Ruby behavior

Some runtime behaviors leave insufficient evidence to safely predict their effect after a change:

- A newly added method that a test previously checked only with `respond_to?` or `try` may not be associated with that probe.
- A class body may register or mutate state on another class. Tests that later read that state through the other class may not be linked to the original class body.
- `defined?(Foo)` and unsuccessful lexical constant reads aren't covered in the same way as `const_get` and `const_defined?` lookups.
- An application constant read only by code inside a gem may not establish an observable application dependency.

Riptide handles many other dynamic cases, including method overrides, class loading, dynamically resolved constants, and SQL table access. Those capabilities don't remove the gaps above.

## Shared state between tests

Riptide records test-class and process setup, but it can't reliably model state one test leaves for a later test, including state changed by an `after_all` hook after a class finishes.

Tests should not depend on the execution order or side effects of unrelated tests. If the suite does, selection can expose assumptions that a full run happened to satisfy.

When tests run concurrently in different threads, Riptide may be unable to attribute their execution to individual tests. It records their outcomes without treating incomplete tracing as a trustworthy dependency history.

## Browser and asset dependencies

A browser may load assets during a system test without the Ruby process observing those reads. Add the relevant asset paths to `fallback_patterns` for suites where asset changes can alter behavior.

For example:

```ruby
Riptide.configure do |c|
  c.fallback_patterns += ["app/assets/**/*", "public/assets/**/*"]
end
```

This is an example, not a universal configuration: choose paths that match how your application builds and serves assets. Changes to fallback files select the full suite.

## Files loaded before tracing starts

Riptide must be configured before the application loads. Code loaded beforehand cannot be traced retroactively. Riptide treats known preloaded application files as whole-file dependencies.

A change to code executed during application boot can select the entire suite. That is intentional: setup behavior may affect tests that never call the changed code themselves.

Files changed on disk after Ruby compiled them cannot safely be attributed to the version that ran. Riptide checks for this and avoids using an untrustworthy recording.

## Missing, failed, and ambiguous runs

Riptide selects tests when it doesn't have a usable passing run. A test with an open failure keeps running until a later build passes it, including when a failure may be flaky or unrelated to a recorded source change.

Tests with the same class-and-method identity cannot have their run histories distinguished reliably, so Riptide selects them rather than treating one test's pass as evidence about another.

If recorded file versions or index data are unavailable or incompatible, more tests may need to execute. Riptide's approach is to fall back toward running more tests rather than inventing confidence in missing history.

## Ruby VM and coverage compatibility

The native tracer is currently written for **CRuby 4.0**. The gem can install on other Rubies, but Riptide stays disabled unless the tracer can be built and used. `RIPTIDE_TRACER=on` attempts an unsupported build; it isn't a compatibility guarantee.

The tracer uses Ruby VM internals and requires headers from the exact Ruby revision used by the runtime. It can retrieve those at install time or use a local tree supplied through `RIPTIDE_RUBY_SOURCE`.

Ruby's one-shot line coverage mode conflicts with the tracing mechanism. When that mode is active, Riptide cannot trust line tracing and disables recording for the process.

If setup or tracing fails, the test suite is intended to continue running in full. Operational failures in the Riptide CLI are reported as warnings instead of failing otherwise valid CI jobs. **Actual test failures must still fail CI** through the test runner's exit status.

## Choose fallbacks deliberately

`fallback_patterns` covers paths that should invalidate the whole suite whenever they change:

```ruby
Riptide.configure do |c|
  c.fallback_patterns += ["config/special_runtime_settings.yml"]
end
```

A fallback is intentionally broad. It trades away some test selection in exchange for covering a dependency Riptide cannot observe.

Avoid assuming that every unknown dependency can be fixed with a filename pattern. Time, network responses, spawned processes, and cross-test state may require changes to the tests or CI workflow instead.

For configuration details see [Configuration](configuration.md). For the internal selection model see [Architecture](architecture.md).
