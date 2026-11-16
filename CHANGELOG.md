## [Unreleased]

- Rebuilt around recorded runs keyed by git blob sha, with selection against the working tree instead of a diff base
- A selection says how many tests each kind of change selected, and whether a change reached them through their own runs, their test class's setup or the process's setup, with the biggest causes of each. The plan says it per test
- A tracer that sees classes load, so load-time code belongs to the classes it ran for
- A class body left without reaching its end, through an error, a `throw` or its thread dying, stops counting as loading once its frame is gone
- The tracer hooks the VM's trace instructions in app code only, so YJIT keeps everything it compiled, and each line costs a test one hit however often it runs
- A line another tool aims a TracePoint at, like a debugger breakpoint, stays traced, so the breakpoint hears every run
- Changes are analyzed by what changed: methods and blocks as a whole, constants, declarations, tables and whole files
- A method in a concern's `class_methods` block counts as one of its ClassMethods, so a new one that could take over a class method selects the tests of every class that includes the concern
- A new method in a concern's `included` or `prepended` block selects the tests of every class that includes it, since it lands ahead of what that class defined before including it
- A class header counts as the class's declaration through the end of its superclass, so editing a `Struct.new(` that wraps onto more lines selects the class's tests
- A sequence in `structure.sql` changes the tables that own it or take their ids from it, so adding a table no longer reruns every test that touched the database
- A foreign key in `structure.sql` changes the table it points at too, so tests that touched that table get selected
- Tables are recorded on the schema and fixture files even when `source_patterns` leaves them out
- A fixture file added, deleted or moved to another model selects the tests that touched the tables it fills or used to
- Reordering methods selects nothing unless one moves past a class-level line like `private`
- Every git call runs under a deadline, including the blob reader and the diffs
- Tests depend on what ran before them outside any test: boot, a parallel worker's setup, and their own class's setup, like a `before_all`, but not its `after_all`
- Tests depend on the classes they called methods on, looked up by name, or read constants from, plus the directories they listed and the files they checked for
- File reads and checks count however they happen, including through Pathname, FileTest, `Dir.exist?`, `Kernel#open` and `IO.copy_stream`, and a size check counts as reading the file
- Only files git knows about are recorded, and only versions from the checked-out commit are pushed
- Runs are stored in git as a sharded index, one unit per suite and branch or pull request, with `riptide fetch` and `riptide publish`
- The app can sit in a subdirectory of its repository
- Tests that share a name, like specs with the same describe and it text, always run
- Failures stay open until a later build passes the test, and a publish that fails keeps the logs for the next one
- `riptide publish --retained-runs` sets how many runs each test keeps
- Installing builds the tracer against Ruby's source at the running Ruby's revision, downloaded from GitHub or read from `RIPTIDE_RUBY_SOURCE`, which doesn't have to be built
- A Ruby missing a function the tracer calls leaves riptide off instead of crashing the test process
- `RIPTIDE_TRACER=on` builds the tracer on a Ruby it isn't written for yet, and `RIPTIDE_TRACER=off` builds without it
- Deleting a test file drops its runs and open failures
- Main and release branches harvest the pull requests that landed, found with `git merge-tree`, and delete their units, along with any idle for 30 days
- The plugin only activates after `Riptide.configure`
- Needs Minitest 5.26.1 or later, the first that installs on Ruby 4, and is tested on it and the newest Minitest 5 and 6

## [0.1.0] - 2026-09-16

- Initial release
