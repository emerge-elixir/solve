# Changelog
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
