# Solve

Solve is a controller-graph state runtime for Elixir applications.

It models application state as a graph of focused controllers instead of a tree
that mirrors UI structure. Each controller owns one slice of behavior and
state, exposes a plain map, and declares its dependencies explicitly.

This keeps state structure and UI structure separate. Your UI can still render
as a tree, but your application state does not have to follow that shape.

## Install Solve

Add `solve` to your dependencies:

```elixir
def deps do
  [
    {:solve, "~> 0.1.0"}
  ]
end
```

## Model state around interaction

Users do not interact with one widget in isolation. They interact with the
application as a whole.

A click, a filter change, a draft edit, or a menu selection is presented in one
place, but it often affects several other parts of the system:

- visible content
- counters and summaries
- enabled actions
- local editing state
- background processes

That is why Solve models state around ownership and interaction, not around the
nearest rendered component.

A controller is not just a bucket of values. A controller models one coherent
slice of application behavior.

## Learn the core ideas

- **controller** - a `GenServer` that owns one slice of state and behavior
- **exposed state** - the plain map a controller shares with subscribers,
  dependents, and view code
- **dependency** - another controller's exposed state made available to a
  controller
- **callback** - a function passed from the app into a controller for explicit
  cross-controller writes
- **collection source** - a controller spec that manages many item controllers
  such as `{:todo, 1}` or `{:todo, 2}`
- **Solve app** - the coordinating `GenServer` that owns the controller graph
- **Solve.Lookup** - a process-local API for cached reads and direct event refs

Declared event handlers take the leading subset of runtime inputs they need:

- `payload`
- `state`
- `dependencies`
- `callbacks`
- `init_params`

For example, an event handler may be defined at any of these arities:

```elixir
event_name(payload)
event_name(payload, state)
event_name(payload, state, dependencies)
event_name(payload, state, dependencies, callbacks)
event_name(payload, state, dependencies, callbacks, init_params)
```

## Start with one controller

Start with one controller.

A controller is the smallest useful unit in Solve. It owns one slice of state,
handles a small set of events, and exposes a plain map for the rest of the
application to read.

```elixir
defmodule MyApp.CounterController do
  use Solve.Controller, events: [:increment, :decrement]

  @impl true
  def init(_params, _dependencies), do: %{count: 0}

  def increment(_payload, state), do: %{state | count: state.count + 1}
  def decrement(_payload, state), do: %{state | count: state.count - 1}
end
```

This controller models one small interaction boundary: incrementing and
decrementing a counter.

That is the right place to begin. Start with one interaction and give it one
controller.

## Run controllers in an app

Controllers run inside a Solve app.

The app starts the controller graph, keeps it alive, and routes events to the
right controller instance.

```elixir
defmodule MyApp.App do
  use Solve

  @impl Solve
  def controllers do
    [
      controller!(name: :counter, module: MyApp.CounterController)
    ]
  end
end
```

Start the app like any other `GenServer`:

```elixir
{:ok, app} = MyApp.App.start_link(name: MyApp.App)
```

At this point:

- `MyApp.CounterController` models one slice of behavior
- `MyApp.App` runs that controller
- the app becomes the stable runtime entrypoint for reads, dispatch, and
  subscriptions

## Describe data flow in the app

The app is not only a runtime container. It also defines how controllers
interact.

That is the main role of the controller graph.

An app defines:

- which controllers exist
- which controllers read from others through dependencies
- which writes cross ownership boundaries through callbacks
- which repeated controller instances are materialized through collections

For example:

```elixir
defmodule MyApp.App do
  use Solve

  @impl Solve
  def controllers do
    [
      controller!(name: :task_list, module: MyApp.TaskList),
      controller!(
        name: :create_task,
        module: MyApp.CreateTask,
        callbacks: %{
          submit: fn title -> dispatch(:task_list, :create_task, title) end
        }
      ),
      controller!(
        name: :filter,
        module: MyApp.Filter,
        dependencies: [:task_list]
      ),
      controller!(
        name: :task_editor,
        module: MyApp.TaskEditor,
        variant: :collection,
        dependencies: [:task_list],
        collect: fn _context = %{dependencies: %{task_list: task_list}} ->
          Enum.map(task_list.ids, fn id ->
            {id, [params: %{id: id, title: task_list.tasks[id].title}]}
          end)
        end
      )
    ]
  end
end
```

This graph describes data flow directly:

- `:filter` reads from `:task_list`
- `:create_task` writes back to `:task_list` through a callback
- `:task_editor` materializes one controller per task
- `:task_list` remains the owner of the canonical data

Controllers implement behavior. The app defines how controllers read from and
write to each other.

## Keep controllers focused

Each controller owns one coherent interaction boundary.

Good controller boundaries include things like:

- current screen selection
- draft input state
- active filter state
- canonical list data
- one edit session per item

A focused controller has:

- one clear responsibility
- one small event surface
- one exposed state map
- one reason to change

For example:

```elixir
defmodule MyApp.Screen do
  use Solve.Controller, events: [:set]

  @screens [
    %{id: :tasks, label: "Tasks"},
    %{id: :reports, label: "Reports"}
  ]

  @impl true
  def init(_params, _dependencies), do: %{current: :tasks}

  def set(screen, state) when screen in [:tasks, :reports] do
    %{state | current: screen}
  end

  def set(_screen, state), do: state

  @impl true
  def expose(state, _dependencies, _params) do
    %{current: state.current, screens: @screens}
  end
end
```

## Use dependencies for derived state

Use dependencies when one controller needs another controller's exposed state as
input.

Dependencies are for reads.

They are the right place for:

- filtered ids
- grouped sections
- status summaries
- enabled actions
- derived counts

For example, a filter controller exposes `visible_ids` instead of making the UI
recompute filtering logic during rendering:

```elixir
defmodule MyApp.Filter do
  use Solve.Controller, events: [:set]

  @filters [:all, :active, :completed]

  @impl true
  def init(_params, _dependencies), do: %{active: :all}

  def set(filter, _state) when filter in @filters, do: %{active: filter}
  def set(_filter, state), do: state

  @impl true
  def expose(state, _dependencies = %{task_list: task_list}, _params) do
    %{
      filters: @filters,
      active: state.active,
      visible_ids: visible_ids(state.active, task_list)
    }
  end

  defp visible_ids(:all, %{ids: ids}), do: ids

  defp visible_ids(:active, %{ids: ids, tasks: tasks}) do
    Enum.reject(ids, fn id -> tasks[id].completed? end)
  end

  defp visible_ids(:completed, %{ids: ids, tasks: tasks}) do
    Enum.filter(ids, fn id -> tasks[id].completed? end)
  end
end
```

This keeps derived state out of the UI layer.

## Use callbacks for explicit writes

Use callbacks when one controller needs to request a write from another
controller.

Dependencies describe reads. Callbacks describe writes.

This keeps the dependency graph acyclic while preserving ownership.

For example, an input controller owns the draft title while another controller
owns the canonical list:

```elixir
defmodule MyApp.App do
  use Solve

  @impl Solve
  def controllers do
    [
      controller!(name: :task_list, module: MyApp.TaskList),
      controller!(
        name: :create_task,
        module: MyApp.CreateTask,
        callbacks: %{
          submit: fn title -> dispatch(:task_list, :create_task, title) end
        }
      )
    ]
  end
end
```

The controller still owns its own local transition logic:

```elixir
defmodule MyApp.CreateTask do
  use Solve.Controller, events: [:set_title, :submit]

  @impl true
  def init(_params, _dependencies), do: %{title: ""}

  def set_title(title) when is_binary(title) do
    %{title: title}
  end

  def submit(_payload, state, _dependencies, _callbacks = %{submit: submit}) do
    case String.trim(state.title) do
      "" ->
        %{title: ""}

      title ->
        submit.(title)
        %{title: ""}
    end
  end
end
```

This keeps ownership explicit:

- one controller owns the draft input
- another controller owns the canonical data
- the write boundary is visible in the app graph

## Use collections for repeated item state

Use a collection source when many items need the same local behavior.

This fits cases like:

- one edit session per row
- one expanded state per item
- one upload state per file
- one inspector state per node

A collection source reuses one controller design while keeping each item's local
state separate.

```elixir
controller!(
  name: :task_editor,
  module: MyApp.TaskEditor,
  variant: :collection,
  dependencies: [:task_list],
  collect: fn _context = %{dependencies: %{task_list: task_list}} ->
    Enum.map(task_list.ids, fn id ->
      {id, [params: %{id: id, title: task_list.tasks[id].title}]}
    end)
  end
)
```

Each item controller then owns only its own local behavior:

```elixir
defmodule MyApp.TaskEditor do
  use Solve.Controller, events: [:begin_edit, :cancel_edit, :set_title, :save_edit]

  @impl true
  def init(params, _dependencies), do: %{editing?: false, title: params.title}

  def begin_edit(_payload, state), do: %{state | editing?: true}

  def set_title(title, %{editing?: true} = state) when is_binary(title) do
    %{state | title: title}
  end

  def cancel_edit(_payload, _state, _dependencies, _callbacks, params) do
    %{editing?: false, title: params.title}
  end

  @impl true
  def expose(state, _dependencies, params), do: Map.put(state, :id, params.id)
end
```

This keeps per-item local state out of the canonical list while still making
every item controller addressable as `{:task_editor, id}`.

## Read and write state directly

The base API is `Solve.subscribe/3` and `Solve.dispatch/4`.

```elixir
iex> {:ok, app} = MyApp.App.start_link(name: MyApp.App)
iex> Solve.subscribe(app, :counter)
%{count: 0}

iex> :ok = Solve.dispatch(app, :counter, :increment, %{})
iex> Solve.subscribe(app, :counter)
%{count: 1}
```

`Solve.subscribe/3`:

- returns the current exposed state synchronously
- registers the subscriber for future updates
- works with singleton targets, collected child targets, and collection sources

`Solve.dispatch/4`:

- routes an event through the Solve app
- forwards the event to the current controller pid for that target
- becomes a no-op if the target is off or missing

Solve also exposes a few inspection helpers:

- `Solve.controller_pid/2`
- `Solve.controller_events/2`
- `Solve.controller_variant/2`

Use these when a test, worker, or tool needs raw access to the runtime.

## Use Solve.Lookup for process-local access

Use `Solve.Lookup` when a long-running process needs:

- cached reads
- update handling
- direct event refs

`Solve.Lookup` is framework-agnostic. It works in ordinary `GenServer`
processes, workers, and UI processes.

The main helpers are:

- `solve(app, target)` for singleton controllers and collected child targets
- `collection(app, source)` for collection sources
- `events(item)` to read direct event refs
- `event(item, name)` and `event(item, name, payload)` to build direct event
  tuples

Item lookups return the exposed state map augmented with an `:events_` key.
Collection lookups return `%Solve.Collection{ids, items}` whose items are
augmented item maps.

## Use Solve.Lookup in a GenServer

`Solve.Lookup` works well in ordinary `GenServer` processes.

```elixir
defmodule MyApp.CounterWorker do
  use GenServer
  use Solve.Lookup

  def start_link(app) do
    GenServer.start_link(__MODULE__, app, name: __MODULE__)
  end

  @impl true
  def init(app), do: {:ok, %{app: app}}

  @impl true
  def handle_cast(:increment, state) do
    counter = solve(state.app, :counter)

    case event(counter, :increment) do
      {pid, message} -> send(pid, message)
      nil -> :ok
    end

    {:noreply, state}
  end

  def render(%{app: app} = state) do
    IO.inspect(solve(app, :counter), label: "counter")
    state
  end

  @impl Solve.Lookup
  def handle_solve_updated(_updated, state) do
    {:ok, render(state)}
  end
end
```

Key properties:

- the first `solve/2` call subscribes the process and populates its local cache
- later `solve/2` calls read from that cache
- `event(counter, :increment)` gives you a direct `{pid, message}` tuple
- `handle_solve_updated/2` handles the process-specific reaction to Solve state
  changes

`use Solve.Lookup` defaults to `handle_info: :auto`. `%Solve.Message{}`
envelopes refresh the local cache and call `handle_solve_updated/2` for you.

Use `handle_info: :manual` when the process needs to inspect updates itself and
decide which ones matter.

## Use Solve.Lookup in Emerge

`Solve.Lookup` also fits naturally into Emerge viewports.

In Emerge, views read Solve state in `render/0` or `render/1`, bind events from
lookup items, and rerender from `handle_solve_updated/2`.

```elixir
defmodule MyApp.Viewport do
  use Emerge
  use Solve.Lookup

  @impl Viewport
  def render(_state) do
    counter = solve(MyApp.App, :counter)

    row([], [
      button("+", event(counter, :increment)),
      el([], text("Count: #{counter.count}")),
      button("-", event(counter, :decrement))
    ])
  end

  @impl Solve.Lookup
  def handle_solve_updated(_updated, state) do
    {:ok, Viewport.rerender(state)}
  end
end
```

This keeps state reads and event wiring close to the view code that uses them.

## Model larger applications

As an application grows, one controller stops being enough. The common shape is:

- one controller for canonical data
- one or more controllers for derived state
- collection controllers for repeated local item behavior

A task app can be split like this:

| Controller | Owns | Depends on | Purpose |
| --- | --- | --- | --- |
| `:task_list` | canonical task data | none | create, update, delete, toggle tasks |
| `:create_task` | draft input value | none | manage input state and submit new tasks |
| `:filter` | active filter | `:task_list` | expose visible ids derived from task state |
| `{:task_editor, id}` | local edit state for one task | `:task_list` | manage editing UI for a single item |

This is a common Solve structure:

- canonical data in one controller
- derived state in another
- local per-item state in a collection source

Split into separate apps only when parts of your system become genuinely
independent domains. That means they:

- have their own controller graph
- evolve independently
- do not share much internal state ownership
- are composed together at a higher level rather than tightly coordinated

Separate apps also fit when you need different variants of the same graph. A
user-facing app and an admin app can reuse the same core controllers while the
admin app adds moderation, audit, or other admin-only controllers.

Controllers stay reusable because they do not know which app they live in. The
app defines how they are wired together. This works when reused controllers
still receive the dependency keys, params, and callbacks they expect.

One concrete example of this style is the Emerge TodoMVC demo:
[https://github.com/emerge-elixir/emerge/tree/main/example](https://github.com/emerge-elixir/emerge/tree/main/example)

## Pick the right primitive

Use these rules when choosing between Solve primitives:

- Use a singleton controller for one focused state owner.
- Use a dependency when one controller derives state from another.
- Use a callback when one controller requests a write from another.
- Use a collection source when each item needs its own local behavior or state.
- Use `Solve.Lookup` when a process needs cached reads and update-aware event
  wiring.

## Respect the invariants

- Running controller instances expose plain maps.
- Collection sources expose `%Solve.Collection{ids, items}` through
  `Solve.subscribe/3` and `Solve.Lookup.collection/2`.
- `nil` means a singleton or collected child is off or stopped.
- `:events_` is reserved in exposed maps for lookup augmentation.
- `Solve.subscribe/3` returns raw exposed state for singleton targets and
  collection sources.
- `Solve.Lookup.solve/2` returns augmented singleton or collected-child views.
- `Solve.Lookup.collection/2` returns an augmented collection view.

## Keep reading

- `ARCHITECTURE.md` covers the runtime model and lifecycle rules in more detail.

## Acknowledge the influences

Solve draws significant conceptual inspiration from
[Keechma Next](https://github.com/keechma/keechma-next/), especially in its
emphasis on controller-oriented state management, explicit data flow, and
keeping UI structure separate from state structure.
