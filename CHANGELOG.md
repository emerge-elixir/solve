# Changelog

## Unreleased

### Added
- Optional controller `deps_changed/3` lifecycle callback for stateful dependency computation. It runs after initialization and accepted dependency-value changes, and its returned user state is stored before exposure. Duplicate, stale and equal-valued updates do not rerun the hook; existing controllers retain identity behaviour by default.

### Changed
- Reserve `:deps_changed` from declared controller events; it names the new lifecycle callback.
- Skip hook invocation, context setup and binding-value comparison for controllers without a `deps_changed/3` override.
- Make already-owned, connected Lookup reads read-only while preserving local resolution and remote recovery/ownership semantics.
- Reuse deterministic dependency projections within reconciliation and avoid filters for literal inactive params. Ordinary collection child revisions update one item without rebuilding membership/order/routes.
- Enumerate collections incrementally, construct common broadcast snapshots once, and remove dead controller subscribers in one pass.

### Fixed
- Bound failed dependency attachment work to one fenced retry chain per target (initial attempt plus three retry rounds), preserving healthy bindings and preventing unrelated reconciliation from resetting the budget.

## [0.3.2] - 2026-11-04

### Fixed
- Deliver fixed arguments and appended event payloads together as `{argument, payload}`. Existing two- and three-field messages keep their behavior; four-field messages now use declared event handlers instead of controller `handle_info`.
- Accept bindings with fixed arguments in `Solve.Lookup.dispatch/2`, and direct event tuples with appended payloads in `dispatch/1`.

## [0.3.1] - 2026-09-29

### Added
- `use Solve` now generates an overridable `child_spec/1`, allowing apps to be added directly to supervision trees as permanent workers.
- Default child IDs include the app module and configured name, allowing differently named instances of the same app under one supervisor.

## [0.3.0] - 2026-09-27

### Added
- Automatically restore Lookup subscriptions after outages and named app restarts, using owner-scoped watching and capped exponential backoff.
- `Solve.Lookup.status/1` to read cached connection status and the optional `handle_solve_connection_changed/3` callback for lifecycle-aware consumers.
- Configurable finite cold-acquisition timeouts and recovery backoff through `:lookup_timeout` and `:lookup_recovery`.

### Changed
- Warm remote Lookup reads, pushed updates, and cleanup no longer make synchronous liveness or name-resolution RPCs; they use owned process monitors instead.
- Remote names stay pinned to their acquired app until invalidation and reacquisition.
- Lookup retains subscription intent across outages. `Solve.Lookup.unsubscribe/1,2` cancels pending recovery as well as active subscriptions; cleanup and raw unsubscribe do not cancel recovery intent.
- **Migration:** Manual and helper-mode consumers must forward owned DOWN messages and private `{:solve_lookup, kind, payload}` recovery messages to `Solve.Lookup.handle_message/1`. Auto mode handles these messages automatically. See [manual message handling](ARCHITECTURE.md#auto-manual-and-helper-modes).
- Refresh development dependencies and Elixir/OTP and CI tooling while retaining Elixir 1.18 support.

### Fixed
- Correct global atom-key name classification.
- Fence recovery and cancellation races so stale work cannot restore canceled subscriptions.
- Notify data consumers after fresh snapshots and event routes are installed, even when recovered values are unchanged.

## [0.2.3] - 2026-09-14

### Added
- `Solve.unsubscribe/2` and `/3` to stop receiving raw updates without stopping the controller.
- `Solve.Lookup.unsubscribe/1` and `/2` to release a process-local lookup subscription and its cached value. A later lookup subscribes again.
- `Solve.Collection.new/1` to build an ordered collection from `{id, value}` pairs.
- `Solve.Lookup.cleanup/0` to clear cached data for app instances that have stopped.

### Changed
- **Breaking:** Explicit app dispatch requires `Solve.dispatch(app, target, event, payload)`. Pass `%{}` when no payload is needed; implicit `/2` and `/3` remain available in controller context.
- **Breaking:** Acquire lookup targets through `solve` or `collection` before forwarding updates. `Solve.Lookup.handle_message/1` no longer creates subscriptions or seeds the cache from unsolicited or versionless updates. Forward complete runtime envelopes rather than rebuilding them from values.
- Controller startup now times out after five seconds by default. Set the app's `:controller_start_timeout` option for slower initialization.
- Reduce overhead of repeated cached lookup reads.

### Fixed
- Refresh lookup values and event handlers correctly after controller replacement or app restart.
- Keep collection dependencies consistent during item changes, reordering, and replacement.
- Correct collection handling of nil values and distinct numeric keys such as `1` and `1.0`; reject invalid reorder operations.
- Avoid restarting slow controllers when a subscription times out.
- Clean up controller processes when their app stops or initialization fails.
- Reject invalid controller dependency definitions with clearer errors.

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
