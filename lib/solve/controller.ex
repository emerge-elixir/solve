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

  Controllers communicate directly with subscribers using `%Solve.Message{}` envelopes
  with `%Solve.Update{}` payloads.

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
  alias Solve.Collection
  alias Solve.DependencyUpdate
  alias Solve.Message

  @genserver_start_options [:name, :timeout, :debug, :spawn_opt, :hibernate_after]

  @type state :: any()
  @type dependencies :: %{optional(atom()) => map() | Collection.t(map()) | nil}
  @type callbacks :: map()
  @type init_params :: any()
  @type dependency_encoder :: (map() -> term())

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
      def handle_call({:subscribe_with, subscriber, encoder}, _from, server_state) do
        Solve.Controller.__handle_subscribe_with__(subscriber, encoder, server_state)
      end

      @impl GenServer
      def handle_call({:unsubscribe, subscription_ref}, _from, server_state) do
        Solve.Controller.__handle_unsubscribe__(subscription_ref, server_state)
      end

      @impl GenServer
      def handle_cast({:update_callbacks, callbacks}, server_state) do
        Solve.Controller.__handle_callbacks_update__(callbacks, server_state)
      end

      @impl GenServer
      def handle_cast({:event, event, payload}, server_state) do
        Solve.Controller.__handle_event__(event, payload, server_state)
      end

      @impl GenServer
      def handle_info(
            %Solve.Message{
              type: :update,
              payload: %Solve.Update{
                app: solve_app,
                controller_name: dependency_name,
                exposed_state: exposed_state
              }
            },
            server_state
          ) do
        Solve.Controller.__handle_dependency_update__(
          solve_app,
          dependency_name,
          exposed_state,
          server_state
        )
      end

      @impl GenServer
      def handle_info(%Solve.DependencyUpdate{} = dependency_update, server_state) do
        Solve.Controller.__handle_dependency_update_message__(dependency_update, server_state)
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

  @doc false
  @spec subscribe_with(GenServer.server(), pid(), dependency_encoder()) ::
          {:ok, map(), reference()}
  def subscribe_with(controller, subscriber, encoder)
      when is_pid(subscriber) and is_function(encoder, 1) do
    GenServer.call(controller, {:subscribe_with, subscriber, encoder})
  end

  def subscribe_with(_controller, subscriber, _encoder) do
    raise ArgumentError,
          "subscribe_with/3 expects a pid subscriber and unary encoder, got: #{inspect(subscriber)}"
  end

  @doc false
  @spec unsubscribe(GenServer.server(), reference()) :: :ok
  def unsubscribe(controller, subscription_ref) when is_reference(subscription_ref) do
    GenServer.call(controller, {:unsubscribe, subscription_ref})
  end

  def unsubscribe(_controller, subscription_ref) do
    raise ArgumentError,
          "unsubscribe/2 expects a subscription reference, got: #{inspect(subscription_ref)}"
  end

  @doc """
  Dispatches an event to a controller.
  """
  @spec dispatch(GenServer.server(), term(), term()) :: :ok
  def dispatch(controller, event, payload \\ %{}) do
    GenServer.cast(controller, {:event, event, payload})
  end

  @doc false
  @spec update_callbacks(GenServer.server(), callbacks() | nil) :: :ok
  def update_callbacks(controller, callbacks) do
    GenServer.cast(controller, {:update_callbacks, normalize_optional_map(callbacks)})
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
         subscribers: %{},
         subscriber_monitor_refs_by_pid: %{},
         external_subscription_refs_by_pid: %{}
       }}
    end
  end

  @doc false
  def __handle_subscribe__(
        subscriber,
        %{exposed_state: exposed_state, external_subscription_refs_by_pid: external_refs} =
          server_state
      )
      when is_pid(subscriber) do
    server_state =
      if Map.has_key?(external_refs, subscriber) do
        server_state
      else
        subscription_ref = make_ref()

        put_subscription(
          server_state,
          subscription_ref,
          subscriber,
          {:external, server_state.solve_app, server_state.controller_name}
        )
        |> put_in([:external_subscription_refs_by_pid, subscriber], subscription_ref)
      end

    {:reply, exposed_state, server_state}
  end

  @doc false
  def __handle_subscribe_with__(
        subscriber,
        encoder,
        %{exposed_state: exposed_state} = server_state
      )
      when is_pid(subscriber) and is_function(encoder, 1) do
    subscription_ref = make_ref()

    server_state =
      put_subscription(server_state, subscription_ref, subscriber, {:internal, encoder})

    {:reply, {:ok, exposed_state, subscription_ref}, server_state}
  end

  @doc false
  def __handle_unsubscribe__(subscription_ref, %{subscribers: subscribers} = server_state)
      when is_reference(subscription_ref) do
    server_state =
      case Map.get(subscribers, subscription_ref) do
        nil ->
          server_state

        %{subscriber: subscriber, kind: {:external, _, _}} ->
          server_state
          |> delete_subscription(subscription_ref)
          |> update_in([:external_subscription_refs_by_pid], &Map.delete(&1, subscriber))

        _entry ->
          delete_subscription(server_state, subscription_ref)
      end

    {:reply, :ok, server_state}
  end

  @doc false
  def __handle_callbacks_update__(callbacks, server_state) when is_map(callbacks) do
    {:noreply, %{server_state | callbacks: callbacks}}
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
    server_state =
      apply_dependency_update(
        DependencyUpdate.replace(solve_app, dependency_name, exposed_state),
        server_state
      )

    {:noreply, refresh_exposed_state(server_state)}
  end

  def __handle_dependency_update__(_solve_app, _dependency_name, _exposed_state, server_state) do
    {:noreply, server_state}
  end

  @doc false
  def __handle_dependency_update_message__(
        %DependencyUpdate{app: solve_app} = dependency_update,
        %{solve_app: solve_app} = server_state
      ) do
    server_state = apply_dependency_update(dependency_update, server_state)
    {:noreply, refresh_exposed_state(server_state)}
  end

  def __handle_dependency_update_message__(%DependencyUpdate{}, server_state) do
    {:noreply, server_state}
  end

  @doc false
  def __handle_subscriber_down__(
        subscriber,
        %{subscriber_monitor_refs_by_pid: monitor_refs} = server_state
      ) do
    server_state =
      if Map.has_key?(monitor_refs, subscriber) do
        remove_subscriber(server_state, subscriber)
      else
        server_state
      end

    {:noreply, server_state}
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

  defp declared_event?(module, event) do
    event in module.__events__()
  end

  defp apply_dependency_update(
         %DependencyUpdate{key: key, op: :replace, value: value},
         %{dependencies: dependencies} = server_state
       ) do
    %{server_state | dependencies: Map.put(dependencies, key, value)}
  end

  defp apply_dependency_update(
         %DependencyUpdate{key: key, op: :collection_put, id: id, value: value},
         %{dependencies: dependencies} = server_state
       ) do
    collection = dependencies |> Map.get(key, Collection.empty()) |> ensure_collection!(key)

    %{
      server_state
      | dependencies: Map.put(dependencies, key, Collection.put(collection, id, value))
    }
  end

  defp apply_dependency_update(
         %DependencyUpdate{key: key, op: :collection_delete, id: id},
         %{dependencies: dependencies} = server_state
       ) do
    collection = dependencies |> Map.get(key, Collection.empty()) |> ensure_collection!(key)
    %{server_state | dependencies: Map.put(dependencies, key, Collection.delete(collection, id))}
  end

  defp apply_dependency_update(
         %DependencyUpdate{key: key, op: :collection_reorder, ids: ids},
         %{dependencies: dependencies} = server_state
       ) do
    collection = dependencies |> Map.get(key, Collection.empty()) |> ensure_collection!(key)

    %{
      server_state
      | dependencies: Map.put(dependencies, key, Collection.reorder(collection, ids))
    }
  end

  defp put_subscription(server_state, subscription_ref, subscriber, kind) do
    monitor_ref =
      Map.get_lazy(server_state.subscriber_monitor_refs_by_pid, subscriber, fn ->
        Process.monitor(subscriber)
      end)

    server_state
    |> put_in([:subscribers, subscription_ref], %{subscriber: subscriber, kind: kind})
    |> put_in([:subscriber_monitor_refs_by_pid, subscriber], monitor_ref)
  end

  defp delete_subscription(%{subscribers: subscribers} = server_state, subscription_ref) do
    case Map.pop(subscribers, subscription_ref) do
      {nil, _subscribers} ->
        server_state

      {%{subscriber: subscriber}, subscribers} ->
        external_refs =
          case Map.get(server_state.external_subscription_refs_by_pid, subscriber) do
            ^subscription_ref ->
              Map.delete(server_state.external_subscription_refs_by_pid, subscriber)

            _ ->
              server_state.external_subscription_refs_by_pid
          end

        has_other_subscriptions? =
          Enum.any?(subscribers, fn {_ref, entry} -> entry.subscriber == subscriber end)

        monitor_refs =
          if has_other_subscriptions? do
            server_state.subscriber_monitor_refs_by_pid
          else
            case Map.pop(server_state.subscriber_monitor_refs_by_pid, subscriber) do
              {nil, monitor_refs} ->
                monitor_refs

              {monitor_ref, monitor_refs} ->
                Process.demonitor(monitor_ref, [:flush])
                monitor_refs
            end
          end

        %{
          server_state
          | subscribers: subscribers,
            subscriber_monitor_refs_by_pid: monitor_refs,
            external_subscription_refs_by_pid: external_refs
        }
    end
  end

  defp remove_subscriber(%{subscribers: subscribers} = server_state, subscriber) do
    subscription_refs =
      subscribers
      |> Enum.filter(fn {_ref, entry} -> entry.subscriber == subscriber end)
      |> Enum.map(fn {subscription_ref, _entry} -> subscription_ref end)

    Enum.reduce(subscription_refs, server_state, &delete_subscription(&2, &1))
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
    Enum.each(server_state.subscribers, fn {_subscription_ref, entry} ->
      case build_subscriber_message(entry, server_state, new_exposed_state) do
        nil -> :ok
        message -> send(entry.subscriber, message)
      end
    end)
  end

  defp build_subscriber_message(
         %{kind: {:external, solve_app, controller_name}},
         _server_state,
         new_exposed_state
       ) do
    Message.update(solve_app, controller_name, new_exposed_state)
  end

  defp build_subscriber_message(%{kind: {:internal, encoder}}, _server_state, new_exposed_state) do
    encoder.(new_exposed_state)
  end

  defp ensure_collection!(%Collection{} = collection, _key), do: collection
  defp ensure_collection!(nil, _key), do: Collection.empty()

  defp ensure_collection!(value, key) do
    raise ArgumentError,
          "Solve dependency #{inspect(key)} expected a Solve.Collection, got: #{inspect(value)}"
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
