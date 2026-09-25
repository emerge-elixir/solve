# Monitor-backed remote Lookup cache

Status: implemented on branch `fix/lookup-remote-recovery`.

## Delivery and verification

The design below is implemented in `Solve.Lookup` plus private `Transport`,
`Recovery`, and `Watcher` modules. Controller data stays in the existing owner-local
ref cache; separate owner-local metadata tracks desired addresses/targets and
availability. One lazy watcher per consumer bounds aggregate discovery concurrency
to one probe. Subscription handshakes still originate from the consumer.

Readiness is per requested address. Consumers observing multiple addresses must
check each independently: one healthy binding may update while another is offline.
Neither a registered-name alias nor an explicit PID silently takes another binding's
identity. Equivalent active refs/raw subscriptions remain shared, not refcounted.

Validation performed on this branch:

| Elixir | OTP | Full tests | Format / warnings-as-errors / strict Credo | Dialyzer |
| --- | --- | --- | --- | --- |
| 1.18.4 | 27.3.4.3 | 207 passed | Passed | 0 errors |
| 1.19.5 | 28.3 | 207 passed | Passed | 0 errors |
| 1.20.2 | 29.0.5 | 207 passed | Passed | 0 errors |

Baseline before changes: 179 passed. The 28 new tests cover real `:peer` nodes,
query-free warm/update/cleanup paths, app/node startup ordering, app-only restart,
partitions with surviving PIDs, node reincarnation, old monitor messages, names/aliases, exact numeric
collection IDs, partial snapshots, capped retries, cancellation and resource churn.
`./ci-tests.sh all` passed for every matrix entry; `mix docs` also passed on OTP 29.
Existing unsubscribe regression tests remain unchanged.

Loopback measurement (OTP 29, 2,000 samples per case, microsecond timer resolution):

| Warm read | Baseline p50 / p95 | Branch p50 / p95 |
| --- | --- | --- |
| Remote PID | 20 / 28 µs | <1 / 1 µs |
| Remote registered name | 42 / 60 µs | <1 / 1 µs |

A simulated render performing twenty warm remote-name reads measured 11 / 13 µs
(p50 / p95). Baseline code was loaded separately from `5a1a7af`; the real-node
regression traces independently verify zero RPC/resolver/snapshot calls on warm
paths. These are loopback measurements, not physical WiFi or hardware acceptance.

No Goat dependency, firmware, cluster configuration, hardware runtime, or release
version was changed. The plan's remaining physical-network deployment checks belong
to downstream integration.

## Approved design

Updated requirement: Lookup itself owns automatic app/node recovery with capped
exponential backoff. This supersedes the earlier external-client-watcher proposal.
Basis: Solve 0.2.3, tracked tree at `5a1a7af`, including the existing raw and
Lookup unsubscribe implementations. Preserve the other files in `plans/`.

## 1. Problem and intended result

Lookup caches exposed controller data, but its remote hot paths still synchronously
probe another node before using that data:

| Operation today | Extra synchronous work |
| --- | --- |
| Warm `solve({name, remote_node}, target)` | `Process.alive?/1` RPC for the previous binding, then `Process.whereis/1` RPC |
| Warm `solve(remote_pid, target)` | `Process.alive?/1` RPC |
| Same operations through `collection/2` | Same checks |
| Handling an update for an acquired remote ref | `Process.alive?/1` RPC, even before rejecting an obsolete version |
| `cleanup/0` with remote refs | Liveness RPC for each remote app |

`resolve_named_app/1` and `alive?/1` use `:rpc.call/4`, with no explicit timeout.
The viewport process waits for those calls while unable to normally process its
other input/render/update messages. The liveness probes do not obtain fresher
controller data and cannot guarantee the app remains alive after replying.

Existing "zero coordinator calls" tests do not catch this: their counters watch
the Solve app, whereas these RPCs execute outside that app process.

**Goal:** once a remote target has been acquired, reading it and processing its
pushed updates require no Solve-issued remote queries. Existing process monitors
invalidate remote cache ownership. Lookup retains the caller's subscription intent
and automatically restores it when the node/app returns. Cold acquisition remains
bounded. The watcher recovers subscriptions; it is not a state-replication proxy.

## 2. Decisions and scope

1. Keep the current process-local cache, canonical app PIDs, target refs, aliases,
   version checks and one owned app monitor per cached app.
2. Remove remote liveness RPCs from healthy read/update/cleanup paths. While an app
   is connected, use its process monitor, not periodic polling. Only an unavailable
   binding runs the recovery watcher and its bounded retry schedule.
3. A warm `{registered_name, remote_node}` lookup uses its recorded alias and
   existing target ref. It does not re-resolve the name.
4. An uncached target through that remote address is a cold lookup: resolve the
   current name, then acquire/reuse the target on the resolved PID. An alias alone
   is not a cache hit. This permits explicit unsubscribe/reacquisition to rebind.
5. Preserve local-name live-rebinding behavior and local PID death checks. This
   avoids breaking the existing local restart/rebind tests for an unrelated fix.
6. Preserve the behavior of local `:global`/`:via` resolution, but never follow a
   resulting remote PID with a liveness RPC. Arbitrary registry implementations
   can themselves block; do not promise that user-supplied resolvers are I/O-free.
7. Bound Solve-owned cold resolution and snapshot calls with one finite acquisition
   budget, default 5,000 ms. Keep existing read arities and return shapes.
8. Preserve raw unsubscribe semantics, pinned ownership and uncertain detachment
   outcomes. Extend Lookup unsubscribe to cancel retained recovery intent as well
   as active refs. An explicitly removed target must never be resubscribed later.
9. Lookup owns recovery: remember what was requested, watch node/app availability,
   re-resolve names, resubscribe, and notify the consumer after installing fresh
   values and event routes. No separate Goat connection watcher is required.
10. Expose cached connection status and an optional lifecycle callback, separate
    from ordinary controller-data updates. A DOWN must not blindly invoke render
    callbacks that synchronously query an absent app.
11. No action replay, app failover, state-forwarding proxy, global data cache, or
    new runtime dependency. Internal recovery tokens fence local retry work; they
    do not require new epochs in the public Solve update protocol.

The important compatibility changes are explicit: remote cached names no longer
notice live registration changes on every read, and remote death is learned from
owned monitor messages rather than a synchronous read-side probe. Cache invalidation
now preserves live subscription intent and starts automatic recovery; unsubscribe
cancels that intent. These are deliberate lifecycle changes, not just optimizations.

## 3. Required invariants

### Identity and cache ownership

- A ref remains keyed by exact `{app_pid, target}`; preserve IDs such as `1` vs `1.0`.
- A cached `%Ref{value: nil}` is a real acquired interest, not a cache miss.
- Collection sources, individual collection items and singleton targets remain
  independent interests. Source event routing still comes from its snapshot.
- Distinguish active bindings/refs from desired subscription intent. An active
  alias is recorded only after a valid ref is installed/reused. Pending recovery
  metadata is never treated as a valid value cache or dispatch route.
- Retain original addresses and requested targets independently of active refs,
  so clearing a dead PID's cache does not lose what must be recovered.
- Keep at most one app monitor per cache-owning process/app PID. Repeated reads do
  not create more interests, timers or retry chains. Canceling the last desired
  interest releases its recovery machinery as well as active cache metadata.
- Switching a name to B must not silently discard live A's explicit PID/other-alias
  interests. Preserve A until released or invalidated by its own lifecycle.

### Updates

- Require a canonical app PID, existing exact target ref, matching kind and a valid
  newer `{generation, revision}` before changing cached data.
- Never seed refs, subscriptions, aliases or monitors from update messages.
- Preserve coherent value/version/event-route installation and same-value routing
  refresh on controller replacement.
- Late updates after invalidation/unsubscribe return `%{}` without network work.
- Explicit old PIDs and copied direct event tuples never retarget a replacement app.
- Every retry, probe result and recovery completion must match the current local
  recovery token and still-wanted targets before it can install refs or notify UI.

### Failure detection

- A remote monitor is an asynchronous failure/connection-loss notification, not
  proof that a process is alive at the instant of a cache read.
- Until an owned DOWN is processed, a remote cache read may return the last accepted
  value. This is expected eventually consistent subscription behavior.
- On matching DOWN, invalidate active refs, values, event routes and PID bindings
  for that app instance. Retain only desired addresses/targets and bounded recovery
  metadata; mark the binding unavailable and start the watcher.
- Do not treat `:noconnection` as permission to reuse an old subscription. Even a
  surviving remote PID requires a fresh subscription after reconnection.
- Losing connectivity does not prove the remote process died or that physical
  server-side detachment completed.
- No helper drains the caller's mailbox to discover DOWN messages. Auto mode handles
  them normally; manual/helpers users must forward them.
- A DOWN from an obsolete monitor must not invalidate a newly acquired monitor,
  including reconnection to the *same surviving remote PID*.

Backoff begins when Lookup observes failure, not at the first lost WiFi packet.
This watcher does not shorten Erlang's node-failure detection interval or add a
healthy-state heartbeat. A short silent outage can recover before a DOWN occurs;
Lookup then keeps its cache and existing subscription rather than starting recovery.

## 4. Read-path design

### 4.1 Classify addresses deliberately

Separate lookup reading from command address resolution. Do not optimize the shared
`resolve_app!/1` indiscriminately and accidentally change named dispatch routing.

Classify reserved address forms before generic `{name, node}`:

1. Explicit PID.
2. `{:global, key}`.
3. `{:via, registry_module, key}`.
4. Local registered atom.
5. `{registered_name, node_name}` with two atoms.
6. Invalid addresses retain an appropriate argument error/normal resolution error.

There is an adjacent ambiguity in the current code: `{:global, :atom_key}` matches
its generic two-atom remote-name clause. Fix this classification while refactoring,
and add an atom-key global-name regression test. The existing global tests use
compound keys and therefore miss this case.

### 4.2 Warm paths

- **Local PID:** preserve cheap `Process.alive?/1` checking and immediate dead-instance
  cleanup. No changed local restart semantics are needed.
- **Remote PID with existing target ref:** return the cached ref directly. Never
  call `Process.alive?/1` remotely or query node connectivity as a preflight.
- **Remote `{name, node}` with recorded alias AND target ref:** return that ref
  directly, including an inactive/nil ref or an empty collection.
- **`{name, node()}`:** treat as local name resolution without calling RPC.
- **Local atom / global / via:** retain current resolution semantics, select the
  canonical PID, then reuse its target ref. Check liveness only for a local PID.

For ordinary remote PID/name cache hits, return before reading acquisition timeout
configuration or running any resolution/subscription helper. Do not reaugment the
exposed value/event maps on each read.

### 4.3 Cold paths

First distinguish a new request from an already-watched unavailable interest.
A read of a watched unavailable target must not start another synchronous attempt
or reset backoff. It fails immediately with a documented unavailable/reconnecting
exit; `Lookup.status/1` lets callers avoid that exit. Do not fabricate nil/empty
controller data to hide an unavailable app.

For a genuinely new request:

1. Normalize implicit app context exactly as today; missing context still raises.
2. Establish the finite operation deadline described in section 6.
3. For a remote PID, go directly to the snapshot call: no liveness preflight.
4. For a remote name, resolve its current PID once with the remaining budget.
   A recorded alias with no requested target ref does not bypass this resolution.
5. If another alias/PID acquisition already installed the resolved PID's target
   ref, reuse it. Otherwise subscribe and obtain the coherent snapshot.
6. Validate/augment the snapshot before publishing new cache metadata.
7. Install/reuse the app monitor and ref; record the active alias and desired
   subscription intent. Recovery can reinstall this ref without another user read.

A nonexistent target on a reachable app returning no snapshot must not allocate an
active ref or an endless target-retry chain. An unavailable named app on the first
attempt is different: retain its requested target as pending intent and start the
watcher, while preserving the first attempt's bounded failure result. This supports
clients starting before the app. A known inactive target returns a snapshot with a
nil value and *does* install a valid ref.
App death between snapshot receipt and monitor installation is handled by the new
monitor's eventual DOWN; no extra RPC can close that race.

### 4.4 Remote named-app rebind semantics

This behavior must be documented and tested, not disguised as an internal change:

```text
Remote name N resolved to A; target T is cached.
N is deliberately re-registered to live B without stopping A.

solve(N, T)                    -> cached A, no RPC
unsubscribe(N, T)             -> releases cached A/T, not B/T
solve(N, T) after that removal -> resolves N again and acquires B/T
```

If A has other refs, its monitor and those refs survive. The missing T forces cold
resolution despite an existing alias, so no new public "clear alias" API is needed.
Check unsubscribe results; removal after a transport error is not confirmation of
physical detachment.

If A actually exits, consuming A's owned DOWN clears active bindings and starts
recovery using retained named intent. The watcher resolves B and Lookup resubscribes
without requiring another render/read. An explicit intent for A's old PID never
becomes an intent for B.

A cold acquisition of a different target may also move alias N to B. Old A refs
remain addressable by A's PID/other aliases, not by a historical name handle.
This retains the existing non-refcounted ownership model.

## 5. Update handling, monitors and cleanup

### `handle_message/1` update branch

Retain the existing input/ownership/version checks. Replace generic `alive?/1` with:

- Local app PID: retain cheap local death detection if needed for existing semantics.
- Remote app PID: presence of its owned cache/ref is sufficient to process the
  envelope; no remote liveness query and no resubscription.

Updates and app DOWN signals can come from different senders. Do not assume a total
ordering between a controller's update and the app monitor. An update processed
before invalidation may be accepted; an update processed after it must be ignored.
No linearizability or instantaneous failure detection is promised.

### Tagged monitor branch

Keep matching both canonical PID and current stored monitor ref. A matching DOWN
invalidates only that app's active refs/bindings and transitions retained intent into
recovery. Repeated, foreign and superseded DOWN messages neither clear newer refs
nor create additional watchers/retry chains.

`handle_message(down)` still returns no controller-data changes: no synthetic nil
updates, empty collections or fake versions. Auto mode may invoke the optional
connection lifecycle callback after marking the binding unavailable and scheduling
recovery. It must not invoke the normal data callback against the absent app.
An unavailable app is not the same condition as an inactive controller.

### `cleanup/0`

Remove its remote RPC behavior. It may prune known-dead **local** PIDs and orphan
active aliases. If such pruning invalidates still-desired named interests, enter
the same recovery path rather than losing their intent. Remote retirement comes
from forwarded owned monitor messages. Cleanup must not consume messages, cancel
wanted recovery intent, or become an alternative remote liveness poller.

Document this limitation for helpers/manual users: calling `cleanup/0` while
ignoring owned remote DOWN messages does not maintain a correct remote cache.

## 6. Bound cold acquisition and preserve failure meaning

Proposed configuration, read/validated only on acquisition, never on a cache hit:

```elixir
config :solve, lookup_timeout: 5_000
```

Require a positive integer in milliseconds; reject zero, negative values and
`:infinity`. Do not introduce new imported read arities or per-render workers.
The failure-only watcher has separate capped scheduling settings in section 8;
its probes and subscription-restoration rounds also have finite request budgets.

Implementation shape:

1. Set a local monotonic deadline at cold-operation entry.
2. Use explicit-timeout remote name resolution, e.g. `:rpc.call/5`, rather than `/4`.
3. Recompute remaining time before subscribing. Resolution must not receive a full
   budget followed by another full budget for the snapshot call.
4. Extend the internal `Solve.subscribe_snapshot` helper to accept an explicit
   timeout, retaining its existing arities/default for other callers. Add types.
5. If no budget remains, fail before sending another request.

Keep initial lookup and subscription handshakes in the owning process. The recovery
watcher may resolve/probe availability off-process, but must not send subscribe or
unsubscribe requests on behalf of that owner. Keeping one sender preserves request
ordering, including a delayed subscribe followed by cancellation. The watcher is
failure-only discovery machinery, not a new subscription owner or update forwarder.
A bounded restoration handshake can briefly pause its owner; do not advertise
recovery itself as entirely wait-free. Healthy reads and offline backoff do not
perform synchronous network work in the viewport.

Scope the bound accurately: these are finite network request/wait budgets, not
hard real-time guarantees under VM suspension or distribution backpressure. A
custom `:via` resolver is user code and is not made preemptible by this deadline.
Acquiring a new target may still pause a caller up to its configured budget.

Failure policy:

| Outcome | Meaning/action |
| --- | --- |
| First remote whereis returns nil | App absent; retain named intent/start recovery and preserve the missing-app exit |
| First resolution timeout or node/RPC failure | Preserve reason and start recovery for the requested address; do not return inactive-target data |
| Read of an already-watched unavailable target | Immediate unavailable/reconnecting exit, no RPC and no extra retry chain |
| Watcher attempt fails | Keep intent, record status/reason and schedule the next capped delay; do not crash the consumer |
| Snapshot call exits | Preserve the underlying GenServer failure/canonical PID context; clean only proven invalid ownership |
| No snapshot for unknown target | Existing nil behavior; no new cache ownership |
| Invalid exposed data/events collision | Existing validation error; no partially installed new ref |
| Successful snapshot | Install/refine coherent cache metadata and monitor |

For resolution failures, use a documented exit context identifying Lookup address
resolution and preserve timeout/node/RPC reason. Do not catch every failure and turn
it into `:noproc`. A remote PID's failed cold lookup may now report the snapshot-call
exit instead of the old preflight-liveness exit; describe that migration.

On failure, do not erase unrelated existing refs/aliases. Timeouts alone are not
proof an app is dead. Pending recovery metadata is permitted, but no failed attempt
may publish an active ref/binding. A call can time out after registering a raw
interest; no active cache ref does **not** prove that no subscription exists on the
server. Retain bounded knowledge of attempted owner PIDs needed for cancellation;
keep raw-unsubscribe uncertainty documentation. Retry subscriptions are idempotent
for the same subscriber/target, and must still originate from the owner process.
Do not schedule a late automatic unsubscribe that could remove a newer acquisition.

## 7. Dispatch and unsubscribe boundaries

### Dispatch

- Direct `{controller_pid, {:solve_event, ...}}` dispatch remains instance-bound
  `send/2`; no liveness RPC, delivery receipt, queue or automatic retry.
- Explicit named `Lookup.dispatch(app, target, event, payload)` and dispatch
  envelopes must still address the current name, not a cached read alias. Their
  explicit remote resolution is bounded, but is not a warm-read operation.
- Explicit remote-PID dispatch needs no preflight liveness RPC; casting to a PID
  does not guarantee it is alive. Document the disappearance of that incidental
  liveness error instead of pretending dispatch acknowledges server execution.
- Dispatch must not insert/rebind lookup ownership aliases. Keep raw
  `Solve.dispatch/4` semantics unchanged.

Removing synchronous checks does not make sending to a remote PID nonblocking in
all network/backpressure conditions. The strict zero-query assertion concerns
cached reads and *update* processing, not command transport itself.

### Unsubscribe

Extend Lookup cancellation to include desired recovery intent. This supersedes the
older `LOOKUP_UNSUBSCRIBE.md` assumption that all ownership disappears with cache
invalidation; do not rewrite that historical plan as if this were already shipped.
The raw `Solve.unsubscribe/2,3` contract remains unchanged.

- Select ownership from the active binding or retained pending intent, never by
  resolving a replacement name just to cancel it.
- With an active ref, preserve reentrancy rejection unchanged. Once cancellation
  takes effect, remove both its ref and all equivalent desired routes for that
  shared interest; an error that clears the local ref also cancels automatic retry.
- With only disconnected/pending intent, cancel it locally immediately, invalidate
  outstanding recovery work, and do not discover/contact a replacement app. `:ok`
  certifies cancellation of local interest, not remote physical detachment.
- Account for partially completed restoration: track which pinned PID may already
  hold raw subscriptions and preserve existing uncertainty/error semantics. Never
  let a late timeout cleanup cancel a newly reacquired target.
- Other targets/apps continue recovering. Canceling the last desired target stops
  its retry timer and probe; when no disconnected intents remain, stop the watcher.
- Raw unsubscribe alone still does not edit Lookup's process-local intent. Consumers
  that want Lookup recovery to stop must use Lookup unsubscribe.
- Preserve raw unsubscribe's current outer timeout. Do not silently substitute the
  acquisition budget or turn `:noconnection` into a physical-detachment receipt.
- Copied values/events cannot be revoked; the application must stop using stale
  controls. Previously issued actions are never queued/replayed by the watcher.

## 8. Lookup-owned watcher and recovery

### 8.1 Availability and retained intent

Maintain a distinction between:

1. **Active cache:** canonical PID, live owned monitor, coherent value/version/event
   refs and current aliases. "Reachable" means connected according to the latest
   observed lifecycle state, not a fresh ping on every read.
2. **Desired interests:** original app address, exact target/kind, and current
   logical ownership. These survive a connection loss until explicit unsubscribe
   or owner-process termination.
3. **Recovery state:** availability, last failure, bounded delay, current token and
   at most one scheduled/in-flight attempt for a logical binding. No old snapshots
   or unbounded history are needed to watch for recovery.

Lifecycle:

```text
connected -> matching DOWN -> reconnecting -> fresh subscription installed -> connected
                                  |
                                  +-> failed attempt -> capped backoff -> retry
                                  |
                                  +-> unsubscribe/owner death -> cancelled
```

A dead explicit PID with no way to name a replacement becomes unavailable rather
than retrying forever. All state is bounded by currently wanted interests, not all
apps/PIDs ever observed. Read retries must not multiply registrations or watchers.

Record enough per-target address provenance to recover deterministically:

- Named interests resolve that same name again after app or node restart.
- Explicit PID interests remain pinned. After `:noconnection`, retry that same PID;
  if it is confirmed dead, stop that PID's retry chain and report unavailable.
- Do not silently upgrade a PID-only interest into a named interest because another
  target happened to use an alias.
- Aliases for the same active PID/target still share one raw subscription and are
  not reference-counted. Equivalent interests coalesce on recovery; aliases that
  now resolve to different PIDs must not cause arbitrary name selection or steal
  each other's intents. Keep only current desired routes, not historical aliases.
- Unsubscribe through an old pinned PID must not cancel an already-rebound new PID's
  interest. A named unsubscribe cancels that address's current/pending ownership.

### 8.2 Watcher ownership and responsibility

Use a small lazy internal watcher owned by the Lookup consumer, not a global service
or a separate application-specific client watcher. One watcher per consumer can
manage its unavailable bindings; deduplicate targets belonging to the same app.

- Start it on loss of a wanted binding, or on the first retryable failed acquisition.
  While all wanted bindings are connected, there is no polling/probing worker.
- Monitor the consumer so termination cancels timers/probes and leaves no orphan.
  Do not make watcher/probe failure take down the viewport through an unhandled link.
- Own node monitoring inside the watcher; do not manipulate the consumer's unrelated
  `monitor_nodes` registrations. Filter events to nodes for wanted endpoints.
- Node-up accelerates a pending retry. It is not proof that the named app exists.
  Retry name resolution when the node is up but the app has not started, and when
  only the app restarted without any node-down event.
- A bounded discovery probe may try the configured known node through normal Erlang
  distribution/autoconnect. Do not rely solely on receiving node-up: that would
  miss already-connected nodes and may never cause a disconnected node to reconnect.
- Do not start distribution, choose cookies, discover arbitrary peers or change
  cluster policy. Those remain deployment responsibilities. If local distribution
  is not ready, treat that as retryable rather than crashing.
- Run bounded resolution probes outside the viewport. Use owned cancellable work
  where needed so a stuck/custom resolver cannot block watcher cancellation.
  Bound concurrent work; no task per target or per render.
- The watcher returns a candidate PID plus recovery token to the owning process.
  It does not own controller subscriptions, forward updates, or maintain a second
  controller-state cache.

### 8.3 Capped exponential backoff

Proposed defaults (milliseconds):

```elixir
config :solve,
  lookup_timeout: 5_000,
  lookup_recovery: [initial_delay: 250, max_delay: 30_000, jitter: 0.2]
```

Base delays: `250, 500, 1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, ...`.
Schedule after an unsuccessful attempt finishes; each attempt is separately bounded.
Use bounded downward jitter, e.g. `[0.8 * base, base]`, so the actual delay never
exceeds the configured cap and clients do not all retry simultaneously.

"Limit" here means **maximum delay**, not abandoning recovery after N attempts.
Continue at the capped interval while the owner still wants the subscription.
Validate positive delays, `max_delay >= initial_delay`, and a bounded jitter value;
permit zero jitter for deterministic tests. Saturate the delay rather than keeping
an indefinitely growing retry counter or exponent.

- Reset delay only after successful restoration, not merely node-up/name resolution.
- Coalesce node-up signals and duplicate failure notifications. An expedited attempt
  must not overlap an existing one or turn a flapping node into a tight retry loop.
- Keep at most one retry timer and one in-flight attempt per logical binding, with
  bounded aggregate probe concurrency per watcher.
- Clear timers on recovery/cancellation. Timer cancellation is not sufficient alone:
  already-queued timer messages must also fail the current-token check.
- Reads, offline UI rerenders and ordinary controller updates do not reset backoff
  or initiate extra attempts.

### 8.4 Restore subscriptions, not just connectivity

A successful probe causes the consumer to process a tagged recovery message:

1. Check consumer binding token, candidate PID and the **current** wanted targets.
   Ignore stale results without modifying cache, status or callbacks.
2. Acquire fresh snapshots/subscriptions from that PID, using the consumer itself
   as subscriber and request sender. Preserve same-sender subscribe/unsubscribe
   ordering; discovery workers must never send these requests.
3. Bound each restoration round with one finite deadline, not a full timeout per
   target. If needed, continue unfinished targets in later rounds. Retain precise
   partial-attempt bookkeeping and do not declare the binding fully recovered early.
4. Stage fresh values, versions and event routes in the owner's ref storage, with
   the new app monitor, until that binding's current wanted set is restored. There
   is no second state cache in the watcher. Accept newer updates for staged refs
   without triggering a premature data callback; absent refs still reject updates.
   Keep the binding reconnecting and its reads fail-fast while the set is incomplete.
5. Publish the restored set and invoke `handle_solve_updated/2`, **even when exposed
   values equal their pre-outage values**. The callback can now read its complete
   wanted set without accidentally starting cold requests. Other app bindings do
   not wait for this one. The UI must reacquire current event routes.
6. Reset/stop successful retry chains. Node-up or a PID-resolution reply alone never
   counts as successful recovery. If cancellation makes the remaining set complete,
   finalize via a current tagged recovery message, not a callback inside unsubscribe.

Repeat this handshake after a partition even if the app PID is unchanged: the server
may have removed the disconnected subscriber. Queued old updates cannot seed absent
refs. Once a ref is freshly acquired, normal generation/revision comparisons govern
queued data; this plan does not add wire-level subscription epochs.

If subscription times out, retryable intent remains and server-side registration
may already exist. Preserve idempotence and ordering rather than launching cleanup
workers that could race a later successful subscription. A confirmed unknown target
or invalid schema on a reachable replacement app is a surfaced compatibility error,
not a fast endless retry loop; do not synthesize valid data for it.

### 8.5 Consumer API and message integration

Keep `solve`, `collection`, event tuples and normal update callback usage. Add a
qualified, local-only status query, conceptually:

```elixir
Solve.Lookup.status(app)
# :unknown | {:connected, pid} | {:reconnecting, reason} | {:unavailable, reason}
```

This reports Lookup's observed state, not an instantaneous network health guarantee.
Allow an optional `handle_solve_connection_changed(app_address, status, state)`
callback in auto mode for offline indicators/input gating. Invoke it only for real
status transitions, after internal state has changed; do not call it for every
failed backoff attempt. Default behavior is no-op for existing consumers.

- Auto mode handles owned DOWN, watcher/probe completion and retry-related envelopes,
  invokes optional lifecycle notifications, and invokes normal data callbacks after
  restored snapshots have been installed.
- Manual/helpers users must forward the documented tagged Lookup messages, not just
  `%Solve.Message{}` and the old DOWN tag. `handle_message/1` performs the same state
  transitions; successful restoration returns normal grouped `Updated` data so
  manual consumers can rerender. They can inspect status to handle lifecycle UI.
- Do not leak private watcher messages into unrelated user handlers, consume foreign
  monitors, or require a consumer to inspect the private cache representation.
- A read of a known pending target fails immediately without RPC; status-aware render
  code can keep the previous scene or show an offline state. Initial cold lookup may
  still fail once before the watcher succeeds. Document both cases and provide a
  tested example that starts before the remote app.

Neither cache invalidation nor the watcher revokes copied event handles, cancels
already-admitted remote work, or guarantees that transport-buffered messages cannot
arrive late. No automatic action replay is introduced. Applications still own input
safety, offline visual policy and command freshness/admission rules.

### 8.6 Cancellation and stale work

Fence watcher messages with a fresh local recovery token for the affected binding
and an intent revision/current wanted set. Advance/invalidate it on cancellation,
rebinding, new recovery cycles and relevant interest changes.

Tests must cover unsubscribe between probe start/result, between candidate delivery
and snapshot acquisition, and after a partial timeout. Revalidate intent before
subscription and before committing results. Stale work must neither restore a
removed ref nor announce recovery or restart its timer.

A watcher crash is retryable internal failure, not permission to forget user intent
or crash the consumer. Restart with fresh fencing while desired interests remain;
retain backoff rather than spinning on repeated failures. A stopped consumer or a
consumer with no remaining recovery intent must leave no watcher, timer or probe.

## 9. Regression and performance tests

Add `test/solve/lookup_remote_test.exs` with real peer-node fixtures; extend existing
lookup/audit/unsubscribe tests where they cover compatibility.

### Test infrastructure

- Use `:peer` with `connection: :standard_io`, copied code paths, and small scheduler
  counts as in the existing remote unsubscribe test. Control peers over that
  independent channel while deliberately disconnecting Erlang distribution.
- Preserve/restore original node state, per-peer cookies, tracing patterns, app
  configuration and owned processes. Do not break a pre-existing test runner node.
- Run distribution/global-tracing cases non-concurrently. Use synchronization
  barriers, not sleeps that assume an update or DOWN has been processed.
- Trace the lookup consumer's RPC/ERPC and subscription/resolver entry points, with
  a trace-delivery barrier and cleanup in `after`. Coordinator counters alone do
  not prove absence of remote probes.
- A real remote node is required: `{name, node()}` does not exercise this bug.

### A. Demonstrate the current defect, then require zero queries

1. First remote named lookup acquires state and remote direct event routes; events
   produce pushed updates and the ordinary consumer callback.
2. After acquisition, repeated remote-PID and remote-name singleton reads produce
   zero RPC/ERPC, snapshot, or remote name-resolution calls.
3. Repeat for collections, individual items, inactive nil refs, and empty sources.
4. Process a valid pushed update with zero probes; run a callback that reads cached
   state repeatedly and verify the callback itself also makes zero queries.
5. Duplicate/obsolete, wrong-kind, versionless, name-addressed and unsolicited
   updates produce no query or new metadata.
6. `cleanup/0` with live remote refs performs no remote work and leaves them intact.
7. Newly requested targets and unknown aliases are correctly classified as cold;
   sharing a canonical PID reuses existing refs/monitors where possible.

### B. Lifecycle and ordering

8. Stop remote app A and process its owned DOWN. Verify active refs/bindings are
   removed, desired interests remain, and one recovery chain starts. Old updates
   cannot resurrect A's cache or trigger data callbacks.
9. Restart registered app B on the same node. Lookup automatically resolves and
   resubscribes without another user read. Explicit A never rebinds; copied A event
   tuples never retarget B.
10. Deliberately live-rebind a remote name A -> B. A warm cached target stays A with
    zero queries. Explicit unsubscribe/reacquisition reaches B without deleting
    A's other refs. A cold different-target acquisition can rebind the alias too.
11. Disconnect distribution while the remote app survives. Process `:noconnection`,
    restore connectivity and verify automatic resubscription to the same PID and
    resumed pushes. A stale old monitor must not invalidate the new monitor.
12. A remote read before an owned DOWN is processed may return cached data; after
    processing, it cannot. Test this deliberately in a controlled manual consumer.
13. App death between snapshot reply and monitor installation eventually removes
    the ref. No permanently unmonitored cache entry may be installed.
14. Killing a controller while its app remains alive refreshes versions/event routes
    through normal Solve updates, without dropping other app interests.
15. Auto/manual/helpers behavior, foreign DOWN messages, repeated DOWN and two-app
    isolation retain their documented semantics. DOWN invokes no synthetic data
    callback; optional connection notification works, and recovery does invoke the
    data callback after installing refs, even for unchanged values.

### C. Bounded acquisition and errors

16. Verify default and overridden finite lookup budgets, and invalid configuration.
17. Deterministically delay remote name resolution and snapshot reply. Verify a
    shared budget rather than two consecutive full timeouts. Instrument/stub the
    cold resolver boundary in tests if necessary, without adding a public transport
    abstraction solely for testing.
18. Unknown remote name, stopped remote PID, unavailable node, and timeout remain
    distinguishable failures, not successful nil/off-controller reads.
19. Failed acquisition leaves no new active bindings/refs, but retryable absence
    retains wanted intent and starts one watcher. Unknown targets on a reachable
    app do not create endless retries. Unrelated interests remain unaffected.
20. Resume a server after snapshot timeout: late replies/updates cannot seed a ref;
    only a current, still-wanted recovery attempt can install one. Partial raw
    registrations and cancellation preserve their documented uncertainty/order.

### D. Preserve contracts and bound metadata

21. Existing local named restart works without first forwarding DOWN; local live
    alias rebind behavior stays unchanged.
22. Global/via aliases still work, including a global **atom** key. Same-node named
    tuples do not issue RPC. Document custom resolver work outside the guarantee.
23. Named dispatch goes to the current registration without rewriting cached read
    ownership; direct tuples remain instance-bound.
24. Keep raw unsubscribe and active-ref Lookup error/ownership regressions green.
    Extend formerly missing-ref tests for pending recovery intent and document those
    deliberate lifecycle changes rather than deleting the regression coverage.
25. Repeated acquisition/unsubscribe, app restart and disconnect/reconnect return
    active cache, intent, monitors, timers, probes and registrations to baseline
    after interests are released. No recovery history/workers accumulate.

### E. Watcher, capped backoff and cancellation

26. Deterministic scheduling tests verify exponential delays, jitter bounds, the
    maximum-delay cap and reset on actual recovery. Sustained outages continue at
    the cap rather than exhausting an implicit attempt limit.
27. Boot before the remote node/app exists: the initial bounded failure starts a
    watcher and later recovers without another lookup call or external watcher.
28. Node-up accelerates recovery; node already up/app absent and app-only restart
    also recover. Duplicate/flapping node events never create overlapping chains.
29. Many unavailable reads, multiple targets and equivalent aliases share intended
    work. Reads neither reset backoff nor issue remote queries while watched.
30. Test unsubscribe before a retry fires, during resolution, with a queued candidate,
    after partial restoration, and immediately before a late result. Canceled refs
    must never return or trigger recovery callbacks. Other wanted refs still recover.
31. Node flaps during restoration; stale timers, watcher results, monitor messages
    and completion messages from a prior recovery cycle all fail their token checks.
32. Explicit PID intent recovers the same surviving PID after partition but stops on
    confirmed PID death. Named intent can bind a replacement. Mixed alias/PID intent
    never silently changes a pinned PID's identity.
33. Consumer termination, final unsubscribe and watcher/probe crash leave no orphan
    work. Internal failures preserve intent and capped pacing without killing UI.
34. Status queries and offline reads are local-only. Auto optional lifecycle hooks,
    manual message forwarding and helpers recover the same data/event routes.
35. A bounded recovery round does not multiply its timeout by target count. Partial
    handshakes remain pending; staged updates do not prematurely invoke callbacks
    that read missing refs. Canceling the final missing target can complete the
    remaining set without resurrecting it or calling a callback inside unsubscribe.
36. Exercise a delayed/partitioned link and verify no intentional command replay;
    do not mistake transport-delayed delivery for a new Lookup retry feature.

### Measurements

Use operation-count assertions as the release gate, not timing alone. Optionally
record a warmed-read/update benchmark before and after under injected link latency.
The key result is zero additional remote queries per warm read/update, including
nested reads during a render callback. Do not report loopback peer tests as physical
WiFi qualification or claim synchronized presentation across nodes.

## 10. Files, delivery order and validation

Expected implementation files:

- `lib/solve/lookup.ex`: address classification, split read/dispatch resolution,
  remote cache-hit paths, desired-intent/availability bookkeeping, monitor-driven
  invalidation, local-only cleanup, finite acquisition and recovery commit/fencing,
  status query and auto/manual lifecycle integration.
- `lib/solve/lookup/watcher.ex` (proposed private module): lazy owner-scoped node/app
  watching, bounded resolution probes, capped scheduling and cancellation. No
  controller-state cache or subscription forwarding.
- `lib/solve.ex`: explicit timeout support on the internal snapshot helper only;
  do not redesign public raw subscriptions/unsubscribe.
- `test/solve/lookup_remote_test.exs`: real remote coverage and zero-query assertions.
- Watcher-focused tests: deterministic scheduling, token races, cancellation and
  owner/probe lifecycle, plus real-peer end-to-end automatic recovery.
- Existing lookup/audit/unsubscribe suites: focused compatibility additions.
- `README.md`, `ARCHITECTURE.md`, Lookup module/function docs and `CHANGELOG.md`:
  remote cache semantics, deadline/backoff configuration, retained intent and
  unsubscribe migration, required message forwarding, status/lifecycle APIs, cold
  vs warm/offline reads, automatic recovery and remaining UI/transport limitations.

Deliver as independently reviewable steps:

1. **Reproduce** — add real remote fixtures and query-count regressions; record the
   currently failing hot paths. Existing coordinator-only tests remain useful.
2. **Remove hot-path probes** — warm remote reads, pushed updates, cleanup and owned
   monitor invalidation; preserve local behavior and unsubscribe ownership.
3. **Bound cold work** — shared deadline, internal snapshot timeout, error-path and
   partial-acquisition tests; separate explicit command routing from cached reads.
4. **Add recovery intent and watcher** — owner-scoped lifecycle, capped backoff,
   bounded probes and same-owner subscription restoration; cancellation/token races
   must pass before declaring recovery usable.
5. **Integrate notifications** — cached status, optional lifecycle hook, normal data
   callbacks on restored snapshots, and consistent manual/helpers handling.
6. **Document/audit** — compatibility matrix, boot-before-app/offline examples,
   automatic recovery, operation counts and churn checks. Update current docs, not
   historical result reports, to describe the new behavior.

Run the full current CI matrix, not only the new remote suite:

- Elixir 1.18.4 / OTP 27.3.4.3
- Elixir 1.19.5 / OTP 28.3
- Elixir 1.20.2 / OTP 29.0.5

Run `./ci-tests.sh` (format, warnings-as-errors compilation, strict Credo, tests and
Dialyzer) and build docs. Use isolated toolchain build caches as needed; do not
rewrite user tool installations or dependency paths. Start by recording the actual
baseline instead of treating older plan result counts as a current test run.

Release gate: no Solve-issued remote probes on healthy warm paths or offline reads,
finite cold/recovery budgets, automatic restart/partition recovery with capped
backoff, cancellation that cannot resurrect interests, bounded watcher resources,
and documented semantic changes. No external client watcher is needed to recover
Lookup subscriptions. WiFi provisioning/cluster formation, role-specific rendering,
offline visual policy and action safety remain application/deployment concerns.
