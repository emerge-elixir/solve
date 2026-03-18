# Counter Lookup Example

This example shows the smallest end-to-end Solve setup:

- a controller implemented as a `GenServer`
- a `Solve` app that starts and manages that controller
- another process using `Solve.Lookup` to read state and dispatch events

## Controller

```elixir
defmodule MyApp.CounterController do
  use Solve.Controller, events: [:increment, :decrement]

  @impl true
  def init(_params, _dependencies) do
    %{count: 0}
  end

  def increment(_payload, state, _dependencies, _callbacks, _init_params) do
    %{state | count: state.count + 1}
  end

  def decrement(_payload, state, _dependencies, _callbacks, _init_params) do
    %{state | count: state.count - 1}
  end
end
```

This controller uses the default `expose/3`, so its internal state is also the exposed state.
Because running controllers must expose plain maps, `%{count: 0}` is both valid internal state
and valid exposed state.

## Solve App

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

## GenServer Using `Solve.Lookup`

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

`use Solve.Lookup` defaults to:

- `handle_info: true`
- `on_update: :render`

That means:

- the first `solve/2` call subscribes this process to the controller
- the latest exposed map is cached in the process dictionary
- every `{:solve_update, ...}` refreshes that cache
- `render/1` is called after each cache refresh

## What `solve/2` returns

`solve(MyApp.State, :counter)` returns the controller's exposed map augmented with `:events_`.

```elixir
%{
  count: 0,
  events_: %{
    increment: %Solve.Lookup.Dispatch{...},
    decrement: %Solve.Lookup.Dispatch{...}
  }
}
```

Use `events/1` to access those refs safely:

```elixir
counter = solve(MyApp.State, :counter)
send(self(), events(counter)[:increment])
```

If the controller is off, `solve/2` returns `nil` and `events(nil)` also returns `nil`, so the
same pattern still works.

## Starting Everything

```elixir
{:ok, _state_pid} = MyApp.State.start_link(name: MyApp.State)
{:ok, _worker_pid} = MyApp.CounterWorker.start_link()

MyApp.CounterWorker.increment()
MyApp.CounterWorker.increment()
MyApp.CounterWorker.decrement()
```

The worker will print something like:

```elixir
counter: %{count: 0, events_: %{decrement: %Solve.Lookup.Dispatch{...}, increment: %Solve.Lookup.Dispatch{...}}}
counter: %{count: 1, events_: %{decrement: %Solve.Lookup.Dispatch{...}, increment: %Solve.Lookup.Dispatch{...}}}
counter: %{count: 2, events_: %{decrement: %Solve.Lookup.Dispatch{...}, increment: %Solve.Lookup.Dispatch{...}}}
counter: %{count: 1, events_: %{decrement: %Solve.Lookup.Dispatch{...}, increment: %Solve.Lookup.Dispatch{...}}}
```

## Process-Local Cache

`Solve.Lookup` keeps one private ref per app/controller in the process dictionary under:

```elixir
{:solve_lookup_ref, app, controller_name}
```

That ref contains:

- the current raw exposed map or `nil`
- prebuilt event dispatch structs
- subscription bookkeeping for the current process

## Key Rules

- Running controllers must expose plain maps.
- `nil` means the controller is off/stopped.
- `:events_` is reserved for lookup augmentation.
- `Solve.subscribe/3` returns raw exposed state.
- `Solve.Lookup.solve/2` returns the augmented process-local view.
