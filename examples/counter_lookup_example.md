# Counter Lookup Example

This example shows `Solve.Lookup` from an ordinary `GenServer`.

Use this pattern when a long-running process wants process-local cached reads, direct event refs,
and update handling without depending on Emerge.

- one singleton controller
- one `Solve` app
- one plain `GenServer` using `Solve.Lookup`

For the main overview, see `README.md`. If you are rendering with Emerge, see
`examples/emerge_lookup_example.md`.

## Controller And Solve App

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
    [controller!(name: :counter, module: MyApp.CounterController)]
  end
end
```

## Auto `Solve.Lookup` In A `GenServer`

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

What this pattern provides:

- the first `solve/2` call subscribes the worker and populates its local cache
- later `solve/2` calls read from that cache
- `event(counter, :increment)` gives you a direct `{pid, message}` tuple you can send immediately
- `handle_solve_updated/2` handles only the process-specific reaction to Solve state changes

`use Solve.Lookup` defaults to `handle_info: :auto`, so `%Solve.Message{}` update envelopes refresh
the local cache and call `handle_solve_updated/2` for you.

## Manual `handle_info`

Use `handle_info: :manual` when you want explicit control over which Solve updates trigger work.

```elixir
defmodule MyApp.ManualCounterWorker do
  use GenServer
  use Solve.Lookup, handle_info: :manual

  @impl true
  def init(app), do: {:ok, %{app: app}}

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

  def handle_info(_message, state) do
    {:noreply, state}
  end

  def render(%{app: app} = state) do
    IO.inspect(solve(app, :counter), label: "counter")
    state
  end
end
```

Choose this variant when the process wants to inspect `Solve.Lookup.handle_message/1` itself and
decide which updates matter.

## What `solve/2` Returns

`solve(app, :counter)` returns the controller's exposed map augmented with an `:events_` key.

```elixir
%{
  count: 1,
  events_: %{
    increment: {#PID<...>, {:solve_event, :increment}},
    decrement: {#PID<...>, {:solve_event, :decrement}}
  }
}
```

Use `events/1` when you want to read those refs directly:

```elixir
counter = solve(app, :counter)
{pid, message} = events(counter)[:increment]
send(pid, message)
```

`event(counter, :increment)` returns the same tuple as `events(counter)[:increment]`.

If the controller is off, `solve/2` returns `nil`, `events(nil)` returns `nil`, and
`event(nil, :increment)` also returns `nil`.

## When To Use This Pattern

Use this style when:

- a `GenServer` or worker process wants cached reads from Solve
- the process should react to updates over time
- you want direct event refs without a render loop
- you want the option to drop into manual `handle_info` control
