# Solve

[![Hex.pm](https://img.shields.io/hexpm/v/solve.svg)](https://hex.pm/packages/solve)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/solve)
[![CI](https://img.shields.io/badge/CI-GitHub_Actions-2088FF?logo=githubactions&logoColor=white)](https://github.com/emerge-elixir/solve/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/emerge-elixir/solve.svg)](https://github.com/emerge-elixir/solve/blob/main/LICENSE)

Solve is a UI application framework.

It provides tools to model an application as a hierarchy of reusable components,
without concerns about how the application is presented to the user or
how user inputs are routed to the application.

To create a usable application, you will have to pair it with a presentation layer
such as Emerge, LiveView, or something else.

If you are coming from LiveView, you can think of it as the assigns + handle_event
part of your LiveView. If you are coming from React, imagine if everything used hooks
and all of your state was managed outside the component hierarchy. From the Elm perspective,
it would be your model + update function without the render function.

This kind of separation unlocks interesting use cases, such as interacting with the same
application from different sources. For example, multiple Nerves devices alongside a web interface at the same time.

It also allows an application to scale to a much higher degree of complexity while
retaining a clear overview of how data flows between components, since lifecycles of components
are not lumped together with rendering code. Testing situation also improves allowing
for testing parts of application in isolation.


## Installation

Add `solve` to your dependencies:

```elixir
def deps do
  [
    {:solve, "~> 0.2.2"}
  ]
end
```

## Writing an application 

Building block of Solve application is a **controller**, for a controller to
do anything it has to live inside of an **application**. Here is a simplest
solve application you can make.

```elixir
defmodule MyApp.Hello do
  use Solve.Controller

  @impl Solve.Controller 
  def init(_params, _dependencies), do: %{hello: "Hello"}
end

defmodule MyApp.App do
  use Solve

  @impl Solve
  def controllers, do: [controller!(name: :hello, module: MyApp.Hello)]
end
```

First module defines controller module that initializes with
internal state of `%{hello: "Hello"}`

Second module defines an app that starts that controller under a name
`:hello`


You can start an app like any GenServer
```
iex(4)> {:ok, app_pid} = MyApp.App.start_link()
{:ok, #PID<0.194.0>}
```
and subscribe to a controller data
```
iex(5)> Solve.subscribe(app_pid, :hello)
%{hello: "Hello"}
```
Subscribing to a controller returns it currently exposed data and
you also receive a message with new information whenever it changes.

## Exposing data

By default controller exposes it's internal state, that can be modified
by implementing `expose` function. Result of expose needs to be elixir
map.


```elixir
defmodule MyApp.Hello do
  use Solve.Controller

  @impl Solve.Controller 
  def init(_params, _dependencies), do: %{hello: "Hello"}

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    %{exposed: "#{state.hello} World"}
  end
end
```

Subscribing to hello now returns result of expose function

```
iex(10)> {:ok, app_pid} = MyApp.App.start_link()
{:ok, #PID<0.235.0>}
iex(11)> Solve.subscribe(app_pid, :hello)
%{exposed: "Hello World"}
```

## I have params therfore I am

Each controller in an application is defined by a name
but its lifecycle is determined by params.

In our earlier example we didn't provide `params` for controller in our app
```elixir
 controller!(name: :hello, module: MyApp.Hello)
```
in that case solve defaults to
```elixir
 controller!(name: :hello, module: MyApp.Hello, params: fn _ -> true end)
```
which means basically means "this controller always running". If we change that to
```elixir
 controller!(name: :hello, module: MyApp.Hello, params: fn _ -> false end)
```
then controller will never turn on and it will expose `nil`.
```
iex(3)> {:ok, app_pid} = MyApp.App.start_link()
{:ok, #PID<0.194.0>}
iex(4)> Solve.subscribe(app_pid, :hello)
nil
```

## If my params change am I still me?

Params with any truthy value will signal an application to turn on a controller,
however if result of params function change it will affect controller in following way:

| Prev   | Current | Prev == Current | Actions |
| -----  | ------  | ----------------| --------- |
| falsy  | falsy   | -               | Do nothing (controller is not running) |
| truthy | falsy   | -               | Stop the current controller process     |
| falsy  | truthy  | -               | Start a new controller process |
| truthy | truthy  | false           | Stop the current controller process and start a new one |
| truthy | truthy  | true            | Do nothing (controller is running)|

Important state change to notice is from one truthy value to different
truthy value, in that case app will stop current process and start a new one.

We will get to how params can change but let's introduce some concepts first.

## Events I encounter change me

Solve controllers receive user actions through events.
Here is an example of counter that implements `increment` and `decrement` events.

```elixir
defmodule MyApp.Counter do
  use Solve.Controller, events: [:increment, :decrement]

  @impl Solve.Controller 
  def init(_params, _dependencies), do: %{count: 0}

  def increment(_payload = nil, state = %{count: count}), do: %{state | count: count + 1}
  def increment(val, state = %{count: count}), do: %{state | count: count + val}

  def decrement(_payload = nil, state = %{count: count}), do: %{state | count: count - 1}
  def decrement(val, state = %{count: count}), do: %{state | count: count - val}
end

defmodule MyApp.App do
  use Solve

  @impl Solve
  def controllers, do: [controller!(name: :counter, module: MyApp.Counter)]
end
```

Let's unpack it line by line.

Events for a Controller are declared in use statement.
```elixir
use Solve.Controller, events: [:increment, :decrement]
```

This now requiers implementation of at leas onet function named `increment`
and one function named `decrement`.

Solve will accept definition with arities `1-5` so
for `events: [:example event]` one of these needs to be implemented.

```elixir
def example_event(event_payload)
def example_event(event_payload, state)
def example_event(event_payload, state, dependencies)
def example_event(event_payload, state, dependencies, callbacks)
def example_event(event_payload, state, dependencies, callbacks, init_params)
```

Declaring the same event at multiple arities is a compile error.
We will talk about dependencies and callbacks soon but let's ignore them for now.  

Each event handler implementation needs to return new internal state of controller.
In case of our counter we increment or decrement count by 1 or by provided value.
```elixir
def increment(_payload = nil, state = %{count: count}), do: %{state | count: count + 1}
def increment(val, state = %{count: count}), do: %{state | count: count + val}
```

If we start our app we can use `Solve.dispatch/4` to send events to controllers.

```
iex(4)> {:ok, app_pid} = MyApp.App.start_link()
{:ok, #PID<0.194.0>}
iex(5)> Solve.subscribe(app_pid, :counter)
%{count: 0}
iex(6)> Solve.dispatch(app_pid, :counter, :increment, nil)
:ok
iex(7)> Solve.subscribe(app_pid, :counter)
%{count: 1}
```

Since we are subscribed to we will also receive a message for each exposed state change.
```
iex(8)> flush
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.194.0>,
    controller_name: :counter,
    exposed_state: %{count: 1}
  }
}
```

If there is an error in our code and controller crashes, app will start it from a fresh state.
We can simulate that here by sending payload that doesn't work with `+`.

```
iex(10)> Solve.dispatch(app_pid, :counter, :increment, 25)
:ok
iex(11)> Solve.dispatch(app_pid, :counter, :increment, "Invalid value")
:ok

21:02:52.019 [error] GenServer #PID<0.195.0> terminating
** (ArithmeticError) bad argument in arithmetic expression
    (erts 16.2) :erlang.+(26, "Invalid value")
    iex:8: MyApp.Counter.increment/2
    (solve 0.2.1) lib/solve/controller.ex:759: Solve.Controller.with_solve_app/2
    (solve 0.2.1) lib/solve/controller.ex:555: Solve.Controller.__handle_event__/3
    (stdlib 7.2) gen_server.erl:2460: :gen_server.try_handle_cast/3
    (stdlib 7.2) gen_server.erl:2418: :gen_server.handle_msg/3
    (stdlib 7.2) proc_lib.erl:333: :proc_lib.init_p_do_apply/3
Last message: {:"$gen_cast", {:event, :increment, "Invalid value"}}
State: %{module: MyApp.Counter, state: %{count: 26}, callbacks: %{}, params: true, dependencies: %{}, solve_app: #PID<0.194.0>, controller_name: :counter, external_subscription_refs_by_pid: %{#PID<0.183.0> => #Reference<0.1748359359.996933634.102658>, #PID<0.194.0> => #Reference<0.1748359359.996933634.102637>}, exposed_state: %{count: 26}, subscriber_monitor_refs_by_pid: %{#PID<0.183.0> => #Reference<0.1748359359.996933634.102659>, #PID<0.194.0> => #Reference<0.1748359359.996933634.102638>}, subscribers: %{#Reference<0.1748359359.996933634.102637> => %{kind: {:external, #PID<0.194.0>, :counter}, subscriber: #PID<0.194.0>}, #Reference<0.1748359359.996933634.102658> => %{kind: {:external, #PID<0.194.0>, :counter}, subscriber: #PID<0.183.0>}}}
iex(12)> flush
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.194.0>,
    controller_name: :counter,
    exposed_state: %{count: 26}
  }
}
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.194.0>,
    controller_name: :counter,
    exposed_state: nil
  }
}
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.194.0>,
    controller_name: :counter,
    exposed_state: %{count: 0}
  }
}
```







## There might be others and we may depend on each other

## By calling back I can reach anyone 

## In a nutshell I am a GenServer

## In a collection I am still individual





...

## Acknowledgements and similar projects

Solve is based on [Keechma Next](https://github.com/keechma/keechma-next/) for clojurescript.
It inherits general concept and is a spiritual successor to it, adapted to elixir with 
tweaks to fit into the ecosystem. 

Closest project with conceptually simialr architecture is [Bonsai](https://github.com/janestreet/bonsai) used by Jane Street
