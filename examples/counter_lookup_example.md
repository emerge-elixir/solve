# Counter Lookup Example

This is the smaller non-Emerge example.

- one singleton controller
- one `Solve` app
- one plain `GenServer` using `Solve.Lookup`

If you are rendering UI, start with `examples/emerge_lookup_example.md` instead.

## Controller And Solve App

```elixir
defmodule MyApp.CounterController do
  use Solve.Controller, events: [:increment, :decrement]

  @impl true
  def init(_params, _dependencies), do: %{count: 0}

  def increment(_payload, state) do
    %{state | count: state.count + 1}
  end

  def decrement(_payload, state) do
    %{state | count: state.count - 1}
  end
end

defmodule MyApp.State do
  use Solve

  @impl true
  def controllers do
    [controller!(name: :counter, module: MyApp.CounterController)]
  end
end
```

## Auto `Solve.Lookup`

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

    case events(counter)[:increment] do
      {pid, message} -> send(pid, message)
      nil -> :ok
    end

    {:noreply, state}
  end

  def render(state) do
    IO.inspect(solve(state.app, :counter), label: "counter")
    state
  end

  @impl Solve.Lookup
  def handle_solve_updated(_updated, state) do
    {:ok, render(state)}
  end
end
```

`use Solve.Lookup` defaults to `handle_info: :auto`, so `%Solve.Message{}` update envelopes refresh
the local cache and call `handle_solve_updated/2`.

## Manual `handle_info`

Use `handle_info: :manual` when you want explicit control.

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

  def render(state) do
    IO.inspect(solve(state.app, :counter), label: "counter")
    state
  end
end
```

## What `solve/2` Returns

```elixir
%{
  count: 1,
  events_: %{
    increment: {#PID<...>, {:solve_event, :increment}},
    decrement: {#PID<...>, {:solve_event, :decrement}}
  }
}
```

Use `events/1` to read those refs safely:

```elixir
counter = solve(app, :counter)
{pid, message} = events(counter)[:increment]
send(pid, message)
```

If the controller is off, `solve/2` returns `nil` and `events(nil)` also returns `nil`.
