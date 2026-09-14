defmodule Solve.Runtime do
  @moduledoc false

  alias Solve.Collection
  alias Solve.Controller
  alias Solve.ControllerSpec
  alias Solve.DependencyGraph
  alias Solve.DependencyUpdate
  alias Solve.Message
  alias Solve.Update

  @restart_limit 3
  @restart_window 5_000
  @attachment_attempts 3
  @retry_delay 100

  def init(module, opts) do
    Process.flag(:trap_exit, true)
    graph = DependencyGraph.resolve_module!(module)
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    try do
      timeout = Keyword.get(opts, :controller_start_timeout, 5_000)

      unless is_integer(timeout) and timeout > 0,
        do:
          raise(
            ArgumentError,
            "controller_start_timeout must be a positive number of milliseconds"
          )

      state = build_state(graph, supervisor, Keyword.get(opts, :params, %{}), timeout)

      case reconcile_names(graph.sorted_controller_names, state) do
        {:ok, state} ->
          {:ok, state}

        {:stop, reason, state} ->
          terminate(reason, state)
          {:stop, reason}
      end
    catch
      kind, reason ->
        stop_supervisor(supervisor)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def terminate(_reason, state), do: stop_supervisor(state.supervisor)

  def handle_call({operation, target, subscriber}, _from, state)
      when operation in [:subscribe, :snapshot] and is_pid(subscriber) do
    if valid_target?(target, state) do
      state = register_subscriber(target, subscriber, state)
      {snapshot, state} = subscribe_target(target, subscriber, state)
      reply = if operation == :snapshot, do: snapshot, else: snapshot.exposed_state
      {:reply, reply, state}
    else
      {:reply, nil, state}
    end
  end

  def handle_call({:controller_pid, target}, _from, state) do
    {:reply, target_pid(target, state), state}
  end

  def handle_call({:controller_events, target}, _from, state) do
    {:reply, Map.get(state.events, source_name(target)), state}
  end

  def handle_call({:controller_variant, source}, _from, state) do
    spec = Map.get(state.controller_specs_by_name, source)
    {:reply, if(spec, do: spec.variant), state}
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :unsupported_call}, state}

  def handle_cast({:dispatch, target, event, payload}, state) do
    if pid = target_pid(target, state), do: Controller.dispatch(pid, event, payload)
    {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  def handle_info(%Message{type: :update, payload: %Update{app: app} = update}, state)
      when app == self() do
    case Map.get(state.targets, update.controller_name) do
      %{pid: pid, snapshot: current} when pid == update.pid ->
        if same_generation?(update.version, current.version) and
             Update.newer?(update.version, current.version) do
          state = put_in(state.targets[update.controller_name].snapshot, update)
          state = refresh_collection_item(update.controller_name, state)
          noreply(reconcile_dependents(source_name(update.controller_name), state))
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.get(state.target_by_monitor, ref) do
      nil ->
        if Map.get(state.subscriber_monitors, pid) == ref do
          {:noreply, remove_subscriber(pid, state)}
        else
          {:noreply, state}
        end

      target ->
        noreply(controller_down(target, reason, state))
    end
  end

  def handle_info({:EXIT, supervisor, reason}, %{supervisor: supervisor} = state) do
    {:stop, {:controller_supervisor_exit, reason}, state}
  end

  def handle_info({:retry_attachment, target, subscriber, generation, attempt}, state) do
    key = {target, subscriber}

    cond do
      Map.get(state.pending_attachments, key) != generation ->
        {:noreply, state}

      target_generation(target, state) == generation and subscribed?(target, subscriber, state) ->
        {_, state} = subscribe_target(target, subscriber, state, attempt)
        {:noreply, state}

      true ->
        {:noreply, %{state | pending_attachments: Map.delete(state.pending_attachments, key)}}
    end
  end

  def handle_info({:retry_bindings, target, generation, attempt}, state) do
    if target_generation(target, state) == generation do
      {:noreply, sync_bindings(target, state, attempt)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:prune_restart_history, state) do
    state = %{state | restart_history: recent_history(state.restart_history), restart_timer: nil}
    {:noreply, schedule_pruning(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp build_state(graph, supervisor, params, start_timeout) do
    events =
      Map.new(graph.controller_specs_by_name, fn {name, spec} ->
        Code.ensure_loaded(spec.module)

        {name,
         if(function_exported?(spec.module, :__events__, 0),
           do: spec.module.__events__(),
           else: []
         )}
      end)

    sources =
      Map.new(graph.controller_specs_by_name, fn {name, spec} ->
        snapshot = %Update{
          app: self(),
          controller_name: name,
          exposed_state: nil,
          version: {0, 0},
          events: events[name]
        }

        snapshot =
          if spec.variant == :collection,
            do: %{snapshot | kind: :collection, exposed_state: Collection.empty(), routes: %{}},
            else: snapshot

        {name, snapshot}
      end)

    Map.merge(graph, %{
      supervisor: supervisor,
      start_timeout: start_timeout,
      app_params: params,
      generation: 0,
      targets: %{},
      target_by_monitor: %{},
      sources: sources,
      events: events,
      subscribers: %{},
      subscriber_monitors: %{},
      pending_attachments: %{},
      restart_history: %{},
      restart_timer: nil
    })
  end

  defp reconcile_names(names, state) do
    Enum.reduce_while(names, {:ok, state}, fn name, {:ok, acc} ->
      case reconcile_source(name, acc) do
        {:ok, _, next} -> {:cont, {:ok, next}}
        {:stop, _, _} = stop -> {:halt, stop}
      end
    end)
  end

  defp reconcile_dependents(source, state) do
    Enum.reduce_while(Map.get(state.dependents_map, source, []), {:ok, state}, fn name,
                                                                                  {:ok, acc} ->
      name |> reconcile_changed_source(acc) |> continue_reconciling()
    end)
  end

  defp reconcile_changed_source(name, state) do
    case reconcile_source(name, state) do
      {:ok, true, next} -> reconcile_dependents(name, next)
      {:ok, false, next} -> {:ok, next}
      stop -> stop
    end
  end

  defp continue_reconciling({:ok, _} = result), do: {:cont, result}
  defp continue_reconciling(stop), do: {:halt, stop}

  defp reconcile_source(name, state) do
    spec = Map.fetch!(state.controller_specs_by_name, name)
    context = %{dependencies: dependency_values(spec, state), app_params: state.app_params}
    params = if is_function(spec.params, 1), do: spec.params.(context), else: spec.params
    previous = snapshot(name, state)

    case spec.variant do
      :singleton ->
        case reconcile_target(name, spec, params, spec.callbacks, state) do
          {:ok, state} -> {:ok, previous !== snapshot(name, state), state}
          stop -> stop
        end

      :collection ->
        with {:ok, entries} <- collected_entries(spec, params, context),
             {:ok, state} <- reconcile_items(spec, entries, state) do
          ids = Enum.map(entries, &elem(&1, 0))
          state = materialize_collection(name, ids, state)
          {:ok, previous !== snapshot(name, state), state}
        else
          {:error, reason} -> {:stop, reason, state}
          stop -> stop
        end
    end
  end

  defp reconcile_items(spec, entries, state) do
    desired = MapSet.new(entries, &elem(&1, 0))

    state =
      Enum.reduce(snapshot(spec.name, state).exposed_state.ids, state, fn id, acc ->
        if MapSet.member?(desired, id), do: acc, else: stop_target({spec.name, id}, acc)
      end)

    Enum.reduce_while(entries, {:ok, state}, fn {id, opts}, {:ok, acc} ->
      case reconcile_target(
             {spec.name, id},
             spec,
             opts.params,
             Map.merge(spec.callbacks, opts.callbacks),
             acc
           ) do
        {:ok, next} -> {:cont, {:ok, next}}
        stop -> {:halt, stop}
      end
    end)
  end

  defp reconcile_target(target, spec, params, callbacks, state) do
    current = Map.get(state.targets, target)

    cond do
      params in [nil, false] ->
        {:ok, stop_target(target, state)}

      current != nil and current.params == params ->
        if current.callbacks !== callbacks,
          do: Controller.update_callbacks(current.pid, callbacks)

        state = put_in(state.targets[target].callbacks, callbacks)
        {:ok, sync_bindings(target, state)}

      true ->
        start_target(target, spec, params, callbacks, state)
    end
  end

  defp start_target(target, spec, params, callbacks, state) do
    generation = state.generation + 1
    state = %{state | generation: generation}

    opts = [
      solve_app: self(),
      controller_name: target,
      generation: generation,
      timeout: state.start_timeout,
      params: params,
      dependencies: dependency_values(spec, state),
      dependency_versions: dependency_versions(spec, state),
      callbacks: callbacks
    ]

    child = %{
      id: target,
      start: {spec.module, :start_link, [opts]},
      restart: :temporary,
      shutdown: 1_000
    }

    case start_child(child, state) do
      {:ok, pid, initial} ->
        old = Map.get(state.targets, target)
        state = retire_target(target, state)
        monitor = Process.monitor(pid)

        record = %{
          pid: pid,
          monitor: monitor,
          snapshot: initial,
          params: params,
          callbacks: callbacks,
          bindings: %{}
        }

        state = %{
          state
          | targets: Map.put(state.targets, target, record),
            target_by_monitor: Map.put(state.target_by_monitor, monitor, target)
        }

        state =
          if is_atom(target), do: update_in(state.sources, &Map.delete(&1, target)), else: state

        if old, do: terminate_child(state.supervisor, old.pid)
        state = sync_bindings(target, state)
        state = attach_subscribers(target, state)
        {:ok, state}

      {:error, reason} ->
        case record_failure(target, reason, state) do
          {:ok, state} -> start_target(target, spec, params, callbacks, state)
          stop -> stop
        end
    end
  end

  defp start_child(child, state) do
    case DynamicSupervisor.start_child(state.supervisor, child) do
      {:ok, pid} ->
        case safe_snapshot(pid, self()) do
          {:ok, initial} ->
            {:ok, pid, initial}

          {:error, reason} ->
            terminate_child(state.supervisor, pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_controller_start, other}}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp stop_target(target, state) do
    case Map.get(state.targets, target) do
      nil ->
        state

      current ->
        state = retire_target(target, state)
        state = %{state | generation: state.generation + 1}

        stopped = %{
          current.snapshot
          | exposed_state: nil,
            pid: nil,
            version: {state.generation, 0}
        }

        state = if is_atom(target), do: put_in(state.sources[target], stopped), else: state
        notify(target, stopped, state)
        terminate_child(state.supervisor, current.pid)
        state
    end
  end

  defp retire_target(target, state) do
    case Map.pop(state.targets, target) do
      {nil, _} ->
        state

      {current, targets} ->
        Enum.each(current.bindings, fn {_, entry} -> unsubscribe_binding(entry) end)
        Process.demonitor(current.monitor, [:flush])
        pending = Map.reject(state.pending_attachments, fn {{name, _}, _} -> name === target end)

        %{
          state
          | targets: targets,
            target_by_monitor: Map.delete(state.target_by_monitor, current.monitor),
            pending_attachments: pending
        }
    end
  end

  defp controller_down(target, reason, state) do
    source = source_name(target)
    state = stop_target(target, state)
    state = refresh_collection_item(target, state)

    with {:ok, state} <- reconcile_dependents(source, state),
         {:ok, state} <- record_failure(target, reason, state),
         {:ok, _, state} <- reconcile_source(source, state) do
      reconcile_dependents(source, state)
    end
  end

  defp sync_bindings(target, state, attempt \\ 0) do
    spec = Map.fetch!(state.controller_specs_by_name, source_name(target))

    Enum.reduce(spec.dependency_bindings, state, fn binding, acc ->
      source = snapshot(binding.source, acc)

      if binding.kind == :single and source.pid != nil,
        do: sync_single_binding(target, binding, source, acc, attempt),
        else: sync_snapshot_binding(target, binding, source, acc)
    end)
  end

  defp sync_single_binding(target, binding, source, state, attempt) do
    record = Map.fetch!(state.targets, target)
    old = Map.get(record.bindings, binding.key)

    if old != nil and old.pid == source.pid do
      state
    else
      unsubscribe_binding(old)

      case safe_dependency_subscribe(source.pid, record.pid, binding.key) do
        {:ok, value, ref} ->
          send(record.pid, dependency_message(binding, value))
          put_in(state.targets[target].bindings[binding.key], %{pid: source.pid, ref: ref})

        :failed ->
          schedule_binding_retry(target, target_generation(target, state), attempt)
          update_in(state.targets[target].bindings, &Map.delete(&1, binding.key))
      end
    end
  end

  defp sync_snapshot_binding(target, binding, source, state) do
    record = Map.fetch!(state.targets, target)
    old = Map.get(record.bindings, binding.key)

    if old == nil or Map.get(old, :version) != source.version do
      unsubscribe_binding(old)
      send(record.pid, dependency_message(binding, source))
    end

    put_in(state.targets[target].bindings[binding.key], %{pid: nil, version: source.version})
  end

  defp schedule_binding_retry(_target, _generation, attempt) when attempt >= @attachment_attempts,
    do: :ok

  defp schedule_binding_retry(target, generation, attempt) do
    Process.send_after(self(), {:retry_bindings, target, generation, attempt + 1}, @retry_delay)
  end

  defp dependency_message(binding, source) do
    DependencyUpdate.replace(self(), binding.key, binding_value(binding, source), source.version)
  end

  defp dependency_values(spec, state) do
    Map.new(spec.dependency_bindings, fn binding ->
      {binding.key, binding_value(binding, snapshot(binding.source, state))}
    end)
  end

  defp dependency_versions(spec, state) do
    Map.new(spec.dependency_bindings, &{&1.key, snapshot(&1.source, state).version})
  end

  defp binding_value(%{kind: :collection, filter: filter}, source) when is_function(filter, 2) do
    source.exposed_state
    |> Enum.filter(fn {id, value} -> filter.(id, value) end)
    |> Collection.new()
  end

  defp binding_value(_binding, source), do: source.exposed_state

  defp unsubscribe_binding(%{pid: pid, ref: ref}) when is_pid(pid) do
    GenServer.call(pid, {:unsubscribe, ref}, 1_000)
  catch
    :exit, _ -> :ok
  end

  defp unsubscribe_binding(_entry), do: :ok

  defp materialize_collection(source, ids, state) do
    entries =
      Enum.flat_map(ids, fn id ->
        case Map.get(state.targets, {source, id}) do
          nil -> []
          record -> [{id, record.snapshot.exposed_state}]
        end
      end)

    value = Collection.new(entries)
    routes = Map.new(value.ids, &{&1, target_pid({source, &1}, state)})
    old = Map.fetch!(state.sources, source)

    if value !== old.exposed_state or routes !== old.routes do
      {generation, revision} = old.version
      next = %{old | exposed_state: value, routes: routes, version: {generation, revision + 1}}
      state = put_in(state.sources[source], next)
      notify(source, next, state)
      state
    else
      state
    end
  end

  defp refresh_collection_item({source, _id}, state) do
    materialize_collection(source, state.sources[source].exposed_state.ids, state)
  end

  defp refresh_collection_item(_target, state), do: state

  defp snapshot(target, state) do
    case Map.get(state.targets, target) do
      %{snapshot: value} ->
        value

      nil ->
        Map.get_lazy(state.sources, target, fn ->
          %Update{
            app: self(),
            controller_name: target,
            exposed_state: nil,
            version: {state.generation, 0},
            events: Map.get(state.events, source_name(target), [])
          }
        end)
    end
  end

  defp target_pid(target, state) do
    case Map.get(state.targets, target) do
      nil -> nil
      record -> record.pid
    end
  end

  defp target_generation(target, state) do
    case Map.get(state.targets, target) do
      %{snapshot: %{version: {generation, _}}} -> generation
      _ -> nil
    end
  end

  defp valid_target?(target, state) when is_atom(target),
    do: Map.has_key?(state.controller_specs_by_name, target)

  defp valid_target?({source, _id}, state) when is_atom(source) do
    match?(%ControllerSpec{variant: :collection}, Map.get(state.controller_specs_by_name, source))
  end

  defp valid_target?(_target, _state), do: false

  defp source_name({source, _id}), do: source
  defp source_name(source) when is_atom(source), do: source
  defp source_name(_target), do: nil

  defp same_generation?({generation, _}, {generation, _}), do: true
  defp same_generation?(_, _), do: false

  defp subscribe_target(target, subscriber, state, attempt \\ 0) do
    current = snapshot(target, state)

    if current.pid do
      finish_subscription(
        safe_snapshot(current.pid, subscriber),
        current,
        subscriber,
        state,
        attempt
      )
    else
      {current, state}
    end
  end

  defp finish_subscription({:ok, value}, current, subscriber, state, attempt) do
    if attempt > 0, do: send(subscriber, Update.message(value))
    pending = Map.delete(state.pending_attachments, {current.controller_name, subscriber})
    {value, %{state | pending_attachments: pending}}
  end

  defp finish_subscription({:error, _}, current, subscriber, state, attempt) do
    alive? = Process.alive?(current.pid)
    key = {current.controller_name, subscriber}
    state = retry_attachment(key, state, attempt, alive?)
    {if(alive?, do: current, else: %{current | exposed_state: nil, pid: nil}), state}
  end

  defp retry_attachment({target, subscriber} = key, state, attempt, alive?) do
    cond do
      not alive? or attempt >= @attachment_attempts ->
        %{state | pending_attachments: Map.delete(state.pending_attachments, key)}

      attempt == 0 and Map.has_key?(state.pending_attachments, key) ->
        state

      true ->
        generation = target_generation(target, state)

        Process.send_after(
          self(),
          {:retry_attachment, target, subscriber, generation, attempt + 1},
          @retry_delay
        )

        put_in(state.pending_attachments[key], generation)
    end
  end

  defp attach_subscribers(target, state) do
    Enum.reduce(Map.get(state.subscribers, target, MapSet.new()), state, fn subscriber, acc ->
      {value, acc} = subscribe_target(target, subscriber, acc)
      send(subscriber, Update.message(value))
      acc
    end)
  end

  defp notify(target, value, state) do
    Enum.each(Map.get(state.subscribers, target, MapSet.new()), &send(&1, Update.message(value)))
  end

  defp register_subscriber(target, subscriber, state) do
    subscribers =
      Map.update(state.subscribers, target, MapSet.new([subscriber]), &MapSet.put(&1, subscriber))

    monitors =
      Map.put_new_lazy(state.subscriber_monitors, subscriber, fn ->
        Process.monitor(subscriber)
      end)

    %{state | subscribers: subscribers, subscriber_monitors: monitors}
  end

  defp subscribed?(target, subscriber, state) do
    MapSet.member?(Map.get(state.subscribers, target, MapSet.new()), subscriber)
  end

  defp remove_subscriber(subscriber, state) do
    subscribers =
      Enum.reduce(state.subscribers, %{}, fn {target, members}, acc ->
        remaining = MapSet.delete(members, subscriber)
        if MapSet.size(remaining) == 0, do: acc, else: Map.put(acc, target, remaining)
      end)

    pending = Map.reject(state.pending_attachments, fn {{_, pid}, _} -> pid == subscriber end)

    %{
      state
      | subscribers: subscribers,
        subscriber_monitors: Map.delete(state.subscriber_monitors, subscriber),
        pending_attachments: pending
    }
  end

  defp safe_snapshot(pid, subscriber) do
    case Controller.subscribe_snapshot(pid, subscriber) do
      %Update{pid: ^pid} = value -> {:ok, value}
      other -> {:error, {:invalid_controller_snapshot, other}}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_dependency_subscribe(pid, subscriber, key) do
    Controller.subscribe_dependency(pid, subscriber, key)
  catch
    :exit, _reason -> :failed
  end

  defp record_failure(target, reason, state) do
    history = recent_history(state.restart_history)
    timestamps = [System.monotonic_time(:millisecond) | Map.get(history, target, [])]
    state = schedule_pruning(%{state | restart_history: Map.put(history, target, timestamps)})

    if length(timestamps) > @restart_limit,
      do: {:stop, {:controller_restart_limit_exceeded, target, reason}, state},
      else: {:ok, state}
  end

  defp recent_history(history) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(history, %{}, fn {target, timestamps}, acc ->
      case Enum.filter(timestamps, &(now - &1 < @restart_window)) do
        [] -> acc
        recent -> Map.put(acc, target, recent)
      end
    end)
  end

  defp schedule_pruning(%{restart_timer: nil, restart_history: history} = state)
       when map_size(history) > 0 do
    now = System.monotonic_time(:millisecond)

    expires_at =
      Enum.reduce(history, now + @restart_window, fn {_target, timestamps}, earliest ->
        min(earliest, List.last(timestamps) + @restart_window)
      end)

    delay = max(expires_at - now, 1)
    %{state | restart_timer: Process.send_after(self(), :prune_restart_history, delay)}
  end

  defp schedule_pruning(state), do: state

  defp collected_entries(_spec, params, _context) when params in [nil, false], do: {:ok, []}

  defp collected_entries(spec, _params, context) do
    normalize_entries(spec.name, spec.collect.(context))
  rescue
    error -> {:error, {:collect_failed, spec.name, error}}
  end

  defp normalize_entries(source, entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, [], MapSet.new()}, fn entry, {:ok, acc, seen} ->
      with {:ok, id, opts} <- normalize_entry(source, entry),
           :ok <- unique_id(source, id, seen) do
        {:cont, {:ok, [{id, opts} | acc], MapSet.put(seen, id)}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries, _} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp normalize_entries(source, value), do: {:error, {:invalid_collect_result, source, value}}

  defp unique_id(source, id, seen) do
    if MapSet.member?(seen, id), do: {:error, {:duplicate_collected_id, source, id}}, else: :ok
  end

  defp normalize_entry(source, {id, opts}) when is_list(opts) do
    if Keyword.keyword?(opts) do
      callbacks = Keyword.get(opts, :callbacks) || %{}

      if is_map(callbacks),
        do: {:ok, id, %{params: Keyword.get(opts, :params, true), callbacks: callbacks}},
        else: {:error, {:invalid_callbacks, source, callbacks}}
    else
      {:ok, id, %{params: opts, callbacks: %{}}}
    end
  end

  defp normalize_entry(_source, {id, params}), do: {:ok, id, %{params: params, callbacks: %{}}}
  defp normalize_entry(source, entry), do: {:error, {:invalid_collect_entry, source, entry}}

  defp terminate_child(supervisor, pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
  catch
    :exit, _ -> :ok
  end

  defp stop_supervisor(supervisor) do
    Supervisor.stop(supervisor, :shutdown, :infinity)
  catch
    :exit, _ -> :ok
  end

  defp noreply({:ok, state}), do: {:noreply, state}
  defp noreply({:stop, reason, state}), do: {:stop, reason, state}
end
