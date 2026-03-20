defmodule Solve do
  @moduledoc """
  Coordinates controller graph validation, lifecycle management, and subscriptions.

  `Solve` is the app-facing runtime API for a controller graph.

  Use `Solve.subscribe/3` to read the current exposed state of a named controller,
  and use `Solve.dispatch/4` as the default way to send events into the graph.

      current = Solve.subscribe(app, :counter)
      :ok = Solve.dispatch(app, :counter, :increment, %{amount: 1})

  `Solve.Controller.dispatch/3` remains available as a low-level primitive when you
  already have a concrete controller pid, but app code should prefer `Solve.dispatch/4`.

  Most user processes should interact through `Solve.Lookup`, which builds on top of these
  APIs and keeps a process-local cached view of controller state.
  """

  alias Solve.Controller
  alias Solve.ControllerSpec
  alias Solve.DependencyGraph
  alias Solve.Message
  alias Solve.Update

  @max_restart_attempts 3
  @restart_window_ms 5_000

  @type controller_name :: ControllerSpec.name()
  @type graph :: [ControllerSpec.t()]
  @type controller_status :: :started | :stopped

  @type runtime_state :: %{
          controller_specs_by_name: %{controller_name() => ControllerSpec.t()},
          sorted_controller_names: [controller_name()],
          dependents_map: %{controller_name() => [controller_name()]},
          app_params: term(),
          controller_pids_by_name: %{controller_name() => pid() | nil},
          controller_name_by_pid: %{pid() => controller_name()},
          controller_exposed_state_by_name: %{controller_name() => term()},
          controller_params_by_name: %{controller_name() => term()},
          controller_status_by_name: %{controller_name() => controller_status()},
          restart_timestamps_by_name: %{controller_name() => [integer()]},
          planned_stop_pids: MapSet.t(pid()),
          subscribers_by_controller_name: %{controller_name() => MapSet.t(pid())},
          subscriber_monitor_refs_by_pid: %{pid() => reference()}
        }

  @callback controllers() :: graph()

  defmacro __using__(_opts) do
    quote do
      @behaviour GenServer
      @behaviour Solve
      @after_compile Solve
      import Solve.ControllerSpec, only: [controller!: 1]

      def start_link(opts \\ []) do
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      @impl true
      def init(opts), do: Solve.init_runtime(__MODULE__, opts)

      @impl true
      def handle_call(message, from, state), do: Solve.__handle_call__(message, from, state)

      @impl true
      def handle_cast(message, state), do: Solve.__handle_cast__(message, state)

      @impl true
      def handle_info(message, state), do: Solve.__handle_info__(message, state)
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    DependencyGraph.resolve_module!(env.module, file: env.file, line: 1)
    :ok
  end

  @doc """
  Subscribes a process to a controller managed by a Solve app.

  Returns the current exposed state, or `nil` when the controller is currently stopped.
  """
  @spec subscribe(GenServer.server(), controller_name(), pid()) :: term()
  def subscribe(app, controller_name, subscriber \\ self())

  def subscribe(app, controller_name, subscriber) when is_pid(subscriber) do
    GenServer.call(app, {:subscribe, controller_name, subscriber})
  end

  def subscribe(_app, _controller_name, subscriber) do
    raise ArgumentError, "subscribe/3 expects a pid subscriber, got: #{inspect(subscriber)}"
  end

  @doc """
  Returns the current pid for a controller managed by a Solve app.
  """
  @spec controller_pid(GenServer.server(), controller_name()) :: pid() | nil
  def controller_pid(app, controller_name) do
    GenServer.call(app, {:controller_pid, controller_name})
  end

  @doc """
  Returns declared event names for a controller managed by a Solve app.
  """
  @spec controller_events(GenServer.server(), controller_name()) :: [atom()] | nil
  def controller_events(app, controller_name) do
    GenServer.call(app, {:controller_events, controller_name})
  end

  @doc """
  Dispatches an event to a controller managed by a Solve app.

  Returns `:ok`. If the controller is stopped or unknown, the dispatch is a silent no-op.
  """
  @spec dispatch(GenServer.server(), controller_name(), term(), term()) :: :ok
  def dispatch(app, controller_name, event, payload \\ %{}) do
    GenServer.cast(app, {:dispatch, controller_name, event, payload})
  end

  @doc false
  def init_runtime(solve_module, opts) do
    Process.flag(:trap_exit, true)

    app_params = Keyword.get(opts, :params, %{})

    solve_module
    |> DependencyGraph.resolve_module!()
    |> build_runtime_state(app_params)
    |> reconcile_all()
    |> case do
      {:ok, state} -> {:ok, state}
      {:stop, reason, _state} -> {:stop, reason}
    end
  end

  @doc false
  def __handle_call__({:subscribe, controller_name, subscriber}, _from, state)
      when is_pid(subscriber) do
    if Map.has_key?(state.controller_specs_by_name, controller_name) do
      state = register_external_subscriber(controller_name, subscriber, state)

      reply =
        case Map.get(state.controller_pids_by_name, controller_name) do
          nil -> nil
          pid -> Controller.subscribe(pid, subscriber)
        end

      {:reply, reply, state}
    else
      {:reply, nil, state}
    end
  end

  def __handle_call__({:controller_pid, controller_name}, _from, state) do
    {:reply, Map.get(state.controller_pids_by_name, controller_name), state}
  end

  def __handle_call__({:controller_events, controller_name}, _from, state) do
    reply =
      case Map.get(state.controller_specs_by_name, controller_name) do
        nil -> nil
        %ControllerSpec{module: module} -> module.__events__()
      end

    {:reply, reply, state}
  end

  def __handle_call__(_message, _from, state) do
    {:reply, {:error, :unsupported_call}, state}
  end

  @doc false
  def __handle_cast__({:dispatch, controller_name, event, payload}, state) do
    case Map.get(state.controller_pids_by_name, controller_name) do
      pid when is_pid(pid) -> Controller.dispatch(pid, event, payload)
      _ -> :ok
    end

    {:noreply, state}
  end

  def __handle_cast__(_message, state) do
    {:noreply, state}
  end

  @doc false
  def __handle_info__(
        %Message{
          type: :update,
          payload: %Update{
            app: solve_app,
            controller_name: controller_name,
            exposed_state: exposed_state
          }
        },
        state
      )
      when solve_app == self() do
    if Map.get(state.controller_status_by_name, controller_name) == :started do
      state = put_controller_exposed_state(controller_name, exposed_state, state)

      case reconcile_direct_dependents(controller_name, state, :runtime_update) do
        {:ok, state} -> {:noreply, state}
        {:stop, reason, state} -> {:stop, reason, state}
      end
    else
      {:noreply, state}
    end
  end

  def __handle_info__(%Message{type: :update, payload: %Update{}}, state) do
    {:noreply, state}
  end

  def __handle_info__({:EXIT, pid, reason}, %{planned_stop_pids: planned_stop_pids} = state)
      when is_pid(pid) do
    if MapSet.member?(planned_stop_pids, pid) do
      {:noreply, %{state | planned_stop_pids: MapSet.delete(planned_stop_pids, pid)}}
    else
      handle_controller_exit(pid, reason, state)
    end
  end

  def __handle_info__({:DOWN, ref, :process, subscriber, _reason}, state)
      when is_pid(subscriber) do
    if Map.get(state.subscriber_monitor_refs_by_pid, subscriber) == ref do
      {:noreply, unregister_external_subscriber(subscriber, state)}
    else
      {:noreply, state}
    end
  end

  def __handle_info__(_message, state) do
    {:noreply, state}
  end

  defp build_runtime_state(dependency_graph, app_params) do
    controller_names = dependency_graph.sorted_controller_names

    Map.merge(dependency_graph, %{
      app_params: app_params,
      controller_pids_by_name: Map.new(controller_names, &{&1, nil}),
      controller_name_by_pid: %{},
      controller_exposed_state_by_name: Map.new(controller_names, &{&1, nil}),
      controller_params_by_name: Map.new(controller_names, &{&1, nil}),
      controller_status_by_name: Map.new(controller_names, &{&1, :stopped}),
      restart_timestamps_by_name: Map.new(controller_names, &{&1, []}),
      planned_stop_pids: MapSet.new(),
      subscribers_by_controller_name: Map.new(controller_names, &{&1, MapSet.new()}),
      subscriber_monitor_refs_by_pid: %{}
    })
  end

  defp reconcile_all(state) do
    Enum.reduce_while(state.sorted_controller_names, {:ok, state}, fn controller_name,
                                                                      {:ok, state} ->
      case reconcile_controller(controller_name, state) do
        {:ok, _action, state} -> {:cont, {:ok, state}}
        {:stop, reason, state} -> {:halt, {:stop, reason, state}}
      end
    end)
  end

  defp reconcile_direct_dependents(source_name, state, transition) do
    Enum.reduce_while(ordered_dependents(source_name, state), {:ok, state}, fn dependent_name,
                                                                               {:ok, state} ->
      case reconcile_controller(dependent_name, state) do
        {:ok, action, state} ->
          state =
            sync_kept_dependent_with_source(
              source_name,
              dependent_name,
              transition,
              action,
              state
            )

          if action in [:started, :replaced, :stopped] do
            case reconcile_direct_dependents(
                   dependent_name,
                   state,
                   transition_for_controller(dependent_name, state)
                 ) do
              {:ok, state} -> {:cont, {:ok, state}}
              {:stop, reason, state} -> {:halt, {:stop, reason, state}}
            end
          else
            {:cont, {:ok, state}}
          end

        {:stop, reason, state} ->
          {:halt, {:stop, reason, state}}
      end
    end)
  end

  defp reconcile_controller(controller_name, state) do
    spec = Map.fetch!(state.controller_specs_by_name, controller_name)
    dependencies_snapshot = build_dependency_snapshot(spec, state)
    current_params = resolve_controller_params(spec, dependencies_snapshot, state.app_params)
    prev_params = Map.get(state.controller_params_by_name, controller_name)
    prev_pid = Map.get(state.controller_pids_by_name, controller_name)

    cond do
      is_nil(prev_pid) and falsy?(current_params) ->
        {:ok, :noop_stopped, cache_stopped_controller(controller_name, current_params, state)}

      is_pid(prev_pid) and falsy?(current_params) ->
        {:ok, state} = stop_controller_normal(controller_name, current_params, state)
        {:ok, :stopped, state}

      is_nil(prev_pid) and truthy?(current_params) ->
        case start_controller(controller_name, spec, current_params, dependencies_snapshot, state) do
          {:ok, state} -> {:ok, :started, state}
          {:stop, reason, state} -> {:stop, reason, state}
        end

      prev_params == current_params ->
        {:ok, :kept, cache_started_params(state, controller_name, current_params)}

      true ->
        case atomic_replace_controller(
               controller_name,
               spec,
               current_params,
               dependencies_snapshot,
               state
             ) do
          {:ok, state} -> {:ok, :replaced, state}
          {:stop, reason, state} -> {:stop, reason, state}
        end
    end
  end

  defp ordered_dependents(controller_name, state) do
    direct_dependents = state.dependents_map |> Map.get(controller_name, []) |> MapSet.new()

    Enum.filter(state.sorted_controller_names, &MapSet.member?(direct_dependents, &1))
  end

  defp transition_for_controller(controller_name, state) do
    case Map.get(state.controller_pids_by_name, controller_name) do
      nil -> :stopped
      pid -> {:running, pid}
    end
  end

  defp sync_kept_dependent_with_source(
         _source_name,
         _dependent_name,
         :runtime_update,
         _action,
         state
       ) do
    state
  end

  defp sync_kept_dependent_with_source(source_name, dependent_name, :stopped, :kept, state) do
    dependent_pid = Map.get(state.controller_pids_by_name, dependent_name)

    if is_pid(dependent_pid) do
      send(dependent_pid, Message.update(self(), source_name, nil))
    end

    state
  end

  defp sync_kept_dependent_with_source(
         source_name,
         dependent_name,
         {:running, source_pid},
         :kept,
         state
       ) do
    dependent_pid = Map.get(state.controller_pids_by_name, dependent_name)

    if is_pid(dependent_pid) do
      exposed_state = subscribe_controller_safely(source_pid, dependent_pid)

      if exposed_state != :subscription_failed do
        send(dependent_pid, Message.update(self(), source_name, exposed_state))
      end
    end

    state
  end

  defp sync_kept_dependent_with_source(_source_name, _dependent_name, _transition, _action, state) do
    state
  end

  defp build_dependency_snapshot(%ControllerSpec{dependencies: dependency_names}, state) do
    Map.new(dependency_names, fn dependency_name ->
      {dependency_name, Map.get(state.controller_exposed_state_by_name, dependency_name)}
    end)
  end

  defp resolve_controller_params(
         %ControllerSpec{params: params},
         dependencies_snapshot,
         app_params
       )
       when is_function(params, 1) do
    params.(%{dependencies: dependencies_snapshot, app_params: app_params})
  end

  defp resolve_controller_params(
         %ControllerSpec{params: params},
         _dependencies_snapshot,
         _app_params
       ) do
    params
  end

  defp start_controller(controller_name, spec, params, dependencies_snapshot, state) do
    callbacks = normalize_callbacks(spec.callbacks)

    case start_controller_instance(
           controller_name,
           spec.module,
           spec.dependencies,
           params,
           dependencies_snapshot,
           callbacks,
           state
         ) do
      {:ok, pid, exposed_state, state} ->
        state =
          state
          |> put_started_controller(controller_name, pid, params, exposed_state)
          |> attach_external_subscribers(controller_name, pid)

        {:ok, state}

      {:stop, reason, state} ->
        {:stop, reason, state}
    end
  end

  defp atomic_replace_controller(controller_name, spec, params, dependencies_snapshot, state) do
    old_pid = Map.fetch!(state.controller_pids_by_name, controller_name)
    callbacks = normalize_callbacks(spec.callbacks)

    case start_controller_instance(
           controller_name,
           spec.module,
           spec.dependencies,
           params,
           dependencies_snapshot,
           callbacks,
           state
         ) do
      {:ok, new_pid, exposed_state, state} ->
        state =
          state
          |> put_started_controller(controller_name, new_pid, params, exposed_state)
          |> delete_controller_pid_mapping(old_pid)
          |> put_planned_stop(old_pid)

        stop_controller_process(old_pid)

        state = attach_external_subscribers(state, controller_name, new_pid)
        {:ok, state}

      {:stop, reason, state} ->
        {:stop, reason, state}
    end
  end

  defp start_controller_instance(
         controller_name,
         controller_module,
         dependency_names,
         params,
         dependencies_snapshot,
         callbacks,
         state
       ) do
    opts = [
      solve_app: self(),
      controller_name: controller_name,
      params: params,
      dependencies: dependencies_snapshot,
      callbacks: callbacks
    ]

    attempt_start_controller_instance(
      controller_name,
      controller_module,
      dependency_names,
      dependencies_snapshot,
      opts,
      state
    )
  end

  defp attempt_start_controller_instance(
         controller_name,
         controller_module,
         dependency_names,
         dependencies_snapshot,
         opts,
         state
       ) do
    case safely_start_controller_instance(
           controller_module,
           dependency_names,
           dependencies_snapshot,
           opts,
           state
         ) do
      {:ok, pid, exposed_state, state} ->
        {:ok, pid, exposed_state, state}

      {:error, reason, state} ->
        now = System.monotonic_time(:millisecond)
        state = record_restart_attempt(controller_name, now, state)

        if restart_budget_exceeded?(controller_name, state) do
          {:stop, {:controller_restart_limit_exceeded, controller_name, reason}, state}
        else
          attempt_start_controller_instance(
            controller_name,
            controller_module,
            dependency_names,
            dependencies_snapshot,
            opts,
            state
          )
        end
    end
  end

  defp safely_start_controller_instance(
         controller_module,
         dependency_names,
         dependencies_snapshot,
         opts,
         state
       ) do
    cond do
      not function_exported?(controller_module, :start_link, 1) ->
        {:error, {:missing_controller_start_link, controller_module}, state}

      true ->
        case controller_module.start_link(opts) do
          {:ok, pid} ->
            case finalize_started_controller_instance(
                   pid,
                   dependency_names,
                   dependencies_snapshot,
                   state
                 ) do
              {:ok, exposed_state} -> {:ok, pid, exposed_state, state}
              {:error, reason} -> {:error, reason, state}
            end

          {:error, reason} ->
            {:error, reason, state}

          other ->
            {:error, {:invalid_controller_start, controller_module, other}, state}
        end
    end
  catch
    :exit, reason -> {:error, reason, state}
    kind, reason -> {:error, {kind, reason}, state}
  end

  defp finalize_started_controller_instance(pid, dependency_names, dependencies_snapshot, state) do
    :ok =
      subscribe_controller_to_dependencies(pid, dependency_names, dependencies_snapshot, state)

    {:ok, Controller.subscribe(pid, self())}
  catch
    :exit, reason ->
      stop_orphan_controller(pid)
      {:error, reason}

    kind, reason ->
      stop_orphan_controller(pid)
      {:error, {kind, reason}}
  end

  defp subscribe_controller_to_dependencies(pid, dependency_names, dependencies_snapshot, state) do
    Enum.each(dependency_names, fn dependency_name ->
      case Map.get(state.controller_pids_by_name, dependency_name) do
        nil ->
          :ok

        dependency_pid ->
          exposed_state = Controller.subscribe(dependency_pid, pid)

          if Map.get(dependencies_snapshot, dependency_name) != exposed_state do
            send(pid, Message.update(self(), dependency_name, exposed_state))
          end
      end
    end)

    :ok
  end

  defp stop_controller_normal(controller_name, params, state) do
    pid = Map.get(state.controller_pids_by_name, controller_name)

    state =
      state
      |> mark_controller_stopped(controller_name, params)
      |> put_planned_stop(pid)

    send_external_subscribers_update(controller_name, nil, state)
    stop_controller_process(pid)

    {:ok, state}
  end

  defp handle_controller_exit(pid, reason, state) do
    case Map.get(state.controller_name_by_pid, pid) do
      nil ->
        {:noreply, state}

      controller_name ->
        state =
          state
          |> delete_controller_pid_mapping(pid)
          |> mark_controller_stopped(controller_name, nil)

        send_external_subscribers_update(controller_name, nil, state)

        with {:ok, state} <- reconcile_direct_dependents(controller_name, state, :stopped),
             {:ok, state} <- maybe_restart_controller(controller_name, reason, state) do
          {:noreply, state}
        else
          {:stop, stop_reason, state} -> {:stop, stop_reason, state}
        end
    end
  end

  defp maybe_restart_controller(controller_name, crash_reason, state) do
    now = System.monotonic_time(:millisecond)
    state = record_restart_attempt(controller_name, now, state)

    if restart_budget_exceeded?(controller_name, state) do
      {:stop, {:controller_restart_limit_exceeded, controller_name, crash_reason}, state}
    else
      case reconcile_controller(controller_name, state) do
        {:ok, action, state} ->
          if action in [:started, :replaced] do
            reconcile_direct_dependents(
              controller_name,
              state,
              transition_for_controller(controller_name, state)
            )
          else
            {:ok, state}
          end

        {:stop, reason, state} ->
          {:stop, reason, state}
      end
    end
  end

  defp register_external_subscriber(controller_name, subscriber, state) do
    subscribers = Map.get(state.subscribers_by_controller_name, controller_name)

    state =
      put_in(
        state.subscribers_by_controller_name[controller_name],
        MapSet.put(subscribers, subscriber)
      )

    if Map.has_key?(state.subscriber_monitor_refs_by_pid, subscriber) do
      state
    else
      put_in(state.subscriber_monitor_refs_by_pid[subscriber], Process.monitor(subscriber))
    end
  end

  defp unregister_external_subscriber(subscriber, state) do
    subscribers_by_controller_name =
      Map.new(state.subscribers_by_controller_name, fn {controller_name, subscribers} ->
        {controller_name, MapSet.delete(subscribers, subscriber)}
      end)

    %{
      state
      | subscribers_by_controller_name: subscribers_by_controller_name,
        subscriber_monitor_refs_by_pid:
          Map.delete(state.subscriber_monitor_refs_by_pid, subscriber)
    }
  end

  defp attach_external_subscribers(state, controller_name, pid) do
    Enum.each(
      Map.get(state.subscribers_by_controller_name, controller_name, MapSet.new()),
      fn subscriber ->
        exposed_state = subscribe_controller_safely(pid, subscriber)

        if exposed_state != :subscription_failed do
          send(subscriber, Message.update(self(), controller_name, exposed_state))
        end
      end
    )

    state
  end

  defp send_external_subscribers_update(controller_name, exposed_state, state) do
    Enum.each(
      Map.get(state.subscribers_by_controller_name, controller_name, MapSet.new()),
      fn subscriber ->
        send(subscriber, Message.update(self(), controller_name, exposed_state))
      end
    )
  end

  defp put_started_controller(state, controller_name, pid, params, exposed_state) do
    state
    |> put_in([:controller_pids_by_name, controller_name], pid)
    |> put_in([:controller_name_by_pid, pid], controller_name)
    |> put_in([:controller_exposed_state_by_name, controller_name], exposed_state)
    |> put_in([:controller_params_by_name, controller_name], params)
    |> put_in([:controller_status_by_name, controller_name], :started)
  end

  defp cache_started_params(state, controller_name, params) do
    put_in(state.controller_params_by_name[controller_name], params)
  end

  defp cache_stopped_controller(controller_name, params, state) do
    state
    |> put_in([:controller_params_by_name, controller_name], params)
    |> put_in([:controller_status_by_name, controller_name], :stopped)
    |> put_in([:controller_exposed_state_by_name, controller_name], nil)
  end

  defp mark_controller_stopped(state, controller_name, params) do
    case Map.get(state.controller_pids_by_name, controller_name) do
      nil ->
        cache_stopped_controller(controller_name, params, state)

      pid ->
        state
        |> delete_controller_pid_mapping(pid)
        |> put_in([:controller_pids_by_name, controller_name], nil)
        |> put_in([:controller_exposed_state_by_name, controller_name], nil)
        |> put_in([:controller_params_by_name, controller_name], params)
        |> put_in([:controller_status_by_name, controller_name], :stopped)
    end
  end

  defp put_planned_stop(state, nil), do: state

  defp put_planned_stop(state, pid) do
    %{state | planned_stop_pids: MapSet.put(state.planned_stop_pids, pid)}
  end

  defp delete_controller_pid_mapping(state, nil), do: state

  defp delete_controller_pid_mapping(state, pid) do
    %{state | controller_name_by_pid: Map.delete(state.controller_name_by_pid, pid)}
  end

  defp put_controller_exposed_state(controller_name, exposed_state, state) do
    put_in(state.controller_exposed_state_by_name[controller_name], exposed_state)
  end

  defp record_restart_attempt(controller_name, now, state) do
    timestamps =
      state.restart_timestamps_by_name
      |> Map.get(controller_name, [])
      |> Enum.filter(&(now - &1 < @restart_window_ms))
      |> Kernel.++([now])

    put_in(state.restart_timestamps_by_name[controller_name], timestamps)
  end

  defp restart_budget_exceeded?(controller_name, state) do
    length(Map.get(state.restart_timestamps_by_name, controller_name, [])) > @max_restart_attempts
  end

  defp subscribe_controller_safely(controller_pid, subscriber) do
    Controller.subscribe(controller_pid, subscriber)
  catch
    :exit, _reason -> :subscription_failed
  end

  defp normalize_callbacks(nil), do: %{}
  defp normalize_callbacks(callbacks), do: callbacks

  defp stop_controller_process(nil), do: :ok

  defp stop_controller_process(pid) do
    GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_orphan_controller(pid) do
    if is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :kill)
    end
  end

  defp falsy?(value), do: value in [nil, false]
  defp truthy?(value), do: not falsy?(value)
end
