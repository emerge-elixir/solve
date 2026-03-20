# Solve

Solve manages a graph of controller processes.

- Controllers are `GenServer`s.
- A running controller exposes a plain map.
- `nil` means a controller is off/stopped.
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

### 3. Use it from another process with `Solve.Lookup`

```elixir
defmodule MyApp.CounterWorker do
  use GenServer
  use Solve.Lookup

  def start_link(app) do
    GenServer.start_link(__MODULE__, app, name: __MODULE__)
  end

  def increment do
    GenServer.cast(__MODULE__, :increment)
  end

  def decrement do
    GenServer.cast(__MODULE__, :decrement)
  end

  @impl true
  def init(app) do
    {:ok, %{app: app}}
  end

  @impl true
  def handle_cast(:increment, state) do
    counter = solve(state.app, :counter)
    send(self(), events(counter)[:increment])
    {:noreply, state}
  end

  @impl true
  def handle_cast(:decrement, state) do
    counter = solve(state.app, :counter)
    send(self(), events(counter)[:decrement])
    {:noreply, state}
  end

  def render(state) do
    counter = solve(state.app, :counter)
    IO.inspect(counter, label: "counter")
    state
  end

  @impl Solve.Lookup
  def handle_solve_updated(_updated, state) do
    {:ok, render(state)}
  end
end
```

`use Solve.Lookup` defaults to `handle_info: :auto`, so `%Solve.Message{}` update envelopes
refresh the local lookup cache and trigger `handle_solve_updated/2`.

For manual control, use `handle_info: :manual` and process `%Solve.Message{}` yourself:

```elixir
def handle_info(nil, state) do
  {:noreply, state}
end

def handle_info(%Solve.Message{} = message, %{app: app} = state) do
  case handle_message(message) do
    %{^app => controllers} ->
      if :counter in controllers,
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

## Key Rules

- Running controllers must expose plain maps.
- `nil` means a controller is off/stopped.
- `:events_` is reserved in exposed maps for lookup augmentation.
- `Solve.subscribe/3` returns raw exposed state.
- `Solve.Lookup.solve/2` returns the augmented process-local view.

## More Example Code

See `examples/counter_lookup_example.md` for a full end-to-end example with a controller, a
`Solve` app, and a GenServer using `Solve.Lookup`.
