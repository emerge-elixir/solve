# Solve

Solve is a state management framework for UI-heavy Elixir applications.

Solve organizes state around controller dependencies, not component hierarchy. The result is an acyclic state graph that can fan out, share upstream nodes, and terminate in multiple leaves. UI layout and state structure stay separate: the UI may be rendered as a tree, while state is modeled as an acyclic dependency graph of controllers.

Each controller owns one slice of behavior and state, exposes a plain map, and can depend on other controllers. Solve validates the graph on boot and rejects circular dependencies.

## What Solve Gives You

- Small, focused state owners instead of one large application process
- Explicit dependencies between state owners
- Derived state without pushing that logic into the UI layer
- Collection support for repeated item controllers
- Explicit cross-controller writes through dispatch and callbacks
- The ability to read state where a process needs it, which reduces the need to thread large state and handler bundles through nested UI helpers

## Installation

If available in Hex, add `solve` to your dependencies:

```elixir
def deps do
  [
    {:solve, "~> 0.1.0"}
  ]
end
```

## Core Ideas

- **Solve app** - the coordinating `GenServer` that owns the controller graph
- **controller** - a `GenServer` that owns one slice of state and behavior
- **exposed state** - the plain map a controller shares with subscribers, dependents, and UI code
- **dependency** - another controller's exposed state made available to a controller
- **callback** - a function passed from the app into a controller for explicit cross-controller writes
- **collection source** - a controller spec that manages many item controllers like `{:todo, 1}` or `{:todo, 2}`
- **Solve.Lookup** - a process-local read API that keeps a local view of Solve state and builds direct event refs

Declared event handlers can take the leading subset of runtime inputs they need: `payload`, `state`, `dependencies`, `callbacks`, and `init_params`.

## Smallest Working Example

Start with one controller and one Solve app.

```elixir
defmodule MyApp.CounterController do
  use Solve.Controller, events: [:increment, :decrement]

  @impl true
  def init(_params, _dependencies), do: %{count: 0}

  def increment(_payload, state), do: %{state | count: state.count + 1}
  def decrement(_payload, state), do: %{state | count: state.count - 1}
end

defmodule MyApp.State do
  use Solve

  @impl true
  def controllers do
    [
      controller!(name: :counter, module: MyApp.CounterController)
    ]
  end
end
```

Start the app like any other `GenServer`:

```elixir
{:ok, app} = MyApp.State.start_link(name: MyApp.State)
```

In this example:

- `MyApp.State` defines the controller graph
- `:counter` is a singleton controller source
- the controller owns its internal state
- the exposed state is the same map because it uses the default `expose/3`

## Using Solve Directly

The lowest-level way to interact with Solve is through `dispatch` and `subscribe`.

```elixir
iex> {:ok, app} = MyApp.State.start_link(name: MyApp.State)
iex> Solve.subscribe(app, :counter)
%{count: 0}

iex> :ok = Solve.dispatch(app, :counter, :increment, %{})
iex> Solve.subscribe(app, :counter)
%{count: 1}
```

`Solve.dispatch/4` sends an event to a controller. `Solve.subscribe/2` returns the current exposed state and subscribes the caller to future updates.

This API is enough when you want to work with Solve directly from another process or from tests.

## Reading State From A Process With Solve.Lookup

When a process wants to keep a local, process-friendly view of Solve state, use `Solve.Lookup`.

`Solve.Lookup` is designed to fit Emerge's render/event loop especially well, but it is not limited to Emerge. It also supports ordinary `GenServer` processes and other long-running processes that want local cached reads and update handling.

The main helpers are:

- `solve(app, target)` for singleton controllers and collection items
- `collection(app, source)` for collection sources
- `events(item)` to read a controller's direct event refs
- `event(item, name)` and `event(item, name, payload)` to build direct handler tuples

If you already know the id of a collection item, read it directly:

```elixir
todo = solve(app, {:todo, 42})
```

Use `collection(app, :todo)` when you want the full ordered collection.

## Solve.Lookup With Emerge

With Emerge, the standard `Solve.Lookup` pattern is: read state in `render/1`, bind events directly from lookup items, and rerender when Solve updates arrive.

```elixir
defmodule MyApp.Viewport do
  use Emerge
  use Solve.Lookup

  @impl Viewport
  def render(_state) do
    counter = solve(MyApp.State, :counter)

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

This keeps rendering code local to the view layer. View helpers can read the state they need where they render instead of relying on large parent-owned state bundles.

For a fuller Emerge example, see `examples/emerge_lookup_example.md`.

## Solve.Lookup With Any GenServer

Solve.Lookup also works outside Emerge.

```elixir
defmodule MyApp.CounterWorker do
  use GenServer
  use Solve.Lookup

  def start_link(app) do
    GenServer.start_link(__MODULE__, app, name: __MODULE__)
  end

  @impl true
  def init(app), do: {:ok, %{app: app}}

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

Use this style when a long-running process wants cached reads and automatic update handling without depending on Emerge.

For the GenServer-focused example, see `examples/counter_lookup_example.md`.

## Modeling A Real App

The [Emerge TodoMVC example](https://github.com/emerge-elixir/emerge/tree/main/example) shows how Solve scales from a single controller into a small state graph.

The controller graph is defined in one place:

```elixir
def controllers do
  [
    controller!(name: :todo_list, module: TodoApp.TodoList),
    controller!(
      name: :create_todo,
      module: TodoApp.CreateTodo,
      callbacks: %{
        submit: fn title -> dispatch(:todo_list, :create_todo, title) end
      }
    ),
    controller!(
      name: :filter,
      module: TodoApp.Filter,
      dependencies: [:todo_list]
    ),
    controller!(
      name: :todo_editor,
      module: TodoApp.TodoEditor,
      variant: :collection,
      dependencies: [:todo_list],
      callbacks: %{
        save_edit: fn id, title -> dispatch(:todo_list, :update_todo, %{id: id, title: title}) end
      },
      collect: fn %{dependencies: %{todo_list: todo_list}} ->
        Enum.map(todo_list.ids, fn id ->
          {id, [params: %{id: id, title: todo_list.todos[id].title}]}
        end)
      end
    )
  ]
end
```

That graph separates responsibilities cleanly:

| Controller | Owns | Depends on | Purpose |
| --- | --- | --- | --- |
| `:todo_list` | canonical todo data | none | create, update, delete, toggle todos |
| `:create_todo` | the draft input value | none | manage input state and submit new todos |
| `:filter` | active filter | `:todo_list` | expose visible ids derived from todo state |
| `{:todo_editor, id}` | local edit state for one todo | `:todo_list` | manage editing UI for a single item |

This is a core Solve pattern: keep canonical data, derived state, and local UI state in separate controllers with explicit relationships.

## Dependencies, Callbacks, And Collections

These three features carry most of the architectural weight in a larger Solve app.

### Dependencies

Use dependencies when one controller needs another controller's exposed state as input.

The filter controller depends on `:todo_list` and computes visible ids in `expose/3`:

```elixir
defmodule TodoApp.Filter do
  use Solve.Controller, events: [:set]

  @filters [:all, :active, :completed]

  @impl true
  def init(_params, _dependencies), do: %{active: :all}

  def set(filter, _state) when filter in @filters, do: %{active: filter}
  def set(_filter, state), do: state

  @impl true
  def expose(state, %{todo_list: todo_list}, _params) do
    %{
      filters: @filters,
      active: state.active,
      visible_ids: visible_ids(state.active, todo_list)
    }
  end

  defp visible_ids(:all, %{ids: ids}), do: ids

  defp visible_ids(:active, %{ids: ids, todos: todos}) do
    Enum.reject(ids, fn id -> todos[id].completed? end)
  end

  defp visible_ids(:completed, %{ids: ids, todos: todos}) do
    Enum.filter(ids, fn id -> todos[id].completed? end)
  end
end
```

This keeps filtering logic out of the UI. The UI asks for visible ids, and the controller decides how they are derived.

### Callbacks

Use callbacks when one controller should trigger another controller's write explicitly.

Because a Solve app is an acyclic dependency graph, a controller should not reach back into upstream controllers directly. Dependencies make downstream data flow explicit by declaring what a controller reads from elsewhere in the graph. Callbacks do the same for upstream writes: they make it explicit when a controller needs to request a change from a controller that owns state elsewhere in the graph.

In the TodoMVC demo, `:create_todo` owns the text input state, but `:todo_list` owns the actual todo collection. The app wires those two together with a callback:

```elixir
controller!(
  name: :create_todo,
  module: TodoApp.CreateTodo,
  callbacks: %{
    submit: fn title -> dispatch(:todo_list, :create_todo, title) end
  }
)
```

The controller remains responsible for its own state transition logic:

```elixir
def submit(_payload, state, _dependencies, callbacks) do
  case String.trim(state.title) do
    "" ->
      %{title: ""}

    title ->
      callbacks.submit.(title)
      %{title: ""}
  end
end
```

This makes upstream writes explicit in the same way dependencies make downstream reads explicit, while keeping state ownership clear.

### Collections

Use collection sources when you need many similar controllers, one per item.

The TodoMVC demo models per-item editing with a collection source:

```elixir
controller!(
  name: :todo_editor,
  module: TodoApp.TodoEditor,
  variant: :collection,
  dependencies: [:todo_list],
  collect: fn %{dependencies: %{todo_list: todo_list}} ->
    Enum.map(todo_list.ids, fn id ->
      {id, [params: %{id: id, title: todo_list.todos[id].title}]}
    end)
  end
)
```

Each item controller then owns only its local edit behavior:

```elixir
defmodule TodoApp.TodoEditor do
  use Solve.Controller, events: [:begin_edit, :cancel_edit, :set_title, :save_edit]

  @impl true
  def init(params, _dependencies), do: %{editing?: false, title: params.title}

  def begin_edit(_payload, state), do: %{state | editing?: true}
  def set_title(title, %{editing?: true} = state) when is_binary(title), do: %{state | title: title}
  def cancel_edit(_payload, _state, _dependencies, _callbacks, params), do: %{editing?: false, title: params.title}

  def expose(state, _dependencies, params), do: Map.put(state, :id, params.id)
end
```

This keeps local item UI state out of the canonical todo list while still making every editor controller addressable as `{:todo_editor, id}`.

## How UI Code Stays Clean

Solve lets UI code stay close to rendering and interaction wiring.

In the TodoMVC demo, view helpers read exactly the state they need with `solve(...)`:

```elixir
def todo_list() do
  filter = solve(TodoApp, :filter)

  column([], Enum.map(filter.visible_ids, &todo_row/1))
end

defp todo_row(todo_id) do
  todo_editor = solve(TodoApp, {:todo_editor, todo_id})

  if todo_editor.editing? do
    editing_row(todo_editor)
  else
    regular_row(todo_id)
  end
end

defp regular_row(todo_id) do
  todo = solve(TodoApp, :todo_list).todos[todo_id]

  row([], [toggle_button(todo), title_button(todo), destroy_button(todo_id)])
end
```

That keeps state access close to the code that renders it. Shared state can still be shared, but it does not have to be threaded through unrelated helpers just because they sit higher in the UI tree.

The same applies to event wiring:

```elixir
Event.on_change(event(create_todo, :set_title))
Event.on_press(event(todo_list, :toggle_todo, todo.id))
Event.on_press(event(filter, :set, filter_name))
Event.on_blur(event(todo_editor, :save_edit))
```

UI helpers bind directly to the controller that owns the behavior.

## End-To-End Flow: Create A Todo

The create flow shows how several small controllers work together without collapsing into one state owner.

1. The input field reads `:create_todo` and sends `:set_title` and `:submit` events.
2. `:create_todo` owns the draft input value.
3. On submit, `:create_todo` validates the title and calls its `submit` callback.
4. That callback dispatches `:create_todo` to `:todo_list`.
5. `:todo_list` creates the canonical todo.
6. `:filter` recomputes visible ids from the updated todo list.
7. The `:todo_editor` collection is reconciled so a per-item editor exists for the new todo.
8. Any subscribed process rerenders through `Solve.Lookup`.

This illustrates Solve's style: each controller does one job, dependencies stay explicit, and the state graph grows by adding specialized nodes instead of expanding one central process.

## What `solve/2` Returns

`solve(app, controller_name)` returns the controller's exposed map augmented with an `:events_` key.

```elixir
%{
  count: 2,
  events_: %{
    increment: {#PID<...>, {:solve_event, :increment}},
    decrement: {#PID<...>, {:solve_event, :decrement}}
  }
}
```

Use `events/1` to read that key safely:

```elixir
counter = solve(app, :counter)
{pid, message} = events(counter)[:increment]
send(pid, message)
```

If the controller is off, `solve/2` returns `nil` and `events(nil)` also returns `nil`.

For Emerge-style event attrs, prefer `event/2` and `event/3`:

```elixir
counter = solve(app, :counter)

button("+", event(counter, :increment))
Input.text([Event.on_change(event(counter, :set_title))], counter.title)
button("Reset", event(counter, :set_mode, :all))
```

`event/2` returns the same direct `{pid, message}` tuple as `events(counter)[:increment]`, and `event/3` adds a fixed payload to that tuple.

## What `collection/2` Returns

Use `collection(app, source_name)` for collection sources and `solve(app, {source_name, id})` for one collected child.

```elixir
columns = collection(app, :column)

Enum.map(columns, fn {id, column} ->
  {id, column.title, Event.on_change(event(column, :rename))}
end)

column = solve(app, {:column, 1})
{pid, message} = event(column, :rename, "Backlog")
send(pid, message)
```

`collection/2` returns a `%Solve.Collection{}` whose items are the normal lookup item maps:

```elixir
%Solve.Collection{
  ids: [1, 2],
  items: %{
    1 => %{
      id: 1,
      title: "Todo",
      events_: %{rename: {#PID<...>, {:solve_event, :rename}}}
    },
    2 => %{
      id: 2,
      title: "Doing",
      events_: %{rename: {#PID<...>, {:solve_event, :rename}}}
    }
  }
}
```

`events/1` returns `nil` for the collection wrapper itself; events live on each item.

## When To Reach For Which Tool

- Use a singleton controller for one focused state owner.
- Use a dependency when one controller derives state from another.
- Use a callback when one controller should trigger another controller's write explicitly.
- Use a collection source when each item needs its own local behavior or state.
- Use `Solve.Lookup` when a process wants local cached reads and update-aware event wiring.

## Key Rules

- Running controller instances must expose plain maps.
- Collection sources expose `%Solve.Collection{ids, items}` through `Solve.subscribe/3` and `Solve.Lookup.collection/2`.
- `nil` means a singleton or collected child is off or stopped.
- `:events_` is reserved in exposed maps for lookup augmentation.
- `Solve.subscribe/3` returns raw exposed state for both singleton targets and collection sources.
- `Solve.Lookup.solve/2` returns augmented singleton or collected-child views.
- `Solve.Lookup.collection/2` returns an augmented collection view.

## Further Reading

- `examples/counter_lookup_example.md` shows `Solve.Lookup` in an ordinary `GenServer`, including manual `handle_info`.
- `examples/emerge_lookup_example.md` shows the render-driven `Solve.Lookup` flow with Emerge.
- `ARCHITECTURE.md` covers the runtime model and lifecycle rules in more detail.
- [Emerge TodoMVC example](https://github.com/emerge-elixir/emerge/tree/main/example) is the full Emerge + Solve application.

## Attribution

Solve draws significant conceptual inspiration from
[Keechma Next](https://github.com/keechma/keechma-next/), especially in its emphasis on
controller-oriented state management, explicit data flow, and keeping UI structure separate from
state structure.
