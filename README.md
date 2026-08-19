# Solve

[![Hex.pm](https://img.shields.io/hexpm/v/solve.svg)](https://hex.pm/packages/solve)
[![HexDocs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/solve)
[![CI](https://img.shields.io/badge/CI-GitHub_Actions-2088FF?logo=githubactions&logoColor=white)](https://github.com/emerge-elixir/solve/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/emerge-elixir/solve.svg)](https://github.com/emerge-elixir/solve/blob/main/LICENSE)

Solve is an application framework.

It provides tools to model a UI application as a graph of reusable state machines,
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

Its architecture allows an application to scale to a much higher degree of complexity while
retaining a clear overview of how data flows between components, since lifecycles of components
are not lumped together with rendering code.

## Project status

This project is still in early stages. Core API parts mentioned in this README are stable
and are not expected to change significantly.

Implementation is very sloppy and will eventually be completely replaced.

Module documentation is coming soon.

Currently only properly tested with [Emerge](https://emerge.hexdocs.pm/readme.html)

[LiveView](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.html) adapter is also in the works.

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
do materialize it has to live inside of an **application**. Here is the simplest
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

The first module defines controller module that initializes with
internal state of `%{hello: "Hello"}`

The second module defines an app that starts that controller under a name
`:hello`


You can start an app like any GenServer:
```
iex(4)> {:ok, app_pid} = MyApp.App.start_link()
{:ok, #PID<0.194.0>}
```
and subscribe to a controller's data
```
iex(5)> Solve.subscribe(app_pid, :hello)
%{hello: "Hello"}
```
Subscribing to a controller returns its currently exposed data and
you also receive a message with new information whenever it changes.

## Exposing data

By default controller exposes it's internal state, which can be modified
by implementing `expose` function. The result of expose needs to be elixir
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

## I have params therefore I am

Each controller in an application is defined by a name
but its lifecycle is determined by params.

In our earlier example we didn't provide `params` for the controller in our app
```elixir
 controller!(name: :hello, module: MyApp.Hello)
```
in that case solve defaults to
```elixir
 controller!(name: :hello, module: MyApp.Hello, params: fn _ -> true end)
```
which basically means "this controller always running". If we change that to
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
however, if the result of params function change it will affect the controller in the following way:

| Prev   | Current | Prev == Current | Actions |
| -----  | ------  | ----------------| --------- |
| falsy  | falsy   | -               | Do nothing (controller is not running) |
| truthy | falsy   | -               | Stop the current controller process     |
| falsy  | truthy  | -               | Start a new controller process |
| truthy | truthy  | false           | Stop the current controller process and start a new one |
| truthy | truthy  | true            | Do nothing (controller is running)|

An important state change to notice is from one truthy value to a different
truthy value, in that case, the app will stop current process and start a new one.

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

Events for a Controller are declared in the use statement.
```elixir
use Solve.Controller, events: [:increment, :decrement]
```

This module now needs to implement at least one function named `increment`
and one function named `decrement`.

Solve will accept function definitions with arity `1-5` so
for `events: [:example event]` one of these needs to be implemented.

```elixir
def example_event(event_payload)
def example_event(event_payload, state)
def example_event(event_payload, state, dependencies)
def example_event(event_payload, state, dependencies, callbacks)
def example_event(event_payload, state, dependencies, callbacks, init_params)
```

Declaring the same event at multiple arities is a compile error.

Each event handler implementation needs to return a new internal state of the controller.
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

Since we are subscribed, we will also receive a message for each exposed state change.
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
We can simulate that here by sending a payload that doesn't work with `+`.

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

Observe state messages and notice how there was update with state nil when controller crashed
and then another one when controller was restarted. That nil state will become important
in a second.

## There might be others and we may depend on each other

Controllers can depend on other controllers and have other controllers depend on them.
Dependency connections are defined in the application rather then in individual controllers.
This allows for reuse of controllers. Let's demonstrate with a multicontroller app.

We are going to reuse Counter controller from the previous example but this time we will name it :credits
and we are going to add a new controller named :hello that will greet our user and show a number of available credits.

```elixir
defmodule MyApp.App do
  use Solve

  @impl Solve
  def controllers do
  [
    controller!(name: :credits, module: MyApp.Counter),
    controller!(
      name: :hello,
      module: MyApp.Hello,
      dependencies: [:credits],
      params: fn %{app_params: app_params} -> Map.get(app_params || %{}, :name, "Anon") end
    )
  ]
  end
end
```

I have also sneaked in `:app_params` here. If, when starting the app you provide a params map
`MyApp.App.start_link(params: %{name: "The greeted one"})` that map will be available
to the params function of every controller.

Controllers cannot be completely detached from their dependencies if they are going to use them,
they need to be aware of the shape of data that is important to them (although you can take advantage of params
to introduce some polymorphic getters in the form of anonymous functions).

```elixir
defmodule MyApp.Hello do
  use Solve.Controller

  @impl Solve.Controller
  def init(_params, _dependencies), do: nil

  def expose(_state, %{credits: %{count: count}}, params) do
    greeting = "Hello #{params}, you have #{count} credits"
    %{greeting: greeting}
  end
end
```

In this expose function we are not using state, we are pattern matching directly on
credits count and since params for our controller is just a string with the name,
we are using it directly.


If we start the app and subscribe to hello we will be greeted with 0 credits.
```elixir
iex(4)> {:ok, app_pid} = MyApp.App.start_link(params: %{name: "The greeted one"})
{:ok, #PID<0.199.0>}
iex(5)> Solve.subscribe(app_pid, :hello)
%{greeting: "Hello The greeted one, you have 0 credits"}
```

Now if credits are incremented, the counter controller exposes new state and
that triggers expose function of all of the controllers that depend on it
to be rerun.

```
iex(6)> Solve.dispatch(app_pid, :credits, :increment, 100)
:ok
iex(7)> flush
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.199.0>,
    controller_name: :hello,
    exposed_state: %{greeting: "Hello The greeted one, you have 100 credits"}
  }
}
:ok
```

Since we didn't subscribe to :credits, we only got an update message from the `:hello`
controller.

Params functions in the application can also rely on the dependencies of the controller.
Let's add another controller to our app that is only on when the credits are negative.

```elixir
defmodule MyApp.NegativeAlert do
  use Solve.Controller

  @impl Solve.Controller
  def init(_params, _dependencies), do: nil

  def expose(_state, _deps, _params) do
    %{alert: "Negative credits"}
  end
end
```

```elixir
defmodule MyApp.App do
  use Solve

  @impl Solve
  def controllers do
  [
    controller!(name: :credits, module: MyApp.Counter),
    controller!(
      name: :hello,
      module: MyApp.Hello,
      dependencies: [:credits],
      params: fn %{app_params: app_params} -> Map.get(app_params || %{}, :name, "Anon") end
    ),
    controller!(
      name: :negative,
      module: MyApp.NegativeAlert,
      dependencies: [:credits],
      params: fn %{dependencies: %{credits: credits}} -> credits && credits.count < 0 end
    )
  ]
  end
end
```

```
iex(19)> {:ok, app_pid} = MyApp.App.start_link()
{:ok, #PID<0.235.0>}
iex(20)> Solve.subscribe(app_pid, :negative)
nil
iex(21)> Solve.subscribe(app_pid, :hello)
%{greeting: "Hello Anon, you have 0 credits"}
iex(22)> Solve.dispatch(app_pid, :credits, :decrement, 100)
:ok
iex(23)> flush
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.235.0>,
    controller_name: :hello,
    exposed_state: %{greeting: "Hello Anon, you have -100 credits"}
  }
}
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.235.0>,
    controller_name: :negative,
    exposed_state: %{alert: "Negative credits"}
  }
}
:ok
iex(24)> Solve.dispatch(app_pid, :credits, :increment, 200)
:ok
iex(25)> flush
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.235.0>,
    controller_name: :hello,
    exposed_state: %{greeting: "Hello Anon, you have 100 credits"}
  }
}
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.235.0>,
    controller_name: :negative,
    exposed_state: nil
  }
}
:ok
```

When controller is not turned on, it's exposed state is nil. If you go
back an look at the params transition table and combine that with the fact that when
a controller crashes it also exposes nil for an instant. That combination
of dependencies and params functions allow you to define not only how data flows
between controllers but also how the state of dependencies influences the lifecycle
of other controllers in a declarative way in a single place.

There are few a restriction on dependencies to be aware of. Circular dependencies
are not allowed. `def controllers` deliberately has arity of 0, should be static
 and the dependency graph is checked for circular dependencies. This is to
make the whole graph eventually consistent but also for clarity. One of the
main advantages of Solve is high level overview of application visible in singular file.
Opposed to component systems that force you to read implementation
of every component and its view function in order to figure out the topology.

## By calling back I can reach anyone

Callbacks are another way of exchanging of data between controllers.
Although you could send find out the pid of some other controller and communicate
directly between controllers, that is heavily discouraged.

Let's add a simple notification system to our app. We will
create a controller that holds notifications.

```elixir
defmodule MyApp.Notifications do
  use Solve.Controller, events: [:notify, :dismiss]

  @impl Solve.Controller
  def init(_params, _dependencies), do: []

  def notify(message, state), do: [message | state]

  def dismiss(_, []), do: []
  def dismiss(index, state) when is_integer(index), do: Enum.delete_at(state, index)
  def dismiss(_, [_ | rest]), do: rest

  # Expose has to return plain map, so we can't use state directly
  def expose(state, _deps, _params), do: %{notifications: state}
end
```

Now if we want to add a notification every time the credits balance changes
we can do that by adding a callback to the counter controller.

We will refactor it a little bit:

```elixir
defmodule MyApp.Counter do
  use Solve.Controller, events: [:increment, :decrement]

  @impl Solve.Controller
  def init(_params, _dependencies), do: %{count: 0}

  def increment(nil, state, _deps, callbacks), do: update_count(state, 1, callbacks)
  def increment(val, state, _deps, callbacks), do: update_count(state, val, callbacks)

  def decrement(nil, state, _deps, callbacks), do: update_count(state, -1, callbacks)
  def decrement(val, state, _deps, callbacks), do: update_count(state, -val, callbacks)

  defp update_count(state = %{count: count}, val, callbacks) do
    Map.get(callbacks, :count_updated_by) && callbacks.count_updated_by.(val)
    %{state | count: count + val}
  end
end
```

We execute a callback named `:count_updated_by` with arity 1
every time the value gets updated.

We can leverage the callback to dispatch a notification on every counter change.
Since callbacks are defined directly in the application, we get clear overview
of communication between controllers.

```elixir
defmodule MyApp.App do
  use Solve

  @impl Solve
  def controllers do
  [
    controller!(name: :notifications, module: MyApp.Notifications),
    controller!(
      name: :credits,
      module: MyApp.Counter,
      callbacks: %{
        count_updated_by: fn value ->
          Solve.dispatch(:notifications, :notify, "Credits change: #{value}")
        end
      }
    )
  ]
  end
end
```

```
iex(4)> {:ok, app_pid} = MyApp.App.start_link()
{:ok, #PID<0.200.0>}
iex(5)> Solve.dispatch(app_pid, :credits, :increment, 300)
:ok
iex(6)> Solve.subscribe(app_pid, :notifications)
%{notifications: ["Credits change: 300"]}
iex(7)> Solve.dispatch(app_pid, :credits, :decrement, 200)
:ok
iex(8)> flush
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.200.0>,
    controller_name: :notifications,
    exposed_state: %{
      notifications: ["Credits change: -200", "Credits change: 300"]
    }
  }
}
:ok
```

Callback allow for a direct dispatch to any other controller, breaking
the data flow out of the dependencies graph.
Specifying them at the application level allows for all of cross controller
communication to be visible in a single place.

Be careful not to create loops when using callbacks.

## In a nutshell I am a GenServer

Controllers are built on top of GenServer and they retain `handle_info` from
a GenServer, expanding on it to have the full array of Solve controller arguments,
that means you can implement any of the following:
```elixir
def handle_info(message, state)
def handle_info(message, state, dependencies)
def handle_info(message, state, dependencies, callbacks)
def handle_info(message, state, dependencies, callbacks, init_params)
```

This allows you to interop with other processes in your BEAM cluster
while keeping solve event semantics.

We can use this to make our notifications automatically disappear
after 5 seconds.

```elixir
defmodule MyApp.Notifications do
  use Solve.Controller, events: [:notify, :dismiss]

  @impl Solve.Controller
  def init(_params, _dependencies), do: []

  def notify(message, state) do
    Process.send_after(self(), :dismiss_last, :timer.seconds(5))
    [message | state]
  end

  def dismiss(_, []), do: []
  def dismiss(index, state) when is_integer(index), do: List.delete_at(state, index)
  def dismiss(_, [_ | rest]), do: rest

  def handle_info(:dismiss_last, state), do: Enum.drop(state, -1)

  # Expose has to return plain map, so we can't use state directly
  def expose(state, _deps, _params), do: %{notifications: state}
end
```

Keeping counter and application same as before.

```
iex(26)> {:ok, app_pid} = MyApp.App.start_link()
{:ok, #PID<0.236.0>}
iex(27)> Solve.subscribe(app_pid, :notifications)
%{notifications: []}
iex(28)> Solve.dispatch(app_pid, :credits, :increment, 300)
:ok
iex(29)> Solve.dispatch(app_pid, :credits, :decrement, 200)
:ok
iex(30)> flush
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.233.0>,
    controller_name: :notifications,
    exposed_state: %{notifications: []}
  }
}
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.236.0>,
    controller_name: :notifications,
    exposed_state: %{notifications: ["Credits change: 300"]}
  }
}
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.236.0>,
    controller_name: :notifications,
    exposed_state: %{
      notifications: ["Credits change: -200", "Credits change: 300"]
    }
  }
}
```
After few seconds
```
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.236.0>,
    controller_name: :notifications,
    exposed_state: %{notifications: ["Credits change: -200"]}
  }
}
:ok
```
After another 5 seconds
```
iex(31)> flush
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.236.0>,
    controller_name: :notifications,
    exposed_state: %{notifications: []}
  }
}
:ok
```

## In a collective I retain my identity

Controllers we have been using so far were all the singleton variant,
meaning the atom used for their name is also their id.

There is also a collection variant of a controller where the same controller module is
used to dynamically create collection of controllers, each with it's own id.

Collections are created by providing a `collect` function instead of a `params` function.
It needs to return a list of `{id, params}` pairs. For each provided pair a new
controller is spawned.

You can provide additional callbacks to each controller in the collection by returning
`{id, [params: <params>, callbacks: <callbacks>]}` pattern from the collect function instead.

We can demonstrate collections reusing the counter controller implementation we already have.

```elixir
defmodule MyApp.App do
  use Solve

  @impl Solve
  def controllers do
  [
    controller!(name: :n_counters, module: MyApp.Counter),
    controller!(
      name: :counter,
      module: MyApp.Counter,
      variant: :collection,
      dependencies: [:n_counters],
      collect: fn %{dependencies: %{n_counters: %{count: count}}} ->
        if count > 0,
          do: Enum.map(1..count, fn id -> {id, true} end),
          else: []
      end
    )
  ]
  end
end
```

```
iex(45)> {:ok, app_pid} = MyApp.App.start_link()
{:ok, #PID<0.365.0>}
iex(46)> Solve.dispatch(app_pid, :n_counters, :increment, 3)
:ok
```
At this point, the controller under id 3 is initialized
```
iex(48)> Solve.subscribe(app_pid, {:counter, 3})
%{count: 0}
iex(49)> Solve.dispatch(app_pid, {:counter, 3}, :increment, 100)
:ok
iex(50)> flush
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.365.0>,
    controller_name: {:counter, 3},
    exposed_state: %{count: 100}
  }
}
:ok
```
If we decrease the number of counters controller under id 3 will disappear
```
iex(51)> Solve.dispatch(app_pid, :n_counters, :decrement, 1)
:ok
iex(52)> flush
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.365.0>,
    controller_name: {:counter, 3},
    exposed_state: nil
  }
}
:ok
```
Once reinitialized, it will start from 0 again
```
iex(53)> Solve.dispatch(app_pid, :n_counters, :increment, 1)
:ok
iex(54)> flush
%Solve.Message{
  type: :update,
  payload: %Solve.Update{
    app: #PID<0.365.0>,
    controller_name: {:counter, 3},
    exposed_state: %{count: 0}
  }
}
:ok
```

Bit of caution here: collections are easily misused and in a lot of
use cases a similar solution can be achieved by using single controller
with more functionality folded into it.

## Looking up data inside of Solve application

We have covered all of the features that Solve provides
for creating applications at the moment. Now we are going to explore how
to connect it to the presentation layer.

We will use the same app from the previous example
and create a GenServer that uses `Solve.Lookup` to
render textual representation of application.

```elixir
defmodule MyApp.Presenter do
  use GenServer
  use Solve.Lookup

  # Client

  def add_counter(), do: GenServer.cast(__MODULE__, :add_counter)
  def increment(id), do: GenServer.cast(__MODULE__, {:increment, id})
  def show(), do: GenServer.call(__MODULE__, :show) |> IO.puts()

  def start_link(app), do: GenServer.start_link(__MODULE__, app, name: __MODULE__)

  @impl GenServer
  def init(app), do: {:ok, %{app: app, scene: render(%{app: app})}}

  @impl GenServer
  def handle_cast(:add_counter, state) do
    solve(state.app, :n_counters)
    |> event(:increment)
    |> dispatch(nil)
    {:noreply, state}
  end

  def handle_cast({:increment, id}, state) do
    solve(state.app, {:counter, id})
    |> event(:increment)
    |> dispatch(nil)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:show, _from, state), do: {:reply, state.scene, state}

  def render(%{app: app}) do
    n_counters = solve(app, :n_counters)
    counters = collection(app, :counter)

    title = "Showing #{n_counters.count} counters"
    counter_line = fn {id, %{count: count}} -> "Counter(#{id}): #{count}" end
    [title | Enum.map(counters, counter_line)] |> Enum.intersperse("\n")
  end

  @impl Solve.Lookup
  def handle_solve_updated(_updated, state), do: {:ok, %{state | scene: render(state)}}
end
```

We are using a few convenience helpers from Solve.Lookup here `solve`, `event`, `dispatch` and `collection`
`solve` and `collection` are cached fetchers. `solve(app, :n_counters)` will fetch the state of the n_counters
controller, subscribe to it and cache it to the process dictionary. Next time it is called it will
use the value cached in process dictionary.

`use Solve.Lookup` will add a couple of handle_info clauses that match on Solve.Message.
When message is received they will update
the process cache and call the `handle_solve_updated` callback.

In the example, a new scene is rendered into GenServer state on each solve update.

`MyApp.Presenter.show()` IO.puts the scene from the state, it now always
reflects the state of our Solve application.

```
iex(4)> {:ok, app_pid} = MyApp.App.start_link()
{:ok, #PID<0.199.0>}
iex(5)> {:ok, presenter_pid} = MyApp.Presenter.start_link(app_pid)
{:ok, #PID<0.201.0>}
iex(6)> MyApp.Presenter.show()
Showing 0 counters
:ok
iex(7)> MyApp.Presenter.add_counter()
:ok
iex(8)> MyApp.Presenter.show()
Showing 1 counters
Counter(1): 0
:ok
iex(9)> Solve.dispatch(app_pid, :n_counters, :increment, 3)
:ok
iex(10)> Solve.dispatch(app_pid, {:counter, 4}, :increment, 20)
:ok
iex(11)> MyApp.Presenter.increment(3)
:ok
iex(12)> MyApp.Presenter.show()
Showing 4 counters
Counter(1): 0
Counter(2): 0
Counter(3): 1
Counter(4): 20
:ok
```

## Acknowledgements and similar projects

Solve is based on [Keechma Next](https://github.com/keechma/keechma-next/), a clojurescript web framework.
It inherits the general concept and is a spiritual successor to it, adapted to elixir with
tweaks to fit into the OTP ecosystem.

The Closest project with similar architecture is [Bonsai](https://github.com/janestreet/bonsai) an OCaml web framework by Jane Street
