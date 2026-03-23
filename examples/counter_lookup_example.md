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
{:ok, app} = MyApp.State.start_link(name: MyApp.State)
```

## GenServer Using `Solve.Lookup`

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

`use Solve.Lookup` defaults to:

- `handle_info: :auto`

That means:

- the first `solve/2` call subscribes this process to the controller
- the latest exposed map is cached in the process dictionary
- every `%Solve.Message{type: :update, ...}` refreshes that cache
- non-empty updates are passed to `handle_solve_updated/2`

If you prefer explicit handling, use `handle_info: :manual` and match `%Solve.Message{}`
yourself:

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

def handle_info(_message, state) do
  {:noreply, state}
end
```

`handle_message/1` returns a map keyed by the actual Solve app ref/pid, so manual handlers
typically match the `app` stored in state.

## What `solve/2` returns

`solve(app, :counter)` returns the controller's exposed map augmented with `:events_`.

```elixir
%{
  count: 0,
  events_: %{
    increment: %Solve.Message{type: :dispatch, payload: %Solve.Dispatch{...}},
    decrement: %Solve.Message{type: :dispatch, payload: %Solve.Dispatch{...}}
  }
}
```

Use `events/1` to access those refs safely:

```elixir
counter = solve(app, :counter)
send(self(), events(counter)[:increment])
```

If the controller is off, `solve/2` returns `nil` and `events(nil)` also returns `nil`. Auto
mode ignores that `nil`, and manual mode can do the same with the `handle_info(nil, state)`
clause shown above.

## Starting Everything

```elixir
{:ok, app} = MyApp.State.start_link(name: MyApp.State)
{:ok, _worker_pid} = MyApp.CounterWorker.start_link(app)

MyApp.CounterWorker.increment()
MyApp.CounterWorker.increment()
MyApp.CounterWorker.decrement()
```

The worker will print something like:

```elixir
counter: %{count: 1, events_: %{decrement: %Solve.Message{...}, increment: %Solve.Message{...}}}
counter: %{count: 2, events_: %{decrement: %Solve.Message{...}, increment: %Solve.Message{...}}}
counter: %{count: 1, events_: %{decrement: %Solve.Message{...}, increment: %Solve.Message{...}}}
```

## Process-Local Cache

`Solve.Lookup` keeps one private ref per app/controller in the process dictionary under:

```elixir
{:solve_lookup_ref, app, controller_name}
```

That ref contains:

- the current raw exposed map or `nil`
- prebuilt event dispatch envelopes
- subscription bookkeeping for the current process

## Key Rules

- Running controllers must expose plain maps.
- `nil` means the controller is off/stopped.
- `:events_` is reserved for lookup augmentation.
- `Solve.subscribe/3` returns raw exposed state.
- `Solve.Lookup.solve/2` returns the augmented process-local view.
