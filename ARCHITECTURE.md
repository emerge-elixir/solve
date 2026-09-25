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
Standalone/raw usage remains supported, but versionless messages cannot update lookup refs or
app-managed controller dependencies. Lookup requires explicit acquisition and complete versioned
runtime envelopes. Runtime-to-app updates must identify the current managed instance.

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
up to three deferred attachment retries. Retries are tied to the target generation, subscriber,
and a unique attachment-chain token, so canceled retries cannot affect a later subscription.
No duplicate instance is started merely because an observer could not attach promptly.

Subscriber monitors remove registrations after subscriber death. Waiting registrations for absent
collection IDs remain intentionally, so those subscribers receive a future start notification.
Raw subscribers implementing their own cache should compare versions across lifecycle messages;
`Solve.Lookup` handles this automatically.

`Solve.unsubscribe/2,3` removes raw target interest and awaits live-controller external detachment
for up to one second. It preserves dependencies and the mandatory app observer. Direct reentrancy
is rejected before mutation. Other nested errors remove logical interest but leave physical
completion unconfirmed; outer app-call timeout exits leave even logical completion unknown.
This raw API does not clear lookup caches or drain queued messages.

### Dispatch and introspection

- Explicit app dispatch is **`Solve.dispatch(app, target, event, payload)`**. Supply `%{}` when
  no payload is needed. There is no explicit-app default producing an ambiguous `/3` overload.
- Implicit `Solve.dispatch(target, event)` and `/3` use controller process context during event
  or Solve-style `handle_info` callbacks. Callback functions can use the imported bare helpers.
- Unknown/stopped targets and virtual collection sources silently ignore dispatch.
- `controller_pid/2`, `controller_events/2`, and `controller_variant/2` expose routing metadata.
- Undeclared events are logged and discarded.

## Solve.Lookup

Lookup caches refs by canonical app PID and exact target in the caller's process dictionary.
Aliases share refs, not reference counts. Warm remote PID reads and remote `{name, node}` reads
use that cache with **zero RPC, resolver or snapshot calls**. Nil inactive refs and empty
collections are real hits. Update acceptance and cleanup also avoid remote liveness probes.
Local/global/via names retain resolver semantics; reserved global names are not remote tuples.

A warm remote name stays pinned while its owned app monitor is valid, even if the registration
is rebound while the old process lives. A new target (or unsubscribe followed by reacquisition)
resolves the current registration. Old PID interests remain independently addressable. Explicit
named dispatch resolves the current name without changing lookup aliases; copied direct event
tuples and PID dispatch remain instance-bound. A send is not an admission or delivery receipt.

Cold resolution and snapshot acquisition share `config :solve, lookup_timeout: 5_000`.
The budget must be a positive integer and is validated on acquisition, not cache hits. Explicit
remote resolution uses a finite RPC timeout. Custom registry code and VM/distribution suspension
are not hard real-time bounded by that budget. A failed snapshot may already have registered
raw interest on the server; no local ref is not proof of physical detachment.

Snapshots contain value, kind, target/event PIDs and version coherently. Augmentation happens
on installation/update, not on every read. Runtime updates require an existing acquired ref,
canonical app PID, matching kind and a newer nonnegative generation/revision. Unsolicited,
versionless and retired updates cannot create ownership.

### Availability and automatic recovery

A matching owned app DOWN retires active values/routes/aliases and retains **desired interests**
(original addresses and exact targets). A lazy owner-scoped watcher observes node-up and probes
only unavailable bindings. Named apps can recover after app-only restart, node restart, or a
client starting before the app. Pinned PIDs can recover after a partition if still alive, but
never follow a replacement PID. Healthy bindings have no periodic liveness polling.

```elixir
config :solve,
  lookup_timeout: 5_000,
  lookup_recovery: [initial_delay: 250, max_delay: 30_000, jitter: 0.2]
```

Base delays double up to 30 seconds, with downward jitter bounded by 20%. The cap is a maximum
delay, not an attempt count. Node-up can expedite pending discovery without overlapping work
or resetting pacing. A watcher has at most one discovery probe in flight. It neither starts
Erlang distribution nor selects cookies, peers or application authority.

The watcher owns no controller subscriptions or data cache. It returns fenced candidate PIDs;
the consumer sends its own subscribe/unsubscribe requests, preserving sender ordering. Recovery
rounds have a finite shared request budget. Partial snapshots and newer pushes are staged in
the consumer's refs until that binding's wanted set is ready. Then `handle_solve_updated/2`
runs even for unchanged values, allowing the UI to replace obsolete event routes. Reconnection
to a surviving app PID still resubscribes: the app may have retired the old subscriber.

Recovery messages/timers are fenced against stale watcher, binding and timer tokens. Cancellation,
new attempts and watcher crashes cannot resurrect removed interests. Internal watcher failure
preserves desired interests and backoff; owner death cancels watcher/probe resources. Confirmed
unknown targets or incompatible snapshots on a replacement are surfaced as unavailable, not
fabricated as inactive controller values.

`Solve.Lookup.status(app)` returns `:unknown`, `{:connected, pid}`, `{:reconnecting, reason}` or
`{:unavailable, reason}` using local metadata only. Initial cold reads can exit while starting
recovery. Reads of a watched unavailable binding exit immediately, without restarting backoff;
additional offline targets are retained as desired interests. Status-aware rendering can keep
its last scene or display an offline indicator. The optional auto-mode lifecycle callback is
`handle_solve_connection_changed(app_address, status, state)`; it returns `{:ok, state}` and
runs before a recovery data callback. Retry failures within the same phase do not spam it.
Readiness is per requested address: consumers observing several app addresses must gate each
one independently, since updates from a healthy binding can arrive while another is offline.

Reachability means **last observed lifecycle state**, not a heartbeat guarantee. Backoff begins
at detected failure; a short silent WiFi stall may produce no DOWN at all. Transport-buffered
actions may arrive late. Lookup adds no replay, expiration, hardware cancellation or authority
failover. Applications must still enforce command freshness/admission and decide offline UI.

### Releasing lookup interests

`Solve.Lookup.unsubscribe/1,2` operates on the calling process's cached interest. It uses an
explicit PID or a previously acquired alias's cached PID, never a freshly resolved name. An
unknown alias or missing interest is a local `:ok` no-op, even if a raw subscription exists.
A pending interest without a ref is canceled locally without resolving a replacement name.
A new acquisition through a reused name binds that alias to the new instance; there are no
historical acquisition handles or per-alias reference counts.

For an existing ref, Lookup calls raw unsubscribe on the pinned PID. Success removes that ref;
raw reentrancy rejection preserves it unchanged. Other errors remove it with physical cleanup
unconfirmed, and outer call exits are re-raised after local removal. Confirmed app death removes
all of that app's refs; a remote disconnect alone is not confirmation. A second lookup unsubscribe
after an error is a local no-op, not a physical retry. Use raw unsubscribe with the original PID
when that confirmation is needed.

Only the requested target is removed; collection sources and separately acquired items remain
independent. Cancellation removes equivalent desired routes as well as active refs. The last ref
releases the owned app monitor/aliases, and the last pending interest stops recovery work. Raw
unsubscribe alone does not edit Lookup intent; use Lookup unsubscribe to prevent recovery. Updates cannot create refs, so queued messages are ignored while
the target is absent. An explicit later read reacquires it; versions still govern update ordering
after reacquisition, without introducing per-subscription message epochs.

Unsubscribe does not invoke an update callback, modify a saved scene, stop controllers, or revoke
returned event tuples. Render code that reads the target again intentionally resubscribes.

### Auto, manual, and helper modes

Auto mode installs handlers for nil, `%Solve.Message{}`, the two owned DOWN tags
`:solve_lookup_down` and `:solve_lookup_watcher_down`, and private three-tuples
`{:solve_lookup, kind, payload}`. Ordinary updates and completed restorations return changes
grouped by app PID. DOWN does not invoke a data callback with fake nil values; the optional
connection callback handles lifecycle UI. Foreign monitor refs do not alter Lookup ownership.

Manual and helper modes install no handlers. Forward all of the above Lookup envelopes to
`Solve.Lookup.handle_message/1`, and rerender when its result is nonempty. Inspect `status/1`
for lifecycle UI. Ignoring the recovery messages prevents automatic restoration. Cleanup does
not drain the mailbox or probe remote nodes; it only retires known-dead local apps and orphan
active aliases. It is not an unsubscribe API and does not cancel still-wanted recovery intent.
