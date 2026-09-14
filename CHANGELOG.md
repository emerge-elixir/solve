# Changelog

## [Unreleased]

### Fixed
- Reject stale controller-instance updates and out-of-order dependency/lookup snapshots.
- Install filtered and unfiltered collection dependencies atomically, preventing invalid intermediate collections.
- Keep controller subscription failures isolated from the app, with bounded live-target attachment retries.
- Supervise temporary controller children so normal shutdown, partial startup failure, and owner death clean them up.
- Invalidate lookup refs when named apps restart and refresh collection routing after same-value child replacement.
- Prune removed targets, empty subscriber registrations, and expired restart history.
- Use exact collection key/value comparisons, correct nil membership, and validate reorder permutations.
- Derive graph edges from validated bindings and reject inconsistent pre-populated specs.
- Repair `mix quality` environment selection and share checks with CI.

### Changed
- Explicit app dispatch requires `Solve.dispatch/4`; pass `%{}` for no payload. Implicit `/2` and `/3` remain available in controller context.
- Add optional version/routing metadata to update envelopes. Versionless manual updates cannot override managed versioned refs.
- Collection dependencies now receive app-owned snapshots instead of direct child patches; single dependencies and external item updates remain direct.
- Controller initialization defaults to 5,000 ms (`controller_start_timeout` app option); supervised shutdown is bounded to 1,000 ms.
- Warm lookup reads no longer query controller metadata. Manual/helper users should forward owned `:solve_lookup_down` messages or clean up retired refs explicitly.
- Consolidate runtime target state and lifecycle code; build bulk collections and graph queues without quadratic append loops.
- Restore Credo complexity, nesting, repeated-filter, and redundant-with checks. CI covers Elixir 1.18/OTP 27, Elixir 1.19/OTP 28, and Elixir 1.20/OTP 29 with separate caches.

### Added
- `Solve.Collection.new/1` for validated ordered bulk construction.
- `Solve.Lookup.cleanup/0` for retired app cache/monitor cleanup.
- Deterministic audit regression tests and `bench/runtime.exs` for construction, warm lookup, and collection fan-out measurements.

## [0.2.2] - 2026-08-19

- Full readme rewrite
- Allow more collect collection patterns
- Add direct event dispatch to Solve.Lookup

## [0.2.1] - 2026-07-16

### Fixed
- Resubscribe dependent controllers when a dependency controller is replaced after a params change, instead of leaving them attached to the stopped process and missing all further updates. Applies to both singleton dependencies and collection items replaced under the same id.

## [0.2.0] - 2026-04-15

### Added
- Add Solve-style controller `handle_info` fallback for non-Solve messages.
- Allow controller `handle_info` arities from `/2` through `/5`, with access to state, dependencies, callbacks, and init params.
- Document controller `handle_info` usage in the README and module docs.

### Changed
- Keep Solve internal messages reserved from controller-defined `handle_info` clauses.
- Validate controller `handle_info` arity at compile time.

## [0.1.0] - 2026-04-08

### Added
- Initial release.
