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
{:ok, _pid} = MyApp.State.start_link(name: MyApp.State)
```

### 3. Use it from another process with `Solve.Lookup`

```elixir
defmodule MyApp.CounterWorker do
  use GenServer
  use Solve.Lookup

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  def increment do
    counter = solve(MyApp.State, :counter)
    send(self(), events(counter)[:increment])
  end

  def decrement do
    counter = solve(MyApp.State, :counter)
    send(self(), events(counter)[:decrement])
  end

  def render(state) do
    counter = solve(MyApp.State, :counter)
    IO.inspect(counter, label: "counter")
    state
  end
end
```

`use Solve.Lookup` defaults to `on_update: :render`, so `render/1` is called after lookup cache updates.

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
    increment: %Solve.Lookup.Dispatch{...},
    decrement: %Solve.Lookup.Dispatch{...}
  }
}
```

Use `events/1` to read that key safely:

```elixir
counter = solve(MyApp.State, :counter)
send(self(), events(counter)[:increment])
```

If the controller is off, `solve/2` returns `nil` and `events(nil)` also returns `nil`, so the same pattern stays safe.

## Key Rules

- Running controllers must expose plain maps.
- `nil` means a controller is off/stopped.
- `:events_` is reserved in exposed maps for lookup augmentation.
- `Solve.subscribe/3` returns raw exposed state.
- `Solve.Lookup.solve/2` returns the augmented process-local view.

## More Example Code

See `examples/counter_lookup_example.md` for a full end-to-end example with a controller, a
`Solve` app, and a GenServer using `Solve.Lookup`.
