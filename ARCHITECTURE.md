# Solve architecture

Solve is a controller-graph runtime built from one coordinating `Solve` process, a set of
controller `GenServer`s, and optional collection sources that materialize ordered child sets.

The `Solve` app process owns graph validation, controller lifecycle, dependency reconciliation,
source- and target-level exposed-state caching, and external subscriber tracking. Controller
instances own their internal state and expose plain-map public views through `expose/3`.

## Core model

### Sources and targets

Solve distinguishes between static source names and concrete runtime targets.

- a source name is an atom such as `:counter` or `:column`
- a singleton source runs at target `:counter`
- a collected child runs at a tuple target like `{:column, 3}`
- a collection source itself is virtual; it does not own a controller pid

The dependency graph is static and source-level. Runtime lifecycle, subscriptions, and dispatch can
operate on either source names or concrete targets.

### Solve app runtime

Each `use Solve` module starts a single app `GenServer` that:

- validates the controller graph on boot
- starts, stops, and replaces singleton targets and collection child targets
- caches the latest exposed state for each source and each running target
- materializes `%Solve.Collection{ids, items}` values for collection sources
- tracks external subscribers per source or target
- reconciles dependents when upstream state, params, or collection membership change

### Controller graph

The app module defines `controllers/0` with `controller!/1` specs. Each spec declares:

- a controller name
- a controller module
- a variant, `:singleton` or `:collection`
- dependency bindings
- params, either as a literal value or a unary function
- for collection sources, a `collect/1` callback returning ordered child ids and params
- optional callbacks passed to event handlers

Inside a `use Solve` module, callback functions can call bare `dispatch/2` or `dispatch/3`.
That implicit app resolution is only guaranteed while a controller event handler is executing.

Solve normalizes dependency bindings into source-level graph edges plus local dependency keys.

Examples:

- `:user`
- `current_user: :user`
- `columns: collection(:column)`
- `visible_columns: collection(:column, fn id, item -> item.visible? end)`

### Controllers

Each concrete controller instance is its own `GenServer` built on `Solve.Controller`. A running
instance owns:

- internal user state
- a cached snapshot of dependency values
- declared event handlers
- an `expose/3` projection for subscribers and dependent controllers

Internal state can be any term. The public exposed state for a running instance must always be a
plain map.

Collection sources are different: Solve materializes them as `%Solve.Collection{ids, items}` from
the exposed state of their child targets. The child controllers themselves are ordinary controllers
and do not know they came from a collection source.

### Exposed state

Solve treats exposed state as the shared boundary between processes.

- subscribers see exposed state, not internal state
- dependent controllers read exposed state from upstream singletons or collected children
- the Solve app caches exposed state to drive reconciliation
- `nil` is reserved to mean a singleton or collected child is off or stopped
- collection sources expose `%Solve.Collection{}` instead of `nil`

### Messages

External update communication uses `%Solve.Message{}` envelopes:

- `%Solve.Message{type: :update, payload: %Solve.Update{...}}`
- `%Solve.Message{type: :dispatch, payload: %Solve.Dispatch{...}}`

Lookup item event refs also expose direct `{pid, {:solve_event, ...}}` tuples for immediate sends.

Internal controller-to-controller dependency updates use `%Solve.DependencyUpdate{}`.

This lets the same controller broadcast turn into:

- an external `%Solve.Message{}` for UI or `Solve.Lookup` subscribers
- a `:replace` dependency patch for single bindings
- `:collection_put`, `:collection_delete`, or `:collection_reorder` patches for collection bindings

## Graph compilation

Graph validation happens on app boot, before any controllers start.

Validation enforces:

- controller names are unique atoms
- controller modules are valid module atoms
- dependency sources reference known controllers
- dependency keys do not repeat
- controllers do not depend on themselves
- collection bindings only point at collection sources
- plain bindings do not point at collection sources
- the graph is acyclic

The compiled graph produces:

- `controller_specs_by_name`
- `sorted_controller_names`
- `dependents_map`

This gives Solve a stable source-level dependency order plus fast direct-dependent lookup.

## Controller lifecycle

On boot, Solve walks the source graph in topological order and reconciles each source.

### Singleton sources

For a singleton source, the runtime:

1. builds a snapshot of dependency values
2. resolves params from dependencies and app params
3. compares new params with previous params
4. keeps stopped, stops, starts, keeps running, or atomically replaces the target

Callback maps do not participate in lifecycle reconciliation. If callbacks change while params stay
equal, Solve keeps the running target and updates its callbacks in place.

Params control existence:

- truthy params mean the target should run
- `nil` or `false` mean the target should be stopped

Replacement is start-new-then-stop-old. The new controller is registered before the old one is
shut down, which avoids a gap in availability.

### Collection sources

For a collection source, the runtime:

1. builds a snapshot of source-level dependency values
2. resolves collection params from dependencies and app params
3. runs `collect/1` to produce ordered `{id, opts}` tuples
4. diffs ids against the current materialized collection
5. starts, stops, or replaces child targets like `{:column, id}`
6. rebuilds `%Solve.Collection{ids, items}` from the child exposed state

`collect/1` is responsible for order. Solve preserves that order in `collection.ids`.
Collected child replacement is params-based for a given `id`. If only collected callbacks change,
Solve keeps the existing child pid and updates its callbacks in place.

## Dependency propagation

### Direct encoded subscriptions

Controllers subscribe directly to their upstream dependencies when they start.

Binding kinds matter:

- a single binding stores one map or `nil` under its local dependency key
- an unfiltered collection binding stores a `%Solve.Collection{}` and subscribes to all child
  targets in the source collection
- a filtered collection binding stores a `%Solve.Collection{}` and subscribes only to child
  targets whose current `{id, item}` match the filter

Controllers still broadcast directly. Subscribers now carry encoder functions, so a broadcast can
be transformed before delivery.

Examples:

- single binding encoder -> `%Solve.DependencyUpdate{op: :replace, ...}`
- collection binding encoder -> `%Solve.DependencyUpdate{op: :collection_put, ...}`
- filtered collection binding encoder -> either `:collection_put` or `:collection_delete`

### Solve app responsibilities

The Solve app also subscribes to every running singleton and collected child. That lets it:

- refresh its target-level cache
- materialize source-level `%Solve.Collection{}` values
- decide whether direct dependents should start, stop, stay running, or be replaced
- add or remove dependency subscriptions when collection membership or filters change

This keeps state propagation direct while leaving lifecycle decisions with the app process.

## External interaction APIs

### `Solve.subscribe/3`

`Solve.subscribe(app, target_or_source, subscriber)`:

- records the subscriber at the app level
- monitors the subscriber process
- subscribes it directly to the concrete controller if that target is running
- returns the current raw exposed state, `%Solve.Collection{}`, or `nil`

Examples:

- `Solve.subscribe(app, :counter)` -> `%{...}` or `nil`
- `Solve.subscribe(app, :column)` -> `%Solve.Collection{...}`
- `Solve.subscribe(app, {:column, 3})` -> `%{...}` or `nil`

### `Solve.dispatch/4`

`Solve.dispatch(app, target, event, payload)` routes an event through the Solve app using the
current controller pid for that target.

- if the target is running, the event is forwarded to it
- if the target is stopped, unknown, or a collection source atom, dispatch is a silent no-op

### Introspection helpers

Solve also exposes:

- `Solve.controller_pid/2` to read the current pid for a singleton or collected child target
- `Solve.controller_events/2` to read the declared event names for a singleton, collection source,
  or collected child target
- `Solve.controller_variant/2` to read whether a source is `:singleton` or `:collection`

## Solve.Lookup

`Solve.Lookup` is a process-local wrapper and cache around `Solve.subscribe/3`
and `Solve.dispatch/4`.

The README covers the most common public usage patterns, including UI code and
ordinary long-running processes.

It stores three lookup shapes:

- singleton item lookups via `solve(app, :counter)`
- collected child item lookups via `solve(app, {:column, 1})`
- collection source lookups via `collection(app, :column)`

Item lookups are augmented with `:events_` direct event tuples. Collection lookups return
`%Solve.Collection{}` whose items are augmented item maps. The collection wrapper itself has no
events.

`handle_message/1` refreshes the local cache and returns updates grouped by app as
`%Solve.Lookup.Updated{refs, collections}`.

### Auto mode

`use Solve.Lookup` defaults to `handle_info: :auto`.

Injected `handle_info/2` clauses:

- ignore `nil`
- consume `%Solve.Message{}` envelopes
- refresh the local cache through `handle_message/1`
- call `handle_solve_updated/2` with `%Solve.Lookup.Updated{refs, collections}`

### Manual mode

With `handle_info: :manual`, no `handle_info/2` clauses are injected. The caller matches
`%Solve.Message{}` itself, calls `handle_message/1`, and decides what to do with the returned map
of updated refs and collections.

## Message shapes

Singleton or child updates use `%Solve.Update{}`:

```elixir
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: app,
    controller_name: :counter,
    exposed_state: %{count: 1}
  }
}

%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: app,
    controller_name: {:column, 1},
    exposed_state: %{id: 1, title: "Todo"}
  }
}
```

Collection source updates use the same envelope with a collection payload:

```elixir
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: app,
    controller_name: :column,
    exposed_state: %Solve.Collection{ids: [1], items: %{1 => %{id: 1, title: "Todo"}}}
  }
}
```

Deferred event dispatch still uses `%Solve.Dispatch{}` and can target either a singleton or a
collected child target.

## Invariants

The runtime depends on a few fixed rules:

- the source graph must be valid before runtime starts
- singleton sources map to at most one active target pid
- collection sources map to zero or more active child target pids
- running controller instances must expose plain non-struct maps
- `nil` means a singleton or collected child is off or stopped
- collection source values are always `%Solve.Collection{}`
- `:events_` is reserved for `Solve.Lookup` augmentation
- downstream controllers only see upstream exposed state, never upstream internal state
- dispatch to unknown or stopped targets is a no-op
- undeclared controller events are logged and discarded

## Typical flows

### Boot

1. Solve validates and compiles the source graph.
2. Solve reconciles sources in dependency order.
3. Running targets subscribe to their dependency targets.
4. Solve subscribes to each running target and caches both target and source exposed state.

### Event dispatch

1. A process either calls `Solve.dispatch/4`, sends a deferred dispatch envelope, or sends a direct
   `{pid, {:solve_event, ...}}` tuple produced by `Solve.Lookup`.
2. The event reaches the current singleton or collected-child controller.
3. The controller updates internal state and recomputes `expose/3`.
4. If the exposed map changed, the controller broadcasts an update envelope.

### Upstream state change

1. An upstream singleton or collected child broadcasts a new exposed map.
2. Dependent controllers receive the encoded dependency update directly.
3. The Solve app refreshes its target cache and, if needed, its source `%Solve.Collection{}`.
4. Solve reconciles direct dependents to decide whether to keep, stop, start, replace, attach, or detach subscriptions.

### Collection reconcile

1. A collection source re-runs `collect/1` because its upstream state changed.
2. Solve diffs ordered ids against the existing materialized collection.
3. Solve starts, stops, or replaces child targets like `{:column, id}`.
4. Solve rebuilds the source `%Solve.Collection{}` and notifies external collection subscribers.
5. Solve reevaluates collection bindings in dependents and adds or removes child subscriptions.

### Crash and restart

1. A controller target exits unexpectedly.
2. Solve marks that target stopped and notifies external subscribers with an update carrying `nil`.
3. If the target belonged to a collection source, Solve removes it from the materialized collection.
4. Solve reconciles dependents against the new state.
5. Solve attempts restart within a bounded retry budget.
6. If the restart budget is exhausted, the Solve app stops.

For public usage examples, see `README.md`.
