## [Unreleased]

- Rebuilt around recorded runs keyed by git blob sha, with selection against the working tree instead of a diff base
- A tracer that sees classes load, so load-time code belongs to the classes it ran for
- Changes are analyzed by what changed: methods and blocks as a whole, constants, declarations, tables and whole files
- Tests depend on the classes they called methods on, looked up by name, or read constants from, plus the directories they listed and the files they checked for
- Only files git knows about are recorded, and only versions from the checked-out commit are pushed
- Runs are stored in git as a sharded index, one unit per suite and branch or pull request, with `riptide fetch` and `riptide publish`
- Failures stay open until a later build passes the test
- Main and release branches harvest the pull requests that landed, found with `git merge-tree`, and delete their units, along with any idle for 30 days
- The plugin only activates after `Riptide.configure`

## [0.1.0] - 2026-09-16

- Initial release
