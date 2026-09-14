# Solve architecture

Solve runs a static controller graph using a coordinating app GenServer, an app-owned
`DynamicSupervisor`, and one GenServer per running controller. `Solve` contains the public API
and generated app callbacks; `lib/solve/runtime.ex` owns reconciliation and lifecycle implementation.

## Sources, targets, and state ownership

- A **source** is a declared atom, such as `:counter` or `:column`.
- A singleton source runs at its own atom target.
- A collection source is virtual. Its concrete children run at targets such as `{:column, 3}`.
- The graph is source-level and static; collection IDs and controller instances are dynamic.

The runtime keeps one record per running target: PID, monitor, params, callbacks, latest
versioned exposed snapshot, and singleton dependency subscription refs. Removed collection
targets are deleted rather than retained as stopped records.

Source-level state holds materialized collection snapshots and singleton stopped snapshots.
A live singleton's authoritative value comes from its target record. Graph metadata and declared
events are compiled/cached at startup. External subscription registrations and recent restart
history are separate from target existence.

Controllers own user state, dependency values/versions, callbacks, and subscriber monitors. User
state can be any term. A running controller's `expose/3` must return a plain map. `nil` means an
item target is off; a collection source always exposes `%Solve.Collection{ids, items}`.

## Graph compilation

`controllers/0` returns `controller!/1` specifications. Dependencies can be plain, aliased,
or collection bindings:

```elixir
:user
current_user: :user
columns: collection(:column)
visible_columns: collection(:column, fn _id, item -> item.visible? end)
```

Validation produces canonical bindings and derives source edges from them. Pre-populated
bindings cannot hide self-dependencies, unknown sources, or cycles; conflicting supplied source
lists are rejected. Revalidating a normalized spec preserves its graph.

Compilation verifies unique atom names and binding keys, module atoms, params/collect/callback
shapes, binding/source variants, known references, and acyclicity. A queue-based topological
sort produces startup order. Direct-dependent lists are preordered once for reconciliation.

## Versions and message ordering

Runtime item updates carry optional public `%Solve.Update{}` metadata:

- `app`: the concrete app-instance PID
- `controller_name` and `exposed_state`: the existing public payload
- `version`: `{generation, revision}`
- `pid`, `events`, `kind`, and `routes`: routing/lookup metadata

An app-wide monotonically increasing counter allocates item generations on start, replacement,
and stop. Generations are not reused when a collection ID is removed and recreated. Each
controller increments its revision on an exact (`!==`) exposed-value change. A subscription
handshake returns value, routing metadata, and version together.

The app accepts item updates only from the current target PID/generation with a newer revision.
Singleton dependents and lookup refs reject obsolete generations, duplicate revisions, and
older subscription snapshots. Nil/stopped notifications have a newer generation, so delayed
messages cannot resurrect a retired instance.

Collection sources have their own monotonically increasing revisions within generation zero.
Membership, exact value changes, order changes, and child routing changes advance that revision.
Even a same-value child replacement refreshes collection lookup event refs.

The public `Message.update/3` and `Update.new/3` constructors still create versionless envelopes.
Standalone/manual usage remains supported, but versionless messages cannot override an existing
versioned lookup ref or update app-managed controller dependencies. Runtime-to-app updates must
identify the current managed instance.

Versions establish ordering per target/binding, not a transaction across the whole graph.
The graph remains eventually consistent; independent upstream events can expose intermediate
but valid snapshots.

## Lifecycle and failure handling

On startup the app reconciles sources in topological order. Params determine existence:

- nil/false -> stopped
- truthy -> running
- changed truthy params -> replacement
- equal params -> retain the PID and reconcile dependencies

Callback-only changes update the existing process; they do not restart it. Replacement starts
and registers the new instance before shutting down the old one. Both remain supervisor-owned
until the old instance exits.

Collection `collect/1` returns ordered `{id, params}` or `{id, [params: ..., callbacks: ...]}`
entries. IDs must be unique under exact key identity. Falsy child params leave that child off.
The materialized collection contains only running children, in collect order. Per-child callbacks
are merged with the source's callbacks.

Every controller is a **temporary** child of the app-owned `DynamicSupervisor`. Only the app
chooses restarts and charges its retry budget; there is no competing supervisor restart loop.
Target monitors drive failure handling. Planned removals retire/demonitor the old record so a
late DOWN cannot charge a second failure.

On a crash, the app publishes the stopped value, reconciles dependents, then retries the source.
More than three failures for a target within five seconds stops the app. Startup failures use
the same budget. Recent history survives removal/recreation within the window; a timer prunes
expired history even while idle.

Controller initialization defaults to a 5,000 ms timeout. Apps may set a positive
`controller_start_timeout` option. Controller shutdown is bounded at 1,000 ms before supervisor
forced termination. Normal app stop awaits supervisor shutdown; abnormal/forced owner death and
failed initialization also release owned children. The startup timeout bounds a supervisor
waiting for a child's initialization acknowledgement.

## Dependency propagation

### Single bindings: direct versioned updates

A dependent subscribes directly to its running singleton source. The initial handshake and
later `%Solve.DependencyUpdate{op: :replace}` messages carry a complete value and version.
The dependent atomically replaces that binding and recomputes exposure only for newer versions.
On source replacement, the app reattaches the dependent; on stop it sends a versioned nil value.
Failed attachment attempts are retried a bounded number of times.

### Collection bindings: app-owned atomic snapshots

The app already observes each collection child for lifecycle decisions. Accepted child updates
rebuild the collection source. Filtered and unfiltered dependency values are derived exclusively
from that accepted source snapshot and sent as versioned `:replace` dependency messages.

The dependent installs the whole collection before running `expose/3`. It never sees membership,
items, and order from different revisions. There are no runtime direct child-to-dependent
collection subscriptions or separate runtime reorder patches.

This intentionally favors one writer and valid intermediate state over the previous multi-writer
patch mechanism. Full snapshot copying costs grow with collection size and fan-out; measure them
with `mix run bench/runtime.exs`. Any future incremental optimization must retain one authoritative
writer and apply its batch atomically.

Low-level standalone controller tests/clients may still use the existing collection patch
constructors. Public `Collection.reorder/2` requires a unique permutation of current keys and
rejects invalid input immediately. `Collection.new/1` builds ordered collections in one pass and
rejects duplicates. Numeric keys such as `1` and `1.0` are distinct.

## External APIs

### Subscription

`Solve.subscribe(app, target_or_source, subscriber \\ self())` registers a PID and returns the
raw exposed map, collection, or nil. Collection source updates come from the app; running item
updates are still delivered directly by their controller using `%Solve.Message{type: :update}`.

A controller subscription handshake is bounded to 1,000 ms. If the process is known dead, the
call returns nil and its monitor drives the normal restart policy. A timeout alone is not a
crash: a live target returns its last accepted cached value, retains the registration, and gets
up to three deferred attachment retries. Retries are tied to the target generation and subscriber.
No duplicate instance is started merely because an observer could not attach promptly.

Subscriber monitors remove registrations after subscriber death. Waiting registrations for absent
collection IDs remain intentionally, so those subscribers receive a future start notification.
Raw subscribers implementing their own cache should compare versions across lifecycle messages;
`Solve.Lookup` handles this automatically.

### Dispatch and introspection

- Explicit app dispatch is **`Solve.dispatch(app, target, event, payload)`**. Supply `%{}` when
  no payload is needed. There is no explicit-app default producing an ambiguous `/3` overload.
- Implicit `Solve.dispatch(target, event)` and `/3` use controller process context during event
  or Solve-style `handle_info` callbacks. Callback functions can use the imported bare helpers.
- Unknown/stopped targets and virtual collection sources silently ignore dispatch.
- `controller_pid/2`, `controller_events/2`, and `controller_variant/2` expose routing metadata.
- Undeclared events are logged and discarded.

## Solve.Lookup

Lookup caches refs by concrete app PID and target in the caller's process dictionary. Names
(including global/via names) resolve to the current PID; aliases do not duplicate cached refs.
A named-app restart is detected on the next read and causes a fresh subscription. An explicit
old PID is never rebound to another app.

An internal subscription snapshot returns value, kind, declared events, target PID(s), and version
coherently. Item maps are augmented with reserved `:events_` tuples. Collection items are augmented
using the snapshot's routing map. Augmentation happens on installation/update, not on each read.
Warm singleton and collection reads make zero calls to the Solve coordinator. Resolving a remote
or registry name can still involve registry/node work.

Direct event tuples are instance-bound: previously copied tuples do not magically retarget after
replacement. Process update envelopes and fetch fresh lookup values, or use explicit
`Solve.dispatch/4` when lifecycle-safe routing is required.

### Auto, manual, and helper modes

Auto mode installs handlers for nil, `%Solve.Message{}`, and owned tagged monitor messages:
`{:solve_lookup_down, ref, :process, app_pid, reason}`. Other DOWN messages remain the caller's
responsibility. Accepted updates invoke `handle_solve_updated/2` with updates grouped by app PID;
obsolete updates and monitor cleanup return no updates.

Manual mode installs no handlers. Forward envelopes and the owned tagged monitor messages to
`Solve.Lookup.handle_message/1`. Helper mode likewise requires the host process to handle its
messages. `Solve.Lookup.cleanup/0` can drop retired-instance refs/monitors explicitly; it is not
an unsubscribe API for live apps. Auto monitor cleanup is silent and does not try to render or
query an app that has exited.
