defmodule Solve do
  @moduledoc """
  Coordinates controller graph validation, lifecycle management, and subscriptions.
  """

  alias Solve.Collection
  alias Solve.Controller
  alias Solve.ControllerSpec
  alias Solve.DependencyGraph
  alias Solve.DependencyUpdate
  alias Solve.Message
  alias Solve.Update

  @max_restart_attempts 3
  @restart_window_ms 5_000

  @type controller_name :: ControllerSpec.name()
  @type controller_target :: controller_name() | {controller_name(), Collection.id()}
  @type graph :: [ControllerSpec.t()]
  @type controller_status :: :started | :stopped

  @type runtime_state :: map()

  @callback controllers() :: graph()

  defmacro __using__(_opts) do
    quote do
      @behaviour GenServer
      @behaviour Solve
      import Solve.ControllerSpec, only: [controller!: 1]

      defp collection(source), do: Solve.ControllerSpec.collection(source)
      defp collection(source, filter), do: Solve.ControllerSpec.collection(source, filter)
      defp dispatch(controller_name, event), do: Solve.dispatch(controller_name, event)

      defp dispatch(controller_name, event, payload),
        do: Solve.dispatch(controller_name, event, payload)

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

  @spec subscribe(GenServer.server(), controller_target(), pid()) :: term()
  def subscribe(app, controller_name, subscriber \\ self())

  def subscribe(app, controller_name, subscriber) when is_pid(subscriber) do
    GenServer.call(app, {:subscribe, controller_name, subscriber})
  end

  def subscribe(_app, _controller_name, subscriber) do
    raise ArgumentError, "subscribe/3 expects a pid subscriber, got: #{inspect(subscriber)}"
  end

  @spec controller_pid(GenServer.server(), controller_target()) :: pid() | nil
  def controller_pid(app, controller_name) do
    GenServer.call(app, {:controller_pid, controller_name})
  end

  @spec controller_events(GenServer.server(), controller_target()) :: [atom()] | nil
  def controller_events(app, controller_name) do
    GenServer.call(app, {:controller_events, controller_name})
  end

  @spec controller_variant(GenServer.server(), controller_name()) ::
          ControllerSpec.variant() | nil
  def controller_variant(app, controller_name) do
    GenServer.call(app, {:controller_variant, controller_name})
  end

  @spec dispatch(controller_target(), atom()) :: :ok
  def dispatch(controller_name, event) when is_atom(event) do
    dispatch(controller_name, event, %{})
  end

  @spec dispatch(controller_target(), atom(), term()) :: :ok
  def dispatch(controller_name, event, payload) when is_atom(event) do
    resolve_current_app!()
    |> dispatch(controller_name, event, payload)
  end

  @spec dispatch(GenServer.server(), controller_target(), term(), term()) :: :ok
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
  def __handle_call__({:subscribe, target, subscriber}, _from, state) when is_pid(subscriber) do
    case resolve_subscription_target(target, state) do
      {:ok, {:collection_source, source_name}} ->
        state = register_external_subscriber(source_name, subscriber, state)
        {:reply, source_collection(source_name, state), state}

      {:ok, {:target, target_key}} ->
        state = register_external_subscriber(target_key, subscriber, state)

        reply =
          case Map.get(state.controller_pids_by_target, target_key) do
            pid when is_pid(pid) -> Controller.subscribe(pid, subscriber)
            _ -> nil
          end

        {:reply, reply, state}

      :error ->
        {:reply, nil, state}
    end
  end

  def __handle_call__({:controller_pid, target}, _from, state) do
    reply =
      case resolve_runtime_target(target, state) do
        {:ok, {:collection_source, _source_name}} -> nil
        {:ok, {:target, target_key}} -> Map.get(state.controller_pids_by_target, target_key)
        :error -> nil
      end

    {:reply, reply, state}
  end

  def __handle_call__({:controller_events, target}, _from, state) do
    reply =
      case source_name_for_target(target, state) do
        nil ->
          nil

        source_name ->
          case Map.get(state.controller_specs_by_name, source_name) do
            nil -> nil
            %ControllerSpec{module: module} -> module.__events__()
          end
      end

    {:reply, reply, state}
  end

  def __handle_call__({:controller_variant, controller_name}, _from, state) do
    reply =
      case Map.get(state.controller_specs_by_name, controller_name) do
        nil -> nil
        %ControllerSpec{variant: variant} -> variant
      end

    {:reply, reply, state}
  end

  def __handle_call__(_message, _from, state) do
    {:reply, {:error, :unsupported_call}, state}
  end

  @doc false
  def __handle_cast__({:dispatch, target, event, payload}, state) do
    case resolve_runtime_target(target, state) do
      {:ok, {:target, target_key}} ->
        case Map.get(state.controller_pids_by_target, target_key) do
          pid when is_pid(pid) -> Controller.dispatch(pid, event, payload)
          _ -> :ok
        end

      _ ->
        :ok
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
          payload: %Update{app: solve_app, controller_name: target, exposed_state: exposed_state}
        },
        state
      )
      when solve_app == self() do
    if Map.get(state.controller_status_by_target, target) == :started do
      {state, source_name, _source_changed?} =
        apply_runtime_target_update(target, exposed_state, state)

      case reconcile_direct_dependents(source_name, state) do
        {:ok, state} ->
          {:noreply, state}

        {:stop, reason, state} ->
          {:stop, reason, state}
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

    singleton_targets =
      Enum.filter(controller_names, fn name ->
        dependency_graph.controller_specs_by_name[name].variant == :singleton
      end)

    Map.merge(dependency_graph, %{
      app_params: app_params,
      controller_pids_by_name: Map.new(controller_names, &{&1, nil}),
      controller_exposed_state_by_name:
        Map.new(controller_names, fn name ->
          {name,
           initial_source_value(Map.fetch!(dependency_graph.controller_specs_by_name, name))}
        end),
      controller_params_by_name: Map.new(controller_names, &{&1, nil}),
      controller_status_by_name: Map.new(controller_names, &{&1, :stopped}),
      restart_timestamps_by_name: Map.new(controller_names, &{&1, []}),
      controller_pids_by_target: Map.new(singleton_targets, &{&1, nil}),
      controller_name_by_pid: %{},
      controller_exposed_state_by_target: Map.new(singleton_targets, &{&1, nil}),
      controller_params_by_target: Map.new(singleton_targets, &{&1, nil}),
      controller_status_by_target: Map.new(singleton_targets, &{&1, :stopped}),
      controller_callbacks_by_target: Map.new(singleton_targets, &{&1, %{}}),
      restart_timestamps_by_target: Map.new(singleton_targets, &{&1, []}),
      dependency_subscription_state_by_target: %{},
      planned_stop_pids: MapSet.new(),
      subscribers_by_controller_name: Map.new(controller_names, &{&1, MapSet.new()}),
      subscriber_monitor_refs_by_pid: %{}
    })
  end

  defp initial_source_value(%ControllerSpec{variant: :collection}), do: Collection.empty()
  defp initial_source_value(%ControllerSpec{}), do: nil

  defp reconcile_all(state) do
    Enum.reduce_while(state.sorted_controller_names, {:ok, state}, fn controller_name,
                                                                      {:ok, state} ->
      case reconcile_controller(controller_name, state) do
        {:ok, _result, state} -> {:cont, {:ok, state}}
        {:stop, reason, state} -> {:halt, {:stop, reason, state}}
      end
    end)
  end

  defp reconcile_direct_dependents(source_name, state) do
    Enum.reduce_while(ordered_dependents(source_name, state), {:ok, state}, fn dependent_name,
                                                                               {:ok, state} ->
      case reconcile_controller(dependent_name, state) do
        {:ok, %{source_changed?: true}, state} ->
          case reconcile_direct_dependents(dependent_name, state) do
            {:ok, state} -> {:cont, {:ok, state}}
            {:stop, reason, state} -> {:halt, {:stop, reason, state}}
          end

        {:ok, _result, state} ->
          {:cont, {:ok, state}}

        {:stop, reason, state} ->
          {:halt, {:stop, reason, state}}
      end
    end)
  end

  defp reconcile_controller(controller_name, state) do
    spec = Map.fetch!(state.controller_specs_by_name, controller_name)
    dependencies_snapshot = build_dependency_snapshot(spec, state)
    current_params = resolve_controller_params(spec, dependencies_snapshot, state.app_params)

    case spec.variant do
      :singleton ->
        reconcile_singleton_controller(
          controller_name,
          spec,
          current_params,
          dependencies_snapshot,
          state
        )

      :collection ->
        reconcile_collection_controller(
          controller_name,
          spec,
          current_params,
          dependencies_snapshot,
          state
        )
    end
  end

  defp reconcile_singleton_controller(
         controller_name,
         spec,
         current_params,
         dependencies_snapshot,
         state
       ) do
    prev_params = Map.get(state.controller_params_by_name, controller_name)
    prev_pid = Map.get(state.controller_pids_by_target, controller_name)
    desired_callbacks = normalize_callbacks(spec.callbacks)

    cond do
      is_nil(prev_pid) and falsy?(current_params) ->
        {:ok, %{action: :noop_stopped, source_changed?: false},
         cache_stopped_singleton(controller_name, current_params, state)}

      is_pid(prev_pid) and falsy?(current_params) ->
        {:ok, state} = stop_singleton_controller(controller_name, current_params, state)
        {:ok, %{action: :stopped, source_changed?: true}, state}

      is_nil(prev_pid) and truthy?(current_params) ->
        case start_singleton_controller(
               controller_name,
               spec,
               current_params,
               dependencies_snapshot,
               state
             ) do
          {:ok, state} ->
            {:ok, %{action: :started, source_changed?: true}, state}

          {:stop, reason, state} ->
            {:stop, reason, state}
        end

      prev_params == current_params ->
        state =
          state
          |> cache_started_singleton_params(controller_name, current_params)
          |> sync_target_callbacks(controller_name, prev_pid, desired_callbacks)

        case reconcile_target_bindings(controller_name, spec, state, initial: false) do
          {:ok, state} -> {:ok, %{action: :kept, source_changed?: false}, state}
          {:stop, reason, state} -> {:stop, reason, state}
        end

      true ->
        case replace_singleton_controller(
               controller_name,
               spec,
               current_params,
               dependencies_snapshot,
               state
             ) do
          {:ok, state} -> {:ok, %{action: :replaced, source_changed?: true}, state}
          {:stop, reason, state} -> {:stop, reason, state}
        end
    end
  end

  defp reconcile_collection_controller(
         controller_name,
         spec,
         current_params,
         dependencies_snapshot,
         state
       ) do
    prev_collection = source_collection(controller_name, state)
    prev_params = Map.get(state.controller_params_by_name, controller_name)

    with {:ok, desired_entries} <-
           resolve_collected_entries(
             controller_name,
             spec,
             current_params,
             dependencies_snapshot,
             state
           ),
         {:ok, state} <-
           reconcile_collection_items(
             controller_name,
             spec,
             desired_entries,
             dependencies_snapshot,
             state
           ),
         {:ok, state} <- reconcile_collection_child_bindings(controller_name, spec, state) do
      desired_ids = Enum.map(desired_entries, &elem(&1, 0))
      next_collection = build_collection_from_targets(controller_name, desired_ids, state)
      source_changed? = next_collection != prev_collection

      state =
        state
        |> put_in([:controller_params_by_name, controller_name], current_params)
        |> put_in(
          [:controller_status_by_name, controller_name],
          if(truthy?(current_params), do: :started, else: :stopped)
        )
        |> put_in([:controller_exposed_state_by_name, controller_name], next_collection)
        |> put_in([:controller_pids_by_name, controller_name], nil)

      if source_changed? do
        send_external_subscribers_update(controller_name, next_collection, state)
      end

      action =
        cond do
          not truthy?(prev_params) and truthy?(current_params) -> :started
          truthy?(prev_params) and not truthy?(current_params) -> :stopped
          source_changed? -> :changed
          true -> :kept
        end

      {:ok, %{action: action, source_changed?: source_changed?}, state}
    else
      {:stop, reason, state} -> {:stop, reason, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp ordered_dependents(controller_name, state) do
    direct_dependents = state.dependents_map |> Map.get(controller_name, []) |> MapSet.new()

    Enum.filter(state.sorted_controller_names, &MapSet.member?(direct_dependents, &1))
  end

  defp build_dependency_snapshot(%ControllerSpec{dependency_bindings: bindings}, state) do
    Map.new(bindings, fn binding -> {binding.key, binding_value(binding, state)} end)
  end

  defp binding_value(%{kind: :single, source: source}, state) do
    Map.get(state.controller_exposed_state_by_name, source)
  end

  defp binding_value(%{kind: :collection, source: source, filter: nil}, state) do
    source_collection(source, state)
  end

  defp binding_value(%{kind: :collection, source: source, filter: filter}, state) do
    source
    |> source_collection(state)
    |> filter_collection(filter)
  end

  defp filter_collection(%Collection{} = collection, filter) do
    Enum.reduce(collection.ids, Collection.empty(), fn id, acc ->
      item = Map.fetch!(collection.items, id)

      if filter.(id, item) do
        Collection.put(acc, id, item)
      else
        acc
      end
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

  defp resolve_collected_entries(
         _controller_name,
         _spec,
         current_params,
         _dependencies_snapshot,
         _state
       )
       when current_params in [nil, false] do
    {:ok, []}
  end

  defp resolve_collected_entries(
         controller_name,
         %ControllerSpec{collect: collect},
         _current_params,
         dependencies_snapshot,
         state
       )
       when is_function(collect, 1) do
    context = %{dependencies: dependencies_snapshot, app_params: state.app_params}
    validate_collected_entries(controller_name, collect.(context))
  rescue
    error -> {:error, {:collect_failed, controller_name, error}}
  end

  defp validate_collected_entries(controller_name, entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, [], MapSet.new()}, fn entry, {:ok, normalized, seen_ids} ->
      with {:ok, id, opts} <- validate_collected_entry(controller_name, entry),
           :ok <- validate_unique_collected_id(controller_name, id, seen_ids) do
        {:cont, {:ok, normalized ++ [{id, opts}], MapSet.put(seen_ids, id)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized, _seen_ids} -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_collected_entries(controller_name, value) do
    {:error, {:invalid_collect_result, controller_name, value}}
  end

  defp validate_collected_entry(_controller_name, {id, opts}) when is_list(opts) do
    callbacks = normalize_callbacks(Keyword.get(opts, :callbacks))
    {:ok, id, %{params: Keyword.get(opts, :params, true), callbacks: callbacks}}
  end

  defp validate_collected_entry(controller_name, entry) do
    {:error, {:invalid_collect_entry, controller_name, entry}}
  end

  defp validate_unique_collected_id(controller_name, id, seen_ids) do
    if MapSet.member?(seen_ids, id) do
      {:error, {:duplicate_collected_id, controller_name, id}}
    else
      :ok
    end
  end

  defp reconcile_collection_items(
         controller_name,
         spec,
         desired_entries,
         dependencies_snapshot,
         state
       ) do
    prev_ids = source_collection(controller_name, state).ids
    desired_ids = Enum.map(desired_entries, &elem(&1, 0))
    removed_ids = prev_ids -- desired_ids

    with {:ok, state} <-
           Enum.reduce_while(removed_ids, {:ok, state}, fn id, {:ok, acc} ->
             {:cont, stop_collection_item(controller_name, id, acc)}
           end),
         {:ok, state} <-
           Enum.reduce_while(desired_entries, {:ok, state}, fn {id, item_opts}, {:ok, acc} ->
             target = {controller_name, id}
             current_pid = Map.get(acc.controller_pids_by_target, target)
             current_params = Map.get(acc.controller_params_by_target, target)
             desired_callbacks = Map.merge(spec.callbacks, item_opts.callbacks)

             cond do
               is_nil(current_pid) ->
                 case start_collection_item(
                        controller_name,
                        id,
                        spec,
                        item_opts.params,
                        desired_callbacks,
                        dependencies_snapshot,
                        acc
                      ) do
                   {:ok, next} -> {:cont, {:ok, next}}
                   {:stop, reason, next} -> {:halt, {:stop, reason, next}}
                 end

               current_params == item_opts.params ->
                 {:cont,
                  {:ok, sync_target_callbacks(acc, target, current_pid, desired_callbacks)}}

               true ->
                 case replace_collection_item(
                        controller_name,
                        id,
                        spec,
                        item_opts.params,
                        desired_callbacks,
                        dependencies_snapshot,
                        acc
                      ) do
                   {:ok, next} -> {:cont, {:ok, next}}
                   {:stop, reason, next} -> {:halt, {:stop, reason, next}}
                 end
             end
           end) do
      {:ok, state}
    end
  end

  defp reconcile_collection_child_bindings(controller_name, spec, state) do
    desired_ids = source_collection(controller_name, state).ids

    Enum.reduce_while(desired_ids, {:ok, state}, fn id, {:ok, acc} ->
      target = {controller_name, id}

      case reconcile_target_bindings(target, spec, acc, initial: false) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:stop, reason, next} -> {:halt, {:stop, reason, next}}
      end
    end)
  end

  defp start_singleton_controller(controller_name, spec, params, dependencies_snapshot, state) do
    callbacks = normalize_callbacks(spec.callbacks)

    with {:ok, pid, exposed_state, state} <-
           start_target_instance(
             controller_name,
             spec.module,
             params,
             callbacks,
             dependencies_snapshot,
             state
           ),
         {:ok, state} <-
           reconcile_target_bindings(
             controller_name,
             spec,
             put_started_singleton(state, controller_name, pid, params, callbacks, exposed_state),
             initial: true
           ) do
      state = attach_external_subscribers(state, controller_name, pid)
      {:ok, state}
    end
  end

  defp replace_singleton_controller(controller_name, spec, params, dependencies_snapshot, state) do
    old_pid = Map.fetch!(state.controller_pids_by_target, controller_name)
    callbacks = normalize_callbacks(spec.callbacks)

    with {:ok, pid, exposed_state, state} <-
           start_target_instance(
             controller_name,
             spec.module,
             params,
             callbacks,
             dependencies_snapshot,
             state
           ) do
      state =
        state
        |> cleanup_target_bindings(controller_name)
        |> put_started_singleton(controller_name, pid, params, callbacks, exposed_state)
        |> delete_controller_pid_mapping(old_pid)
        |> put_planned_stop(old_pid)

      stop_controller_process(old_pid)

      with {:ok, state} <- reconcile_target_bindings(controller_name, spec, state, initial: true) do
        state = attach_external_subscribers(state, controller_name, pid)
        {:ok, state}
      end
    end
  end

  defp stop_singleton_controller(controller_name, params, state) do
    pid = Map.get(state.controller_pids_by_target, controller_name)

    state =
      state
      |> cleanup_target_bindings(controller_name)
      |> mark_singleton_stopped(controller_name, params)
      |> put_planned_stop(pid)

    send_external_subscribers_update(controller_name, nil, state)
    stop_controller_process(pid)

    {:ok, state}
  end

  defp start_collection_item(
         controller_name,
         id,
         spec,
         params,
         callbacks,
         dependencies_snapshot,
         state
       ) do
    target = {controller_name, id}

    with {:ok, pid, exposed_state, state} <-
           start_target_instance(
             target,
             spec.module,
             params,
             callbacks,
             dependencies_snapshot,
             state
           ),
         {:ok, state} <-
           reconcile_target_bindings(
             target,
             spec,
             put_started_target(state, target, pid, params, callbacks, exposed_state),
             initial: true
           ) do
      state = attach_external_subscribers(state, target, pid)
      {:ok, state}
    end
  end

  defp replace_collection_item(
         controller_name,
         id,
         spec,
         params,
         callbacks,
         dependencies_snapshot,
         state
       ) do
    target = {controller_name, id}
    old_pid = Map.fetch!(state.controller_pids_by_target, target)

    with {:ok, pid, exposed_state, state} <-
           start_target_instance(
             target,
             spec.module,
             params,
             callbacks,
             dependencies_snapshot,
             state
           ) do
      state =
        state
        |> cleanup_target_bindings(target)
        |> put_started_target(target, pid, params, callbacks, exposed_state)
        |> delete_controller_pid_mapping(old_pid)
        |> put_planned_stop(old_pid)

      stop_controller_process(old_pid)

      with {:ok, state} <- reconcile_target_bindings(target, spec, state, initial: true) do
        state = attach_external_subscribers(state, target, pid)
        {:ok, state}
      end
    end
  end

  defp stop_collection_item(controller_name, id, state) do
    target = {controller_name, id}
    pid = Map.get(state.controller_pids_by_target, target)

    state =
      state
      |> cleanup_target_bindings(target)
      |> mark_target_stopped(target, nil)
      |> put_planned_stop(pid)

    send_external_subscribers_update(target, nil, state)
    stop_controller_process(pid)

    {:ok, state}
  end

  defp start_target_instance(
         target,
         controller_module,
         params,
         callbacks,
         dependencies_snapshot,
         state
       ) do
    opts = [
      solve_app: self(),
      controller_name: target,
      params: params,
      dependencies: dependencies_snapshot,
      callbacks: callbacks
    ]

    attempt_start_target_instance(target, controller_module, opts, state)
  end

  defp attempt_start_target_instance(target, controller_module, opts, state) do
    case safely_start_target_instance(controller_module, opts, state) do
      {:ok, pid, exposed_state, state} ->
        {:ok, pid, exposed_state, state}

      {:error, reason, state} ->
        now = System.monotonic_time(:millisecond)
        state = record_restart_attempt(target, now, state)

        if restart_budget_exceeded?(target, state) do
          {:stop, {:controller_restart_limit_exceeded, target, reason}, state}
        else
          attempt_start_target_instance(target, controller_module, opts, state)
        end
    end
  end

  defp safely_start_target_instance(controller_module, opts, state) do
    case Code.ensure_loaded(controller_module) do
      {:module, ^controller_module} ->
        cond do
          not function_exported?(controller_module, :start_link, 1) ->
            {:error, {:missing_controller_start_link, controller_module}, state}

          true ->
            case controller_module.start_link(opts) do
              {:ok, pid} ->
                {:ok, pid, Controller.subscribe(pid, self()), state}

              {:error, reason} ->
                {:error, reason, state}

              other ->
                {:error, {:invalid_controller_start, controller_module, other}, state}
            end
        end

      {:error, reason} ->
        {:error, {:controller_module_not_loaded, controller_module, reason}, state}
    end
  catch
    :exit, reason -> {:error, reason, state}
    kind, reason -> {:error, {kind, reason}, state}
  end

  defp reconcile_target_bindings(target, spec, state, opts) do
    pid = Map.get(state.controller_pids_by_target, target)

    if is_pid(pid) do
      initial? = Keyword.get(opts, :initial, false)

      Enum.reduce_while(spec.dependency_bindings, {:ok, state}, fn binding, {:ok, acc} ->
        case binding.kind do
          :single ->
            {:cont, reconcile_single_binding(target, pid, binding, spec, acc, initial?)}

          :collection ->
            {:cont, reconcile_collection_binding(target, pid, binding, acc, initial?)}
        end
      end)
    else
      {:ok, state}
    end
  end

  defp reconcile_single_binding(target, dependent_pid, binding, _spec, state, initial?) do
    current_binding_state = get_binding_state(state, target, binding.key)
    source_target = binding.source
    source_pid = Map.get(state.controller_pids_by_target, source_target)
    snapshot_value = binding_value(binding, state)

    cond do
      is_pid(source_pid) and same_single_binding?(current_binding_state, source_target) ->
        {:ok, state}

      is_pid(source_pid) ->
        state = cleanup_binding_subscription(state, current_binding_state)
        solve_app = self()

        encoder = fn exposed_state ->
          DependencyUpdate.replace(solve_app, binding.key, exposed_state)
        end

        case subscribe_controller_with_safely(source_pid, dependent_pid, encoder) do
          {:ok, current_exposed_state, subscription_ref} ->
            if not initial? or snapshot_value != current_exposed_state do
              send(dependent_pid, encoder.(current_exposed_state))
            end

            binding_state = %{
              kind: :single,
              source: binding.source,
              child_target: source_target,
              subscription_ref: subscription_ref
            }

            {:ok, put_binding_state(state, target, binding.key, binding_state)}

          :subscription_failed ->
            {:ok, state}
        end

      true ->
        state = cleanup_binding_subscription(state, current_binding_state)

        if current_binding_state != nil do
          send(dependent_pid, DependencyUpdate.replace(self(), binding.key, nil))
        end

        {:ok, delete_binding_state(state, target, binding.key)}
    end
  end

  defp reconcile_collection_binding(target, dependent_pid, binding, state, initial?) do
    desired_collection = binding_value(binding, state)
    desired_ids = desired_collection.ids

    current_binding_state =
      get_binding_state(state, target, binding.key) || default_collection_binding_state(binding)

    current_ids = current_binding_state.ids
    current_refs = current_binding_state.subscription_refs_by_id

    state =
      Enum.reduce(current_ids -- desired_ids, state, fn id, acc ->
        case Map.get(current_refs, id) do
          nil ->
            delete_collection_binding_subscription(acc, target, binding.key, id)

          entry ->
            send(dependent_pid, DependencyUpdate.collection_delete(self(), binding.key, id))

            acc
            |> unsubscribe_collection_binding_entry(entry)
            |> delete_collection_binding_subscription(target, binding.key, id)
        end
      end)

    current_binding_state =
      get_binding_state(state, target, binding.key) || default_collection_binding_state(binding)

    state =
      Enum.reduce(desired_ids -- current_binding_state.ids, state, fn id, acc ->
        child_target = {binding.source, id}

        case Map.get(acc.controller_pids_by_target, child_target) do
          pid when is_pid(pid) ->
            encoder = build_collection_encoder(binding, id)

            case subscribe_controller_with_safely(pid, dependent_pid, encoder) do
              {:ok, current_exposed_state, subscription_ref} ->
                if not initial? do
                  send(dependent_pid, encoder.(current_exposed_state))
                else
                  snapshot_item = Collection.get(desired_collection, id)

                  if snapshot_item != current_exposed_state do
                    send(dependent_pid, encoder.(current_exposed_state))
                  end
                end

                put_collection_binding_subscription(
                  acc,
                  target,
                  binding.key,
                  id,
                  %{target: child_target, subscription_ref: subscription_ref}
                )

              :subscription_failed ->
                acc
            end

          _ ->
            acc
        end
      end)

    if not initial? and current_ids != desired_ids do
      send(dependent_pid, DependencyUpdate.collection_reorder(self(), binding.key, desired_ids))
    end

    binding_state =
      get_binding_state(state, target, binding.key) || default_collection_binding_state(binding)

    {:ok, put_binding_state(state, target, binding.key, %{binding_state | ids: desired_ids})}
  end

  defp default_collection_binding_state(binding) do
    %{
      kind: :collection,
      source: binding.source,
      filter: binding.filter,
      ids: [],
      subscription_refs_by_id: %{}
    }
  end

  defp build_collection_encoder(%{filter: nil, key: key}, id) do
    solve_app = self()
    fn exposed_state -> DependencyUpdate.collection_put(solve_app, key, id, exposed_state) end
  end

  defp build_collection_encoder(%{filter: filter, key: key}, id) do
    solve_app = self()

    fn exposed_state ->
      if filter.(id, exposed_state) do
        DependencyUpdate.collection_put(solve_app, key, id, exposed_state)
      else
        DependencyUpdate.collection_delete(solve_app, key, id)
      end
    end
  end

  defp same_single_binding?(
         %{kind: :single, child_target: child_target, subscription_ref: subscription_ref},
         source_target
       )
       when not is_nil(subscription_ref) do
    child_target == source_target
  end

  defp same_single_binding?(_binding_state, _source_target), do: false

  defp get_binding_state(state, target, key) do
    state.dependency_subscription_state_by_target
    |> Map.get(target, %{})
    |> Map.get(key)
  end

  defp put_binding_state(state, target, key, binding_state) do
    binding_states = Map.get(state.dependency_subscription_state_by_target, target, %{})
    next_binding_states = Map.put(binding_states, key, binding_state)
    put_in(state.dependency_subscription_state_by_target[target], next_binding_states)
  end

  defp delete_binding_state(state, target, key) do
    case get_in(state, [:dependency_subscription_state_by_target, target]) do
      nil ->
        state

      binding_states ->
        next_binding_states = Map.delete(binding_states, key)

        if next_binding_states == %{} do
          update_in(state.dependency_subscription_state_by_target, &Map.delete(&1, target))
        else
          put_in(state, [:dependency_subscription_state_by_target, target], next_binding_states)
        end
    end
  end

  defp put_collection_binding_subscription(state, target, key, id, entry) do
    binding_state =
      get_binding_state(state, target, key) || %{subscription_refs_by_id: %{}, ids: []}

    put_binding_state(state, target, key, %{
      binding_state
      | subscription_refs_by_id: Map.put(binding_state.subscription_refs_by_id, id, entry)
    })
  end

  defp delete_collection_binding_subscription(state, target, key, id) do
    case get_binding_state(state, target, key) do
      nil ->
        state

      binding_state ->
        put_binding_state(state, target, key, %{
          binding_state
          | subscription_refs_by_id: Map.delete(binding_state.subscription_refs_by_id, id)
        })
    end
  end

  defp cleanup_binding_subscription(state, nil), do: state

  defp cleanup_binding_subscription(state, %{
         target: source_target,
         subscription_ref: subscription_ref
       }) do
    unsubscribe_dependency_subscription(source_target, subscription_ref, state)
    state
  end

  defp cleanup_binding_subscription(state, %{
         kind: :single,
         child_target: source_target,
         subscription_ref: subscription_ref
       }) do
    unsubscribe_dependency_subscription(source_target, subscription_ref, state)
    state
  end

  defp unsubscribe_collection_binding_entry(state, %{
         target: source_target,
         subscription_ref: subscription_ref
       }) do
    unsubscribe_dependency_subscription(source_target, subscription_ref, state)
    state
  end

  defp cleanup_target_bindings(state, target) do
    case Map.get(state.dependency_subscription_state_by_target, target) do
      nil ->
        state

      binding_states ->
        state =
          Enum.reduce(binding_states, state, fn {_key, binding_state}, acc ->
            cleanup_binding_state(acc, binding_state)
          end)

        update_in(state.dependency_subscription_state_by_target, &Map.delete(&1, target))
    end
  end

  defp cleanup_binding_state(state, %{
         kind: :single,
         child_target: source_target,
         subscription_ref: subscription_ref
       }) do
    unsubscribe_dependency_subscription(source_target, subscription_ref, state)
    state
  end

  defp cleanup_binding_state(state, %{
         kind: :collection,
         subscription_refs_by_id: subscription_refs_by_id
       }) do
    Enum.reduce(subscription_refs_by_id, state, fn {_id, entry}, acc ->
      unsubscribe_collection_binding_entry(acc, entry)
    end)
  end

  defp cleanup_binding_state(state, _binding_state), do: state

  defp unsubscribe_dependency_subscription(source_target, subscription_ref, state) do
    case Map.get(state.controller_pids_by_target, source_target) do
      pid when is_pid(pid) -> unsubscribe_controller_safely(pid, subscription_ref)
      _ -> :ok
    end
  end

  defp apply_runtime_target_update(target, exposed_state, state) do
    state = put_target_exposed_state(target, exposed_state, state)
    source_name = source_name_for_target(target, state)

    case target do
      {collection_name, id} ->
        prev_collection = source_collection(collection_name, state)
        next_collection = Collection.put(prev_collection, id, exposed_state)
        source_changed? = next_collection != prev_collection

        state = put_in(state.controller_exposed_state_by_name[collection_name], next_collection)

        if source_changed? do
          send_external_subscribers_update(collection_name, next_collection, state)
        end

        {state, collection_name, source_changed?}

      source when is_atom(source) ->
        {put_in(state.controller_exposed_state_by_name[source], exposed_state), source_name,
         false}
    end
  end

  defp handle_controller_exit(pid, reason, state) do
    case Map.get(state.controller_name_by_pid, pid) do
      nil ->
        {:noreply, state}

      target when is_atom(target) ->
        state =
          state
          |> cleanup_target_bindings(target)
          |> delete_controller_pid_mapping(pid)
          |> mark_singleton_stopped(target, nil)

        send_external_subscribers_update(target, nil, state)

        with {:ok, state} <- reconcile_direct_dependents(target, state),
             {:ok, state} <- maybe_restart_singleton(target, reason, state) do
          {:noreply, state}
        else
          {:stop, stop_reason, state} -> {:stop, stop_reason, state}
        end

      {collection_name, id} = target ->
        prev_collection = source_collection(collection_name, state)

        state =
          state
          |> cleanup_target_bindings(target)
          |> delete_controller_pid_mapping(pid)
          |> mark_target_stopped(target, nil)

        send_external_subscribers_update(target, nil, state)

        next_collection = Collection.delete(prev_collection, id)
        state = put_in(state.controller_exposed_state_by_name[collection_name], next_collection)

        if next_collection != prev_collection do
          send_external_subscribers_update(collection_name, next_collection, state)
        end

        with {:ok, state} <- reconcile_direct_dependents(collection_name, state),
             {:ok, state} <- maybe_restart_collection_item(collection_name, target, reason, state) do
          {:noreply, state}
        else
          {:stop, stop_reason, state} -> {:stop, stop_reason, state}
        end
    end
  end

  defp maybe_restart_singleton(controller_name, crash_reason, state) do
    now = System.monotonic_time(:millisecond)
    state = record_restart_attempt(controller_name, now, state)

    if restart_budget_exceeded?(controller_name, state) do
      {:stop, {:controller_restart_limit_exceeded, controller_name, crash_reason}, state}
    else
      case reconcile_controller(controller_name, state) do
        {:ok, %{source_changed?: true}, state} ->
          reconcile_direct_dependents(controller_name, state)

        {:ok, _result, state} ->
          {:ok, state}

        {:stop, reason, state} ->
          {:stop, reason, state}
      end
    end
  end

  defp maybe_restart_collection_item(collection_name, target, crash_reason, state) do
    now = System.monotonic_time(:millisecond)
    state = record_restart_attempt(target, now, state)

    if restart_budget_exceeded?(target, state) do
      {:stop, {:controller_restart_limit_exceeded, target, crash_reason}, state}
    else
      case reconcile_controller(collection_name, state) do
        {:ok, %{source_changed?: true}, state} ->
          reconcile_direct_dependents(collection_name, state)

        {:ok, _result, state} ->
          {:ok, state}

        {:stop, reason, state} ->
          {:stop, reason, state}
      end
    end
  end

  defp resolve_subscription_target(target, state) when is_atom(target) do
    case Map.get(state.controller_specs_by_name, target) do
      %ControllerSpec{variant: :collection} -> {:ok, {:collection_source, target}}
      %ControllerSpec{} -> {:ok, {:target, target}}
      nil -> :error
    end
  end

  defp resolve_subscription_target({source, _id} = target, state) when is_atom(source) do
    case Map.get(state.controller_specs_by_name, source) do
      %ControllerSpec{variant: :collection} -> {:ok, {:target, target}}
      _ -> :error
    end
  end

  defp resolve_subscription_target(_target, _state), do: :error

  defp resolve_runtime_target(target, state) when is_atom(target) do
    case Map.get(state.controller_specs_by_name, target) do
      %ControllerSpec{variant: :collection} -> {:ok, {:collection_source, target}}
      %ControllerSpec{} -> {:ok, {:target, target}}
      nil -> :error
    end
  end

  defp resolve_runtime_target({source, _id} = target, state) when is_atom(source) do
    case Map.get(state.controller_specs_by_name, source) do
      %ControllerSpec{variant: :collection} -> {:ok, {:target, target}}
      _ -> :error
    end
  end

  defp resolve_runtime_target(_target, _state), do: :error

  defp source_name_for_target(target, _state) when is_atom(target), do: target
  defp source_name_for_target({source_name, _id}, _state), do: source_name
  defp source_name_for_target(_target, _state), do: nil

  defp source_collection(source_name, state) do
    case Map.get(state.controller_exposed_state_by_name, source_name) do
      %Collection{} = collection -> collection
      _ -> Collection.empty()
    end
  end

  defp register_external_subscriber(target, subscriber, state) do
    subscribers = Map.get(state.subscribers_by_controller_name, target, MapSet.new())

    state =
      put_in(
        state.subscribers_by_controller_name[target],
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
      Map.new(state.subscribers_by_controller_name, fn {target, subscribers} ->
        {target, MapSet.delete(subscribers, subscriber)}
      end)

    %{
      state
      | subscribers_by_controller_name: subscribers_by_controller_name,
        subscriber_monitor_refs_by_pid:
          Map.delete(state.subscriber_monitor_refs_by_pid, subscriber)
    }
  end

  defp attach_external_subscribers(state, target, pid) do
    Enum.each(
      Map.get(state.subscribers_by_controller_name, target, MapSet.new()),
      fn subscriber ->
        exposed_state = subscribe_controller_safely(pid, subscriber)

        if exposed_state != :subscription_failed do
          send(subscriber, Message.update(self(), target, exposed_state))
        end
      end
    )

    state
  end

  defp send_external_subscribers_update(target, exposed_state, state) do
    Enum.each(
      Map.get(state.subscribers_by_controller_name, target, MapSet.new()),
      fn subscriber ->
        send(subscriber, Message.update(self(), target, exposed_state))
      end
    )
  end

  defp put_started_singleton(state, controller_name, pid, params, callbacks, exposed_state) do
    state
    |> put_started_target(controller_name, pid, params, callbacks, exposed_state)
    |> put_in([:controller_pids_by_name, controller_name], pid)
    |> put_in([:controller_exposed_state_by_name, controller_name], exposed_state)
    |> put_in([:controller_params_by_name, controller_name], params)
    |> put_in([:controller_status_by_name, controller_name], :started)
  end

  defp put_started_target(state, target, pid, params, callbacks, exposed_state) do
    state
    |> put_in([:controller_pids_by_target, target], pid)
    |> put_in([:controller_name_by_pid, pid], target)
    |> put_in([:controller_exposed_state_by_target, target], exposed_state)
    |> put_in([:controller_params_by_target, target], params)
    |> put_in([:controller_status_by_target, target], :started)
    |> put_in([:controller_callbacks_by_target, target], callbacks)
  end

  defp sync_target_callbacks(state, _target, pid, _desired_callbacks) when not is_pid(pid),
    do: state

  defp sync_target_callbacks(state, target, pid, desired_callbacks) do
    current_callbacks = Map.get(state.controller_callbacks_by_target, target, %{})

    if current_callbacks == desired_callbacks do
      state
    else
      Controller.update_callbacks(pid, desired_callbacks)
      put_in(state.controller_callbacks_by_target[target], desired_callbacks)
    end
  end

  defp cache_started_singleton_params(state, controller_name, params) do
    state
    |> put_in([:controller_params_by_name, controller_name], params)
    |> put_in([:controller_params_by_target, controller_name], params)
  end

  defp cache_stopped_singleton(controller_name, params, state) do
    state
    |> put_in([:controller_params_by_name, controller_name], params)
    |> put_in([:controller_status_by_name, controller_name], :stopped)
    |> put_in([:controller_exposed_state_by_name, controller_name], nil)
    |> put_in([:controller_params_by_target, controller_name], params)
    |> put_in([:controller_status_by_target, controller_name], :stopped)
    |> put_in([:controller_exposed_state_by_target, controller_name], nil)
  end

  defp mark_singleton_stopped(state, controller_name, params) do
    pid = Map.get(state.controller_pids_by_target, controller_name)

    state
    |> delete_controller_pid_mapping(pid)
    |> put_in([:controller_pids_by_name, controller_name], nil)
    |> put_in([:controller_exposed_state_by_name, controller_name], nil)
    |> put_in([:controller_params_by_name, controller_name], params)
    |> put_in([:controller_status_by_name, controller_name], :stopped)
    |> put_in([:controller_pids_by_target, controller_name], nil)
    |> put_in([:controller_exposed_state_by_target, controller_name], nil)
    |> put_in([:controller_params_by_target, controller_name], params)
    |> put_in([:controller_status_by_target, controller_name], :stopped)
    |> put_in([:controller_callbacks_by_target, controller_name], %{})
  end

  defp mark_target_stopped(state, target, params) do
    pid = Map.get(state.controller_pids_by_target, target)

    state
    |> delete_controller_pid_mapping(pid)
    |> put_in([:controller_pids_by_target, target], nil)
    |> put_in([:controller_exposed_state_by_target, target], nil)
    |> put_in([:controller_params_by_target, target], params)
    |> put_in([:controller_status_by_target, target], :stopped)
    |> put_in([:controller_callbacks_by_target, target], %{})
  end

  defp put_target_exposed_state(target, exposed_state, state) do
    put_in(state.controller_exposed_state_by_target[target], exposed_state)
  end

  defp build_collection_from_targets(controller_name, desired_ids, state) do
    Enum.reduce(desired_ids, Collection.empty(), fn id, collection ->
      case Map.get(state.controller_exposed_state_by_target, {controller_name, id}) do
        value when is_map(value) and not is_struct(value) -> Collection.put(collection, id, value)
        _ -> collection
      end
    end)
  end

  defp put_planned_stop(state, nil), do: state

  defp put_planned_stop(state, pid) do
    %{state | planned_stop_pids: MapSet.put(state.planned_stop_pids, pid)}
  end

  defp delete_controller_pid_mapping(state, nil), do: state

  defp delete_controller_pid_mapping(state, pid) do
    %{state | controller_name_by_pid: Map.delete(state.controller_name_by_pid, pid)}
  end

  defp record_restart_attempt(target, now, state) do
    timestamps =
      state.restart_timestamps_by_target
      |> Map.get(target, [])
      |> Enum.filter(&(now - &1 < @restart_window_ms))
      |> Kernel.++([now])

    state = put_in(state.restart_timestamps_by_target[target], timestamps)

    if is_atom(target) do
      put_in(state.restart_timestamps_by_name[target], timestamps)
    else
      state
    end
  end

  defp restart_budget_exceeded?(target, state) do
    length(Map.get(state.restart_timestamps_by_target, target, [])) > @max_restart_attempts
  end

  defp subscribe_controller_safely(controller_pid, subscriber) do
    Controller.subscribe(controller_pid, subscriber)
  catch
    :exit, _reason -> :subscription_failed
  end

  defp subscribe_controller_with_safely(controller_pid, subscriber, encoder) do
    Controller.subscribe_with(controller_pid, subscriber, encoder)
  catch
    :exit, _reason -> :subscription_failed
  end

  defp resolve_current_app! do
    case Process.get(:solve_app) do
      nil ->
        raise ArgumentError,
              "Solve.dispatch/2 and dispatch/3 require a current solve app in process context"

      app ->
        app
    end
  end

  defp unsubscribe_controller_safely(controller_pid, subscription_ref) do
    Controller.unsubscribe(controller_pid, subscription_ref)
  catch
    :exit, _reason -> :ok
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

  defp falsy?(value), do: value in [nil, false]
  defp truthy?(value), do: not falsy?(value)
end
