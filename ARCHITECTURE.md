# Solve Architecture

Solve is a controller-graph runtime built from one coordinating `Solve` process and a set of
controller `GenServer`s.

The `Solve` app process owns graph validation, controller lifecycle, dependent reconciliation,
exposed-state caching, and external subscriber tracking. Each controller owns its internal state
and exposes a plain-map public view derived from `expose/3`. Most application processes interact
through `Solve.subscribe/3`, `Solve.dispatch/4`, or the process-local `Solve.Lookup` facade.

## Core Model

### Solve App Runtime

Each `use Solve` module starts a single app `GenServer` that:

- validates the controller graph
- starts, stops, and replaces controllers
- caches the latest exposed state for each controller
- tracks external subscribers per controller name
- reconciles dependents when upstream state or params change

### Controller Graph

The app module defines `controllers/0` with `controller!/1` specs. Each spec declares:

- a controller name
- a controller module
- zero or more controller dependencies
- params, either as a literal value or a unary function
- optional callbacks passed to event handlers

At compile time and boot time, Solve validates the graph and compiles it into:

- `controller_specs_by_name`
- `sorted_controller_names`
- `dependents_map`

This gives the runtime a stable dependency order plus fast dependent lookup.

### Controllers

Each controller is its own `GenServer` built on `Solve.Controller`. A controller owns:

- internal user state
- a cached snapshot of dependency exposed state
- declared event handlers
- an `expose/3` projection for subscribers and dependent controllers

Internal state can be any term. The public exposed state must always be a plain map while the
controller is running.

### Exposed State

Solve treats exposed state as the shared boundary between processes.

- subscribers see exposed state, not internal state
- dependent controllers read exposed state from upstream controllers
- the Solve app caches exposed state to drive reconciliation
- `nil` is reserved to mean a controller is off or stopped

### Messages

Cross-process communication uses `%Solve.Message{}` envelopes:

- `%Solve.Message{type: :update, payload: %Solve.Update{...}}` propagates exposed-state changes
- `%Solve.Message{type: :dispatch, payload: %Solve.Dispatch{...}}` carries deferred event dispatch

### Solve.Lookup

`Solve.Lookup` is a process-local facade on top of `Solve.subscribe/3` and `Solve.dispatch/4`.
It caches controller views in the process dictionary and augments those views with `:events_`
dispatch refs for ergonomic event sending.

## Runtime Topology

```text
External process
    |
    | solve/2, events/1, handle_message/1
    v
Solve.Lookup (process-local cache)
    |
    | subscribe/dispatch by controller name
    v
Solve app (GenServer)
    |
    | start/stop/replace/reconcile controllers
    v
Controllers (one GenServer per running controller)
    |
    | direct %Solve.Message{type: :update, ...}
    +--> dependent controllers
    +--> external subscribers
    +--> Solve app
```

The Solve app is the coordinator. Controllers still communicate state changes directly to their
subscribers, including dependent controllers and external processes.

## Controller Graph Compilation

When a module uses `Solve`, graph validation happens in two places:

1. after compile, so invalid graphs fail early during development
2. on app boot, before any controllers start

Validation enforces:

- controller names are unique atoms
- controller modules are valid module atoms
- dependencies reference known controllers
- dependencies do not repeat
- controllers do not depend on themselves
- the graph is acyclic

The compiled graph gives Solve a topological start order and a reverse map of direct dependents.

## Controller Lifecycle

On boot, Solve walks the graph in topological order and reconciles each controller.

For each controller, the runtime:

1. builds a snapshot of dependency exposed state
2. resolves controller params from dependencies and app params
3. compares the new params with the previous params
4. chooses the next lifecycle action

Possible outcomes are:

- keep stopped
- stop the current controller
- start a new controller
- keep the current controller
- atomically replace the current controller with a new one

Params control whether a controller should exist at all:

- truthy params mean the controller should be running
- `nil` or `false` mean the controller should be stopped

Replacement is start-new-then-stop-old. The new controller is started and registered before the
old one is shut down, which avoids a gap in controller availability.

External subscribers are tracked at the app level, so a subscriber can express interest in a
controller even while that controller is stopped. When the controller later starts or is replaced,
Solve re-attaches those subscribers and sends them an update.

## State Propagation

### Event Handling Inside a Controller

Event handlers run with the full runtime context:

```elixir
event_name(payload, state, dependencies, callbacks, init_params)
```

After an event handler returns a new internal state, the controller recomputes `expose/3`.
If the exposed map changed, the controller broadcasts an update envelope to all subscribers.

### Dependency Updates

Controllers subscribe directly to their upstream dependencies when they start. When an upstream
controller broadcasts an update, dependent controllers receive the new exposed state directly and
recompute their own `expose/3` projection.

The Solve app also subscribes to every running controller. That lets it:

- refresh its exposed-state cache
- decide whether direct dependents should start, stop, stay running, or be replaced
- synchronize kept dependents when dependency process relationships change

This split keeps state propagation direct while still letting the app process stay in control of
lifecycle decisions.

## External Interaction APIs

### `Solve.subscribe/3`

`Solve.subscribe(app, controller_name, subscriber)`:

- records the subscriber at the app level
- monitors the subscriber process
- subscribes it directly to the controller if the controller is running
- returns the current raw exposed state or `nil`

### `Solve.dispatch/4`

`Solve.dispatch(app, controller_name, event, payload)` routes an event through the Solve app using
the current controller pid for that name.

- if the controller is running, the event is forwarded to it
- if the controller is stopped or unknown, dispatch is a silent no-op

This keeps callers aligned with controller replacement and restart behavior.

### Introspection Helpers

Solve also exposes:

- `Solve.controller_pid/2` to read the current pid for a controller
- `Solve.controller_events/2` to read the declared event names for a controller

## Solve.Lookup

`Solve.Lookup` gives a process-local view of controller state.

On the first `solve(app, controller_name)` call in a process, it:

1. subscribes the current process through `Solve.subscribe/3`
2. stores a private lookup ref in the process dictionary
3. returns the exposed map augmented with `:events_`

Later `solve/2` calls in the same process read from that local cache.

Example shape:

```elixir
%{
  count: 2,
  events_: %{
    increment: %Solve.Message{type: :dispatch, payload: %Solve.Dispatch{...}}
  }
}
```

`events/1` reads the nested dispatch refs safely. A caller can send one of those refs to its own
process and let `handle_message/1` route it back through `Solve.dispatch/4`.

### Auto Mode

`use Solve.Lookup` defaults to `handle_info: :auto`.

In this mode, injected `handle_info/2` clauses:

- ignore `nil`
- consume `%Solve.Message{}` envelopes
- refresh the local cache through `handle_message/1`
- call `handle_solve_updated/2` when relevant controller updates were observed

### Manual Mode

With `handle_info: :manual`, no `handle_info/2` clauses are injected. The caller matches
`%Solve.Message{}` itself, calls `handle_message/1`, and decides what to do with the returned map
of updated controllers.

## Message Shapes

Update envelopes carry state changes:

```elixir
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: app,
    controller_name: :counter,
    exposed_state: %{count: 1}
  }
}
```

Dispatch envelopes carry deferred event sends:

```elixir
%Solve.Message{
  type: :dispatch,
  payload: %Solve.Dispatch{
    app: app,
    controller_name: :counter,
    event: :increment,
    payload: %{}
  }
}
```

In practice:

- controllers send update envelopes to subscribers
- `Solve.Lookup` builds dispatch envelopes for local event sending
- `handle_message/1` is the bridge that consumes those envelopes in user processes

## Invariants

The runtime depends on a few fixed rules:

- the controller graph must be valid before runtime starts
- a controller name maps to at most one active controller pid
- running controllers must expose plain non-struct maps
- `nil` means the controller is off or stopped
- `:events_` is reserved for `Solve.Lookup` augmentation
- downstream controllers only see upstream exposed state, never upstream internal state
- dispatch to unknown or stopped controllers is a no-op
- undeclared controller events are logged and discarded

## Typical Flows

### Boot

1. Solve validates and compiles the controller graph.
2. Solve reconciles controllers in dependency order.
3. Running controllers subscribe to their dependencies.
4. Solve subscribes to each running controller and caches its exposed state.

### Event Dispatch

1. A process calls `Solve.dispatch/4` or sends a dispatch envelope produced by `Solve.Lookup`.
2. Solve resolves the current controller pid and forwards the event.
3. The controller updates internal state and recomputes `expose/3`.
4. If the exposed map changed, the controller broadcasts an update envelope.

### Upstream State Change

1. An upstream controller broadcasts a new exposed map.
2. Dependent controllers receive the update directly.
3. The Solve app refreshes its cache for the source controller.
4. Solve reconciles direct dependents to decide whether to keep, stop, start, or replace them.

### Crash And Restart

1. A controller exits unexpectedly.
2. Solve marks it stopped and notifies external subscribers with an update carrying `nil`.
3. Solve reconciles dependents against the new stopped state.
4. Solve attempts restart within a bounded retry budget.
5. If the restart budget is exhausted, the Solve app stops.

For public usage examples, see `README.md` and `examples/counter_lookup_example.md`.
