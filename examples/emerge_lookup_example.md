# Emerge Lookup Example

This is the main `Solve.Lookup` style to copy.

- read state in `render/1`
- build UI handlers with `event/2` and `event/3`
- rerender from `handle_solve_updated/2`

It mirrors the `EmergeDemo` pattern used in the local Emerge example app.

## Singleton Lookup In `render/1`

```elixir
defmodule EmergeDemo do
  use Emerge
  use Solve.Lookup

  @impl Viewport
  def render(_state) do
    counter = solve(EmergeDemo.State, :counter)

    column([], [
      row([], [
        button("+", event(counter, :increment)),
        el([], text("Count: #{counter.count}")),
        button("-", event(counter, :decrement))
      ])
    ])
  end

  @impl Solve.Lookup
  def handle_solve_updated(_updated, state) do
    {:ok, Viewport.rerender(state)}
  end
end
```

Why this feels good:

- the first `solve/2` call subscribes the viewport process
- later `solve/2` calls read from the local lookup cache
- `event(counter, :increment)` gives you an Emerge-ready `{pid, message}` tuple
- `handle_solve_updated/2` can stay tiny and just trigger a rerender

Use `event(controller, event_name)` when Emerge should provide the payload later, like
`Event.on_change(event(form, :set_title))`. Use `event(controller, event_name, payload)` when the
payload is fixed at render time.

## Collection Lookup Uses The Same Pattern

If the state module exposes a collection source, read it directly in `render/1`.

```elixir
def render(_state) do
  columns = collection(MyApp.State, :column)

  row([], Enum.map(columns, fn {_id, column} ->
    Input.text([Event.on_change(event(column, :rename))], column.title)
  end))
end
```

`collection/2` returns `%Solve.Collection{ids, items}`, but because it implements `Enumerable`, UI
code can iterate it directly.

Each item is a normal lookup result:

```elixir
column = solve(MyApp.State, {:column, 1})
Input.text([Event.on_change(event(column, :rename))], column.title)
```

Important rules:

- `events(collection(...))` returns `nil`
- events live on the items inside the collection
- `event/2` and `event/3` only work on lookup item maps, not the collection wrapper
- `solve(app, :column)` is for singletons only; use `collection(app, :column)` for collection sources

## Collection Source Definition

The source side is still just a `Solve` controller spec.

```elixir
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

`collect/1` returns ordered `{id, opts}` tuples. Solve diffs those ids, manages child controllers
like `{:column, 1}`, and exposes the source as `%Solve.Collection{}`.

## When To Use The Smaller GenServer Example

Use `examples/counter_lookup_example.md` when you want:

- the smallest possible `GenServer` example
- manual `handle_info: :manual`
- direct `handle_message/1` control outside a render loop
