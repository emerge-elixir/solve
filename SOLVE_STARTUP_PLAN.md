# Solve Startup Plan

This document captures the current implementation plan for controller startup and
lifecycle management inside `Solve`.

It is based on the current `Solve.Controller` contract and intentionally does not
try to preserve older markdown design docs.

## Goals

- Make `Solve` the controller lifecycle manager.
- Keep `Solve.Controller` responsible only for a single controller process
  lifetime.
- Evaluate controller params inside `Solve`.
- Support start, stop, restart, and atomic replacement of controllers.
- Keep controller-to-controller updates using `%Solve.Message{}` envelopes with
  `%Solve.Update{}` payloads.

## Solve State

`Solve` should keep:

- `controller_specs_by_name`
- `sorted_controller_names`
- `dependents_map`
- `app_params`
- `controller_pids_by_name`
- `controller_name_by_pid`
- `controller_exposed_state_by_name`
- `controller_params_by_name`
- `controller_status_by_name`
- `restart_timestamps_by_name`
- `planned_stop_pids`

The `Solve` pid itself is the `solve_app` identity passed to controllers.

## Init Flow

In `Solve.init_runtime/2`:

1. Call `Process.flag(:trap_exit, true)`.
2. Resolve the controller graph with `DependencyGraph.resolve_module!/1`.
3. Initialize empty runtime maps.
4. Run a full reconcile pass in topological order.

## Params Resolution

Each controller spec params function receives:

```elixir
%{dependencies: deps, app_params: app_params}
```

Rules:

- If `params` is an arity-1 function, evaluate it with that map.
- Otherwise treat `params` as a literal value.
- Dependencies snapshot always includes every declared dependency key.
- Stopped dependencies appear as `nil`.

## Controller Lifecycle Table

For each controller, compare previous params to current params:

| Prev Params | Current Params | Prev == Current | Action |
| --- | --- | --- | --- |
| falsy | falsy | - | Do nothing; controller stays stopped |
| truthy | falsy | - | Stop current controller with `:normal` |
| falsy | truthy | - | Start new controller |
| truthy | truthy | false | Atomically replace controller |
| truthy | truthy | true | Keep current controller |

Notes:

- `truthy -> falsy` produces a `nil` dependency state for descendants.
- `truthy -> truthy` with changed params must not create a `nil` outage for
  descendants.
- If exposed state stays the same after atomic replacement, downstream behavior
  can naturally no-op; no special handling is required.

## Starting a Controller

To start a controller:

1. Build `dependencies_snapshot` from `controller_exposed_state_by_name`.
2. Resolve params from `%{dependencies: deps, app_params: app_params}`.
3. Normalize callbacks to a map.
4. Start the controller with:

```elixir
solve_app: self()
controller_name: name
params: resolved_params
dependencies: dependencies_snapshot
callbacks: callbacks
```

5. Subscribe the new controller to each started dependency using
   `Solve.Controller.subscribe(dependency_pid, controller_pid)`.
6. If the returned dependency snapshot differs from the startup snapshot, send:

```elixir
Solve.Message.update(self(), dependency_name, exposed_state)
```

   to the newly started controller.
7. Subscribe `Solve` itself to the new controller with
   `Solve.Controller.subscribe(controller_pid, self())`.
8. Store pid, params, status, and current exposed state in `Solve` state.

## Stopping a Controller

Planned stops use:

```elixir
GenServer.stop(pid, :normal)
```

When `Solve` intentionally stops a controller:

- record the pid in `planned_stop_pids`
- clear pid/name mappings
- set exposed state to `nil`
- set status to `:stopped`
- keep params cache aligned with the newly evaluated value
- send synthetic `Solve.Message.update(solve_app, controller_name, nil)` to currently
  running direct dependents

Planned `:normal` stops do not count toward restart budget.

## Atomic Replacement

For `truthy -> truthy` with changed params:

1. Start the replacement controller first using new params and current
   dependency snapshot.
2. Subscribe it to started dependencies.
3. Subscribe `Solve` to it and capture its current exposed state.
4. Swap `Solve` runtime maps from old pid to new pid.
5. Subscribe currently running direct dependents to the new pid.
6. Send one synthetic `Solve.Message.update(solve_app, controller_name,
   new_exposed_state)` to direct dependents.
7. Stop the old controller with `:normal`.
8. Reconcile descendants.

This path must not publish an intermediate `nil` state for the replaced
controller.

## Update Handling

`Solve` handles:

```elixir
%Solve.Message{type: :update, payload: %Solve.Update{app: solve_app, controller_name: controller_name, exposed_state: exposed_state}}
```

When the update belongs to the current `Solve` instance:

- update `controller_exposed_state_by_name[controller_name]`
- reconcile descendants of `controller_name`

Normal dependency refresh inside already-running controllers is still handled by
their direct controller-to-controller subscriptions.

## Why Solve Sends Synthetic Updates

Direct dependents cache dependency state inside `Solve.Controller`.

During stop, start, restart, or replacement, `Solve` must send direct dependents
the relevant state transition itself:

- `nil` when a dependency stops or crashes
- current exposed state when a dependency starts, restarts, or is atomically
  replaced

Deeper descendants then update through normal controller-to-controller
propagation.

## Crash Handling

Controllers should not bring down `Solve` immediately.

If a controller exits abnormally:

1. Mark it stopped internally.
2. Set its exposed state to `nil`.
3. Send synthetic nil updates to running direct dependents.
4. Reconcile descendants.
5. Try to restart the controller with freshly evaluated params.

Restart budget:

- maximum `3` abnormal exits
- within `5_000` milliseconds
- tracked per controller

If the restart budget is exceeded, stop `Solve` with:

```elixir
{:controller_restart_limit_exceeded, controller_name, reason}
```

## Public Solve API

Add:

- `Solve.subscribe(app, controller_name, subscriber \\ self())`
- `Solve.controller_pid(app, controller_name)`
- `Solve.dispatch(app, controller_name, event, payload \\ %{})`

`Solve.subscribe/3` behavior:

- running controller -> delegate to `Solve.Controller.subscribe/2`
- stopped controller -> return `nil`

`Solve.dispatch/4` behavior:

- running controller -> forward to `Solve.Controller.dispatch/3`
- stopped or unknown controller -> silent no-op
- this is the default public dispatch API; callers should not need controller pids

## Supporting Changes

Update `Solve.ControllerSpec` defaults:

- `callbacks: %{}`
- default params function accepts `%{dependencies: _, app_params: _}`

Update `Solve.Lookup` to delegate to the real `Solve.subscribe/3`.

## Suggested Helper Functions In Solve

- `build_runtime_state/2`
- `reconcile_all/1`
- `reconcile_descendants/2`
- `reconcile_controller/2`
- `build_dependency_snapshot/2`
- `resolve_controller_params/3`
- `start_controller/4`
- `stop_controller_normal/2`
- `atomic_replace_controller/4`
- `mark_controller_stopped/3`
- `send_direct_dependency_update/4`
- `record_restart_attempt/3`
- `restart_budget_exceeded?/2`

## Test Plan

Add Solve integration tests for:

- topological startup order
- params context shape `%{dependencies: ..., app_params: ...}`
- all five lifecycle transitions
- stopped dependencies appearing as `nil`
- truthy-to-truthy changed params with no nil outage
- abnormal crash restart within budget
- fourth crash within five seconds stopping `Solve`
- `Solve.subscribe/3` returning current exposed state or `nil`
