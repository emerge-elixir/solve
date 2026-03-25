# Solve

Solve manages a graph of controller processes and collection sources.

- Controllers are `GenServer`s.
- A running controller instance exposes a plain map.
- Collection sources materialize as `%Solve.Collection{ids, items}`.
- `nil` means a singleton or collected child is off/stopped.
- `Solve.Lookup` is the main process-facing API.

## Installation

If [available in Hex](https://hex.pm/docs/publish), add `solve` to your dependencies:

```elixir
def deps do
  [
    {:solve, "~> 0.1.0"}
  ]
end
```

## Getting Started

### 1. Define a controller

```elixir
defmodule MyApp.CounterController do
  use Solve.Controller, events: [:increment, :decrement]

  @impl true
  def init(_params, _dependencies) do
    %{count: 0}
  end

  def increment(_payload, state, _dependencies, _callbacks, _params) do
    %{state | count: state.count + 1}
  end

  def decrement(_payload, state, _dependencies, _callbacks, _params) do
    %{state | count: state.count - 1}
  end
end
```

This controller uses the default `expose/3`, so its internal state is also the exposed map.

### 2. Define a Solve app

```elixir
defmodule MyApp.State do
  use Solve

  @impl true
  def controllers do
    [
      controller!(
        name: :counter,
        module: MyApp.CounterController
      )
    ]
  end
end
```

Start the app like any other GenServer:

```elixir
{:ok, app} = MyApp.State.start_link(name: MyApp.State)
```

### 3. Read state from render code with `Solve.Lookup`

```elixir
defmodule EmergeDemo do
  use Emerge
  use Solve.Lookup

  @impl Viewport
  def render(_state) do
    counter = solve(EmergeDemo.State, :counter)

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

`use Solve.Lookup` defaults to `handle_info: :auto`, so `%Solve.Message{}` update envelopes
refresh the local lookup cache and trigger `handle_solve_updated/2`.

Use `event(controller, event_name)` for UI handlers that should send directly to the current
controller pid. Use `event(controller, event_name, payload)` when you want to bake in a fixed
payload. `events/1` still exposes the lower-level `%Solve.Message{}` dispatch refs.

This is the most natural way to use Solve from a UI process: read with `solve/2` inside
`render/1`, build handler tuples with `event/2` or `event/3`, and rerender on
`handle_solve_updated/2`.

For a full Emerge walkthrough, see `examples/emerge_lookup_example.md`.

If you are not using Emerge and want the smaller raw `GenServer` pattern, see
`examples/counter_lookup_example.md`.

For manual control, use `handle_info: :manual` and process `%Solve.Message{}` yourself:

```elixir
def handle_info(nil, state) do
  {:noreply, state}
end

def handle_info(%Solve.Message{} = message, %{app: app} = state) do
  case handle_message(message) do
    %{^app => %Solve.Lookup.Updated{refs: refs}} ->
      if :counter in refs,
        do: {:noreply, render(state)},
        else: {:noreply, state}

    %{} ->
      {:noreply, state}
  end
end

def handle_info(_message, state), do: {:noreply, state}
```

`handle_message/1` returns a map keyed by the actual Solve app ref/pid, so manual handlers
typically match the `app` stored in state.

### 4. Dispatch directly through `Solve`

```elixir
:ok = Solve.dispatch(MyApp.State, :counter, :increment, %{})
counter = Solve.subscribe(MyApp.State, :counter)
# => %{count: 1}
```

### 5. Define a collection source

Collection sources let Solve manage a dynamic ordered set of child controllers.

```elixir
defmodule MyApp.ColumnController do
  use Solve.Controller, events: [:rename]

  @impl true
  def init(%{id: id, title: title}, _dependencies) do
    %{id: id, title: title}
  end

  def rename(title, state, _dependencies, _callbacks, _params) do
    %{state | title: title}
  end

  @impl true
  def expose(state, _dependencies, _params) do
    %{id: state.id, title: state.title}
  end
end

defmodule MyApp.State do
  use Solve

  @impl true
  def controllers do
    [
      controller!(
        name: :column,
        module: MyApp.ColumnController,
        variant: :collection,
        collect: fn %{app_params: %{columns: columns}} ->
          Enum.map(columns, fn %{id: id, title: title} ->
            {id, [params: %{id: id, title: title}]}
          end)
        end
      )
    ]
  end
end
```

`collect/1` returns ordered `{id, opts}` tuples. Solve diffs those ids, compares child `params`
for each `id`, starts or stops child controllers like `{:column, 1}`, and materializes the source
as `%Solve.Collection{}`. Callback changes do not force replacement; Solve updates callbacks in
place when params stay the same.

The lookup side still reads naturally from render code:

```elixir
def render(_state) do
  columns = collection(MyApp.State, :column)

  row([], Enum.map(columns, fn {_id, column} ->
    Input.text([Event.on_change(event(column, :rename))], column.title)
  end))
end
```

## What `solve/2` returns

`solve(app, controller_name)` returns the controller's exposed map augmented with an `:events_` key.

```elixir
%{
  count: 2,
  events_: %{
    increment: %Solve.Message{type: :dispatch, payload: %Solve.Dispatch{...}},
    decrement: %Solve.Message{type: :dispatch, payload: %Solve.Dispatch{...}}
  }
}
```

Use `events/1` to read that key safely:

```elixir
counter = solve(app, :counter)
send(self(), events(counter)[:increment])
```

If the controller is off, `solve/2` returns `nil` and `events(nil)` also returns `nil`. Auto
mode ignores that `nil`, and manual mode can do the same with the `handle_info(nil, state)`
clause shown above.

For Emerge-style event attrs, prefer `event/2` and `event/3`:

```elixir
counter = solve(app, :counter)

button("+", event(counter, :increment))
Input.text([Event.on_change(event(counter, :set_title))], counter.title)
button("Reset", event(counter, :set_mode, :all))
```

`event/2` returns a `{pid, message}` tuple that Emerge can send directly. The helper resolves the
current controller pid from the lookup ref at render time.

## What `collection/2` returns

Use `collection(app, source_name)` for collection sources and `solve(app, {source_name, id})` for
one collected child.

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
      events_: %{rename: %Solve.Message{type: :dispatch, payload: %Solve.Dispatch{...}}}
    },
    2 => %{
      id: 2,
      title: "Doing",
      events_: %{rename: %Solve.Message{type: :dispatch, payload: %Solve.Dispatch{...}}}
    }
  }
}
```

`events/1` returns `nil` for the collection wrapper itself; events live on each item.

## Key Rules

- Running controller instances must expose plain maps.
- Collection sources expose `%Solve.Collection{ids, items}` through `Solve.subscribe/3` and `Solve.Lookup.collection/2`.
- `nil` means a singleton or collected child is off/stopped.
- `:events_` is reserved in exposed maps for lookup augmentation.
- `Solve.subscribe/3` returns raw exposed state for both singleton targets and collection sources.
- `Solve.Lookup.solve/2` returns augmented singleton or collected-child views.
- `Solve.Lookup.collection/2` returns an augmented collection view.

## More Example Code

- `examples/emerge_lookup_example.md` shows the primary render-driven `Solve.Lookup` flow
- `examples/counter_lookup_example.md` shows the smaller non-Emerge and manual `handle_info` flow
