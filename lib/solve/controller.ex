defmodule Solve.Controller do
  @moduledoc """
  In Solve your main building block is the controller. Controllers are composed in the
  app state graph, and they can depend on each other. UI can subscribe to the controller
  state. Each controller has its own internal state, and each controller has read access
  to the exposed state of its dependencies.

  Controllers are implemented as `GenServer`s.

  ## Responsibilities

  - Manage internal user state
  - Handle UI events
  - Refresh cached dependency state when dependencies change
  - Track observers (both UIs and other controllers)
  - Send state updates directly to observers
  - Monitor observer processes and clean them up

  ## Direct Communication

  Controllers communicate directly with subscribers using
  `{:solve_update, solve_app, controller_name, exposed_state}` messages.

  ## Example Controller

      defmodule MyApp.CounterController do
        use Solve.Controller, events: [:increment, :decrement, :reset]

        @impl true
        def init(_init_params, _dependencies) do
          %{count: 0, private_data: "secret"}
        end

        @impl true
        def expose(state, _dependencies, _init_params) do
          %{count: state.count}
        end

        def increment(_payload, state, _dependencies, _callbacks, _init_params) do
          %{state | count: state.count + 1}
        end

        def decrement(_payload, state, _dependencies, _callbacks, _init_params) do
          %{state | count: state.count - 1}
        end

        def reset(_payload, _state, _dependencies, _callbacks, _init_params) do
          %{count: 0, private_data: "secret"}
        end
      end

  ## With Dependencies

      defmodule MyApp.ComputedController do
        use Solve.Controller, events: []

        @impl true
        def init(_init_params, _dependencies) do
          %{multiplier: 10}
        end

        @impl true
        def expose(state, dependencies, _init_params) do
          source_value = get_in(dependencies, [:source, :count]) || 0
          %{result: source_value * state.multiplier}
        end
      end

  ## Params and Callbacks

  `init_params` can have any shape, but it must be truthy. If it is `nil` or `false`, the
  controller stops with `{:invalid_init_params, controller_name, value}`.

  `callbacks` is a plain map passed only to declared event handlers. Event handlers receive
  all runtime inputs as:

      event_name(event_payload, state, dependencies, callbacks, init_params)

  ## Subscription Helpers

  - `subscribe(controller, subscriber \\ self())` registers the subscriber and returns the
    current exposed state synchronously.
  - `dispatch(controller, event, payload \\ %{})` sends an event to the controller.

  In normal app code, prefer `Solve.dispatch/4` so dispatch goes through the `Solve`
  runtime and stays aligned with controller lifecycle changes. `Solve.Controller.dispatch/3`
  is the low-level primitive for callers that already have a controller pid.

  ## Exposed State

  A running controller must expose a plain map. `nil` is reserved for the Solve runtime
  to mean that a controller is currently off/stopped. The `:events_` key is reserved for
  `Solve.Lookup` augmentation and should not be returned from `expose/3`.

  ## Using Structs for State

  Controller user state can be any term. Structs are often a good choice because they
  provide better documentation and tooling, but they are not required.
  """

  require Logger

  @genserver_start_options [:name, :timeout, :debug, :spawn_opt, :hibernate_after]

  @type state :: any()
  @type dependencies :: map()
  @type callbacks :: map()
  @type init_params :: any()

  @doc """
  Initializes the controller user state.

  `init_params` can have any truthy shape. `dependencies` contains cached exposed state
  from upstream controllers.
  """
  @callback init(init_params(), dependencies()) :: state()

  @doc """
  Computes the exposed state visible to subscribers and dependent controllers.

  Defaults to returning the full user state. Running controllers must return a plain map.
  """
  @callback expose(state(), dependencies(), init_params()) :: map()

  @optional_callbacks expose: 3

  defmacro __using__(opts) do
    events = validate_events_option!(opts, __CALLER__)

    quote bind_quoted: [events: events] do
      use GenServer

      @behaviour Solve.Controller
      @before_compile Solve.Controller
      @solve_controller_events events

      @impl Solve.Controller
      def expose(state, _dependencies, _init_params), do: state

      def __events__, do: @solve_controller_events

      def start_link(opts \\ []) do
        Solve.Controller.start_link(__MODULE__, opts)
      end

      @impl GenServer
      def init(opts), do: Solve.Controller.__init__(__MODULE__, opts)

      @impl GenServer
      def handle_call({:subscribe, subscriber}, _from, server_state) do
        Solve.Controller.__handle_subscribe__(subscriber, server_state)
      end

      @impl GenServer
      def handle_cast({:event, event, payload}, server_state) do
        Solve.Controller.__handle_event__(event, payload, server_state)
      end

      @impl GenServer
      def handle_info({:solve_update, solve_app, dependency_name, exposed_state}, server_state) do
        Solve.Controller.__handle_dependency_update__(
          solve_app,
          dependency_name,
          exposed_state,
          server_state
        )
      end

      @impl GenServer
      def handle_info({:DOWN, _ref, :process, subscriber, _reason}, server_state) do
        Solve.Controller.__handle_subscriber_down__(subscriber, server_state)
      end

      @impl GenServer
      def handle_info(_message, server_state) do
        {:noreply, server_state}
      end

      defoverridable expose: 3
    end
  end

  defmacro __before_compile__(env) do
    events = Module.get_attribute(env.module, :solve_controller_events) || []
    definitions = MapSet.new(Module.definitions_in(env.module))

    missing_callbacks =
      Enum.reject(events, fn event ->
        MapSet.member?(definitions, {event, 5})
      end)

    if missing_callbacks != [] do
      callbacks = Enum.map_join(missing_callbacks, ", ", &"#{&1}/5")

      raise CompileError,
        file: env.file,
        line: 1,
        description: "#{inspect(env.module)} must define declared event callback(s): #{callbacks}"
    end

    quote(do: :ok)
  end

  @doc """
  Starts a controller GenServer.
  """
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(module, opts \\ []) when is_atom(module) and is_list(opts) do
    GenServer.start_link(module, opts, Keyword.take(opts, @genserver_start_options))
  end

  @doc """
  Subscribes a process to controller updates and returns the current exposed state.
  """
  @spec subscribe(GenServer.server(), pid()) :: any()
  def subscribe(controller, subscriber \\ self())

  def subscribe(controller, subscriber) when is_pid(subscriber) do
    GenServer.call(controller, {:subscribe, subscriber})
  end

  def subscribe(_controller, subscriber) do
    raise ArgumentError, "subscribe/2 expects a pid subscriber, got: #{inspect(subscriber)}"
  end

  @doc """
  Dispatches an event to a controller.
  """
  @spec dispatch(GenServer.server(), term(), term()) :: :ok
  def dispatch(controller, event, payload \\ %{}) do
    GenServer.cast(controller, {:event, event, payload})
  end

  @doc false
  def __init__(module, opts) when is_atom(module) and is_list(opts) do
    solve_app = Keyword.get(opts, :solve_app)
    controller_name = Keyword.get(opts, :controller_name, module)
    params = Keyword.get(opts, :params)

    if params in [nil, false] do
      {:stop, {:invalid_init_params, controller_name, params}}
    else
      dependencies = normalize_optional_map(Keyword.get(opts, :dependencies))
      callbacks = normalize_optional_map(Keyword.get(opts, :callbacks))
      state = module.init(params, dependencies)

      exposed_state =
        validate_exposed_state!(
          module.expose(state, dependencies, params),
          module,
          controller_name
        )

      {:ok,
       %{
         module: module,
         solve_app: solve_app,
         controller_name: controller_name,
         state: state,
         params: params,
         dependencies: dependencies,
         callbacks: callbacks,
         exposed_state: exposed_state,
         subscribers: %{}
       }}
    end
  end

  @doc false
  def __handle_subscribe__(
        subscriber,
        %{subscribers: subscribers, exposed_state: exposed_state} = server_state
      )
      when is_pid(subscriber) do
    subscribers = ensure_subscriber(subscribers, subscriber)
    {:reply, exposed_state, %{server_state | subscribers: subscribers}}
  end

  @doc false
  def __handle_event__(
        event,
        payload,
        %{module: module, controller_name: controller_name} = server_state
      ) do
    if declared_event?(module, event) do
      new_state =
        apply(module, event, [
          payload,
          server_state.state,
          server_state.dependencies,
          server_state.callbacks,
          server_state.params
        ])

      server_state = %{server_state | state: new_state}
      {:noreply, refresh_exposed_state(server_state)}
    else
      Logger.warning(
        "discarding undeclared Solve controller event #{inspect(event)} for #{inspect(controller_name)}"
      )

      {:noreply, server_state}
    end
  end

  @doc false
  def __handle_dependency_update__(
        solve_app,
        dependency_name,
        exposed_state,
        %{solve_app: solve_app} = server_state
      ) do
    dependencies = Map.put(server_state.dependencies, dependency_name, exposed_state)
    server_state = %{server_state | dependencies: dependencies}
    {:noreply, refresh_exposed_state(server_state)}
  end

  def __handle_dependency_update__(_solve_app, _dependency_name, _exposed_state, server_state) do
    {:noreply, server_state}
  end

  @doc false
  def __handle_subscriber_down__(subscriber, %{subscribers: subscribers} = server_state) do
    {:noreply, %{server_state | subscribers: Map.delete(subscribers, subscriber)}}
  end

  defp validate_events_option!(opts, caller) when is_list(opts) do
    opts
    |> Keyword.get(:events, [])
    |> validate_events!(caller)
  end

  defp validate_events_option!(opts, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "use Solve.Controller expects a keyword list, got: #{inspect(opts)}"
  end

  defp validate_events!(events, caller) when is_list(events) do
    cond do
      not Enum.all?(events, &is_atom/1) ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "Solve.Controller events must be a list of unique atoms, got: #{inspect(events)}"

      length(events) != MapSet.size(MapSet.new(events)) ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "Solve.Controller events must be a list of unique atoms, got: #{inspect(events)}"

      true ->
        events
    end
  end

  defp validate_events!(events, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "Solve.Controller events must be a list of unique atoms, got: #{inspect(events)}"
  end

  defp normalize_optional_map(nil), do: %{}
  defp normalize_optional_map(value), do: value

  defp ensure_subscriber(subscribers, subscriber) do
    if Map.has_key?(subscribers, subscriber) do
      subscribers
    else
      Map.put(subscribers, subscriber, Process.monitor(subscriber))
    end
  end

  defp declared_event?(module, event) do
    event in module.__events__()
  end

  defp refresh_exposed_state(server_state) do
    new_exposed_state =
      server_state.module.expose(
        server_state.state,
        server_state.dependencies,
        server_state.params
      )
      |> validate_exposed_state!(server_state.module, server_state.controller_name)

    maybe_broadcast_update(server_state, new_exposed_state)
  end

  defp maybe_broadcast_update(server_state, new_exposed_state) do
    if server_state.exposed_state === new_exposed_state do
      %{server_state | exposed_state: new_exposed_state}
    else
      broadcast_update(server_state, new_exposed_state)
      %{server_state | exposed_state: new_exposed_state}
    end
  end

  defp broadcast_update(server_state, new_exposed_state) do
    message =
      {:solve_update, server_state.solve_app, server_state.controller_name, new_exposed_state}

    Enum.each(Map.keys(server_state.subscribers), &send(&1, message))
  end

  defp validate_exposed_state!(exposed_state, _module, _controller_name)
       when is_map(exposed_state) and not is_struct(exposed_state) do
    exposed_state
  end

  defp validate_exposed_state!(exposed_state, module, controller_name) do
    raise ArgumentError,
          "#{inspect(module)} expose/3 for #{inspect(controller_name)} must return a plain map, got: #{inspect(exposed_state)}"
  end
end
