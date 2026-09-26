defmodule Solve.Lookup do
  @moduledoc """
  Process-local, monitor-backed subscriptions to a Solve app.

  Warm remote reads use the caller's cache without liveness or name-resolution
  RPCs. An owned app DOWN invalidates values and event routes but retains desired
  subscriptions. A lazy watcher restores them with capped exponential backoff.
  No controller state or actions are forwarded through the watcher.

  Configure `:lookup_timeout` (default 5,000 ms) and `:lookup_recovery`
  (`initial_delay: 250, max_delay: 30_000, jitter: 0.2`) under application `:solve`.
  The delay cap is not an attempt limit. Healthy apps are not polled.

  `status/1` reports observed availability. Initial cold acquisition can exit;
  reads while reconnecting exit immediately without additional network work.
  Recovery invokes the ordinary data callback after fresh refs are installed.
  The optional `handle_solve_connection_changed/3` callback allows offline UI and
  input gating without attempting to render unavailable data.

  Distribution startup, credentials, command admission and protection against
  delayed transport delivery remain application responsibilities.
  """

  defmodule Ref do
    @moduledoc false

    @enforce_keys [:app, :controller_name, :kind]
    defstruct [:app, :controller_name, :kind, :value, :version]
  end

  defmodule Updated do
    @moduledoc false

    @enforce_keys [:refs, :collections]
    defstruct refs: [], collections: []

    @type t :: %__MODULE__{refs: [Solve.controller_target()], collections: [atom()]}
  end

  @events_key :events_
  @cache_key {__MODULE__, :cache}
  @down_tag :solve_lookup_down

  alias Solve.Lookup.Recovery
  alias Solve.Lookup.Transport
  alias Solve.Lookup.Watcher
  alias Solve.Update

  @type target :: Solve.controller_target()

  @callback handle_solve_updated(map(), term()) :: {:ok, term()}
  @type connection_status ::
          :unknown | {:connected, pid()} | {:reconnecting, term()} | {:unavailable, term()}

  @callback handle_solve_connection_changed(GenServer.server(), connection_status(), term()) ::
              {:ok, term()}
  @optional_callbacks handle_solve_updated: 2, handle_solve_connection_changed: 3

  defmacro __using__(opts \\ []) do
    %{imports: imports, mode: mode, handle_info_mode: handle_info_mode} =
      validate_options!(opts, __CALLER__)

    quote do
      import Solve.Lookup, only: unquote(imports)

      if unquote(mode) != :helpers do
        @behaviour Solve.Lookup
        @before_compile Solve.Lookup
        @solve_lookup_handle_info_mode unquote(handle_info_mode)

        if unquote(handle_info_mode) == :auto do
          def handle_info(nil, state) do
            {:noreply, state}
          end

          def handle_info({tag, _ref, :process, _pid, _reason} = message, state)
              when tag in [:solve_lookup_down, :solve_lookup_watcher_down] do
            Solve.Lookup.__handle_update__(
              message,
              state,
              &handle_solve_updated/2,
              &handle_solve_connection_changed/3
            )
          end

          def handle_info({:solve_lookup, _kind, _payload} = message, state) do
            Solve.Lookup.__handle_update__(
              message,
              state,
              &handle_solve_updated/2,
              &handle_solve_connection_changed/3
            )
          end

          def handle_info(%Solve.Message{} = message, state) do
            Solve.Lookup.__handle_update__(
              message,
              state,
              &handle_solve_updated/2,
              &handle_solve_connection_changed/3
            )
          end
        end
      end
    end
  end

  @doc false
  def __handle_update__(
        message,
        state,
        callback,
        connection_callback \\ fn _, _, state -> {:ok, state} end
      ) do
    pending = Recovery.take_notifications()
    updated = handle_message(message)
    changes = Map.new(pending ++ Recovery.take_notifications())

    state =
      Enum.reduce(changes, state, fn {app, status}, acc ->
        {:ok, next} = connection_callback.(app, status, acc)
        next
      end)

    if map_size(updated) == 0 do
      {:noreply, state}
    else
      {:ok, next} = callback.(updated, state)
      {:noreply, next}
    end
  end

  defmacro __before_compile__(env) do
    handle_info_mode = Module.get_attribute(env.module, :solve_lookup_handle_info_mode)
    definitions = MapSet.new(Module.definitions_in(env.module))

    if handle_info_mode == :auto and not MapSet.member?(definitions, {:handle_solve_updated, 2}) do
      raise CompileError,
        file: env.file,
        line: 1,
        description:
          "#{inspect(env.module)} must define handle_solve_updated/2 when using Solve.Lookup in :auto mode"
    end

    if handle_info_mode == :auto and
         not MapSet.member?(definitions, {:handle_solve_connection_changed, 3}) do
      quote do
        @impl Solve.Lookup
        def handle_solve_connection_changed(_app, _status, state), do: {:ok, state}
      end
    else
      quote(do: :ok)
    end
  end

  @spec solve(target()) :: map() | nil
  def solve(target), do: solve(nil, target)

  @spec solve(GenServer.server() | nil, target()) :: map() | nil
  def solve(app, target) do
    case read_ref(app, target, :item) do
      nil ->
        nil

      %Ref{kind: :item, value: value} ->
        value

      %Ref{kind: :collection} ->
        raise ArgumentError,
              "Solve.Lookup.solve/2 does not support collection source #{inspect(target)}; use collection/2"
    end
  end

  @spec collection(atom()) :: Solve.Collection.t(map())
  def collection(source) when is_atom(source), do: collection(nil, source)

  @spec collection(GenServer.server() | nil, atom()) :: Solve.Collection.t(map())
  def collection(app, source) when is_atom(source) do
    case read_ref(app, source, :collection) do
      %Ref{kind: :collection, value: value} ->
        value

      %Ref{} ->
        raise ArgumentError,
              "Solve.Lookup.collection/2 requires a collection source, got singleton #{inspect(source)}"

      nil ->
        raise ArgumentError,
              "Solve.Lookup.collection/2 could not resolve collection source #{inspect(source)}"
    end
  end

  @doc """
  Releases a lookup interest using the calling process's `:solve_app` context.

  See `unsubscribe/2` for ownership and partial-failure semantics.
  """
  @spec unsubscribe(target()) :: :ok | {:error, term()}
  def unsubscribe(target), do: unsubscribe(nil, target)

  @doc """
  Releases the calling process's cached interest in a target and requests raw detachment.

  Use an app PID or a name previously used to acquire a lookup. Names identify their
  cached app instance: this function never resolves a name to discover a replacement
  app. Pending recovery intent is canceled even when no active ref remains. An
  unknown alias or missing interest returns `:ok` without an app call. Passing
  `nil` uses the calling process's `:solve_app` context.

  Removes only this target. Collection sources and individual items are independent;
  repeated reads and aliases share one interest, not reference counts. The last ref
  for an app also releases its lookup monitor and aliases. Queued updates cannot
  recreate a removed ref; a later `solve/2` or `collection/2` explicitly reacquires it.
  No update callback is invoked and previously returned event tuples remain usable.
  Cancellation also removes equivalent recovery intent and fences queued retries;
  releasing the last pending interest stops its watcher. Raw `Solve.unsubscribe`
  alone does not cancel Lookup intent. Partial recovery refs use the same pinned
  raw-detachment semantics as active refs.

  A raw reentrancy error preserves the cache unchanged. Other raw errors remove the
  ref but leave physical detachment unconfirmed. Outer app-call exits also remove the
  ref before propagating; confirmed app death is treated as successful cleanup.

  `:ok` for a missing ref certifies only a local no-op, not physical detachment. After
  a timeout, another lookup unsubscribe does not retry the raw operation. Use
  `Solve.unsubscribe/2` with the original app PID if confirmation is needed, or to
  release raw subscriptions that have no lookup ref (including failed acquisitions).
  """
  @spec unsubscribe(GenServer.server() | nil, target()) :: :ok | {:error, term()}
  def unsubscribe(app, target) do
    app = context_app!(app)
    pid = if is_pid(app), do: app, else: Map.get(cache().aliases, app)

    binding = Recovery.get_binding(app)
    pid = pid || (binding && binding.pid)

    if lookup_ref(pid, target) do
      unsubscribe_ref(pid, target)
    else
      Recovery.cancel(app, pid, target)
      :ok
    end
  end

  defp unsubscribe_ref(app, target) do
    if locally_dead?(app) do
      Recovery.cancel(app, app, target)
      retire_app(app, :noproc)
      :ok
    else
      case Solve.unsubscribe(app, target, self()) do
        {:error, :reentrant_unsubscribe} = error ->
          error

        result ->
          Recovery.cancel(app, app, target)
          forget_ref(app, target)
          result
      end
    end
  catch
    :exit, reason ->
      Recovery.cancel(app, app, target)

      if app_gone?(app, reason) do
        retire_app(app, :noproc)
        :ok
      else
        forget_ref(app, target)
        :erlang.raise(:exit, reason, __STACKTRACE__)
      end
  end

  defp app_gone?(app, {:noproc, {GenServer, :call, [app, _request, _timeout]}}), do: true
  defp app_gone?(app, _reason), do: locally_dead?(app)
  defp locally_dead?(pid), do: node(pid) == node() and not Process.alive?(pid)

  @type dispatch_event ::
          {pid(), {:solve_event, atom()}} | {pid(), {:solve_event, atom(), term()}}

  @spec dispatch(dispatch_event()) :: :ok
  def dispatch({pid, {:solve_event, _} = message}) when is_pid(pid) do
    send(pid, message)
    :ok
  end

  def dispatch({pid, {:solve_event, _, _} = message}) when is_pid(pid) do
    send(pid, message)
    :ok
  end

  @spec dispatch(target() | dispatch_event(), term()) :: :ok
  def dispatch({pid, {:solve_event, event}}, payload) when is_pid(pid),
    do: dispatch({pid, {:solve_event, event, payload}})

  def dispatch(target, event), do: dispatch(nil, target, event, %{})

  @spec dispatch(target(), atom(), term()) :: :ok
  def dispatch(target, event, payload), do: dispatch(nil, target, event, payload)

  @spec dispatch(GenServer.server() | nil, target(), atom(), term()) :: :ok
  def dispatch(app, target, event, payload) when is_atom(event) do
    Solve.dispatch(resolve_app!(app), target, event, payload)
  end

  @doc "Reads an instance-bound direct event tuple from a lookup item."
  @spec event(map() | nil, atom()) :: dispatch_event() | nil
  def event(controller, event_name) when is_atom(event_name) do
    case events(controller) do
      nil -> nil
      events -> Map.get(events, event_name)
    end
  end

  @spec event(map() | nil, atom(), term()) :: dispatch_event() | nil
  def event(controller, event_name, payload) when is_atom(event_name) do
    case event(controller, event_name) do
      {pid, {:solve_event, ^event_name}} -> {pid, {:solve_event, event_name, payload}}
      _ -> nil
    end
  end

  @spec events(map() | nil) :: map() | nil
  def events(nil), do: nil
  def events(%Solve.Collection{}), do: nil
  def events(%{@events_key => events}), do: events
  def events(_value), do: nil

  @doc """
  Consumes update/dispatch envelopes and owned lifecycle/recovery messages.

  Manual/helpers consumers must forward `%Solve.Message{}`, both tagged DOWN forms
  (`:solve_lookup_down`, `:solve_lookup_watcher_down`), and
  `{:solve_lookup, kind, payload}` messages. Foreign monitor refs are ignored.
  Successful recovery returns the same grouped `Updated` data as normal updates.
  Use `status/1` to inspect availability in a manually wired consumer.
  Acquire a target with `solve/2` or `collection/2` before forwarding its updates.
  Only versioned updates carrying the canonical app PID for an existing ref are
  accepted. Unsolicited, versionless, obsolete, and retired-app updates are ignored;
  messages never create subscriptions or seed the cache. Forward the complete runtime
  envelope rather than rebuilding an update from its value.
  """
  @spec handle_message(
          Solve.Message.t()
          | {:solve_lookup_down | :solve_lookup_watcher_down, reference(), :process, pid(),
             term()}
          | {:solve_lookup, atom(), term()}
        ) :: map()
  def handle_message({@down_tag, ref, :process, pid, reason}) do
    case Map.get(cache().apps, pid) do
      %{monitor: ^ref} -> retire_app(pid, reason)
      _ -> :ok
    end

    %{}
  end

  def handle_message({:solve_lookup_watcher_down, ref, :process, pid, _reason}) do
    Recovery.watcher_down(ref, pid)
    %{}
  end

  def handle_message({:solve_lookup, :recover, {watcher, app, token, pid}})
      when is_pid(watcher) and is_reference(token) and is_pid(pid) do
    case Recovery.candidate(watcher, app, token, pid) do
      nil -> %{}
      binding -> restore(app, pid, binding)
    end
  end

  def handle_message({:solve_lookup, :failed, {watcher, app, token, failure, delay}}) do
    case Recovery.failed(watcher, app, token, failure, delay) do
      {:retire, pid, reason} -> retire_app(pid, reason)
      _ -> :ok
    end

    %{}
  end

  def handle_message({:solve_lookup, :restart, token}) do
    Recovery.restart(token)
    %{}
  end

  def handle_message({:solve_lookup, :notify, nil}) do
    Recovery.take_notifications()
    %{}
  end

  def handle_message({:solve_lookup, _kind, _payload}), do: %{}

  def handle_message(%Solve.Message{type: :dispatch, payload: %Solve.Dispatch{} = dispatch}) do
    Solve.dispatch(
      resolve_app!(dispatch.app),
      dispatch.controller_name,
      dispatch.event,
      dispatch.payload
    )

    %{}
  end

  def handle_message(%Solve.Message{
        type: :update,
        payload: %Update{app: app, version: {generation, revision}} = update
      })
      when is_pid(app) and is_integer(generation) and generation >= 0 and
             is_integer(revision) and revision >= 0 do
    case lookup_ref(app, update.controller_name) do
      nil ->
        %{}

      ref ->
        if locally_dead?(app) do
          retire_app(app, :noproc)
          %{}
        else
          accept_update(update, ref)
        end
    end
  end

  def handle_message(%Solve.Message{type: :update, payload: %Update{}}), do: %{}

  defp accept_update(update, current) do
    if current.kind == update.kind and Update.newer?(update.version, current.version) do
      ref = %{current | value: augment_value(update), version: update.version}
      Process.put(@cache_key, put_in(cache(), [:apps, ref.app, :refs, ref.controller_name], ref))

      updated =
        case ref.kind do
          :collection -> %Updated{refs: [], collections: [ref.controller_name]}
          :item -> %Updated{refs: [ref.controller_name], collections: []}
        end

      if Recovery.visible?(update.app, ref.controller_name),
        do: %{update.app => updated},
        else: %{}
    else
      %{}
    end
  end

  @doc "Drops cached refs and monitors for retired local app instances. No live subscriptions are removed."
  @spec cleanup() :: :ok
  def cleanup do
    Enum.each(cache().apps, fn {pid, _} -> if locally_dead?(pid), do: retire_app(pid, :noproc) end)

    cache = cache()
    aliases = Map.filter(cache.aliases, fn {_, pid} -> Map.has_key?(cache.apps, pid) end)
    Process.put(@cache_key, %{cache | aliases: aliases})
    :ok
  end

  @doc """
  Reports the calling process's observed connection state, without resolving names,
  polling processes, or performing network work. `nil` uses the current app context.

  `{:connected, pid}` means this address's wanted set is installed and no failure has
  been consumed. It is not an instantaneous health check: a silent network stall
  can precede Erlang's failure detection. `:unknown` means no retained interest through that address.
  Named apps automatically reconnect; a confirmed dead explicit PID is unavailable
  and cannot follow a replacement. Unsubscribe to cancel or deliberately reacquire.
  """
  @spec status(GenServer.server() | nil) ::
          :unknown | {:connected, pid()} | {:reconnecting, term()} | {:unavailable, term()}
  def status(app), do: Recovery.status(context_app!(app))

  defp read_ref(app, target, kind) do
    app = context_app!(app)
    Recovery.request(app, target, kind)

    case cached_ref(app, target, kind) do
      nil ->
        acquire(app, target, kind)

      ref ->
        record_binding(app, ref, Recovery.config_for(ref.app))
        ref
    end
  end

  defp cached_pid(app) do
    cond do
      is_pid(app) -> app
      Transport.remote_name?(app) -> cache().aliases[app]
      not Map.has_key?(cache().aliases, app) -> nil
      true -> GenServer.whereis(app)
    end
  end

  defp cached_ref(app, target, kind) do
    pid = cached_pid(app)

    cond do
      pid == nil ->
        nil

      locally_dead?(pid) ->
        retire_app(pid, :noproc)
        Recovery.pending!(app)
        nil

      lookup_ref(pid, target) != nil and not Recovery.visible?(pid, target) ->
        pending_read(app, pid, target, kind)

      true ->
        lookup_ref(pid, target)
    end
  end

  defp pending_read(app, pid, target, kind) do
    config = Recovery.config_for(pid)
    Recovery.failed_acquisition(app, pid, target, kind, {:recovering, pid}, config)
    Recovery.pending!(app)
  end

  defp acquire(app, target, kind) do
    config = Watcher.config!()
    deadline = Transport.deadline(config.timeout)
    pid = acquire_pid(app, target, kind, config, deadline)

    if lookup_ref(pid, target) != nil and not Recovery.visible?(pid, target),
      do: pending_read(app, pid, target, kind)

    try do
      case lookup_ref(pid, target) || restore_ref(pid, target, deadline) do
        nil ->
          nil

        ref ->
          record_binding(app, ref, config)
          ref
      end
    catch
      :exit, reason ->
        Recovery.failed_acquisition(app, pid, target, kind, reason, config)
        :erlang.raise(:exit, reason, __STACKTRACE__)
    end
  end

  defp acquire_pid(app, target, kind, config, deadline) do
    Transport.resolve!(app, deadline)
  catch
    :exit, reason ->
      Recovery.failed_acquisition(app, nil, target, kind, reason, config)
      :erlang.raise(:exit, reason, __STACKTRACE__)
  end

  defp record_binding(app, ref, config) do
    Recovery.remember(app, ref.app, ref.controller_name, ref.kind, config)

    if not is_pid(app) do
      Process.put(@cache_key, %{cache() | aliases: Map.put(cache().aliases, app, ref.app)})
    end
  end

  defp restore(app, pid, binding) do
    deadline = Transport.deadline(binding.config.timeout)

    Enum.each(binding.targets, fn {target, kind} ->
      ref = lookup_ref(pid, target) || restore_ref(pid, target, deadline)
      if ref == nil, do: throw({:unknown_target, target})
      if ref.kind != kind, do: throw({:changed_kind, target})
    end)

    if not is_pid(app) do
      Process.put(@cache_key, %{cache() | aliases: Map.put(cache().aliases, app, pid)})
    end

    Recovery.complete(app)
    restored_updates(pid, binding.targets)
  rescue
    error ->
      Recovery.terminal(app, {:invalid_snapshot, Exception.message(error)})
      %{}
  catch
    :exit, reason ->
      if disconnected_call?(reason) do
        retire_app(pid, disconnect_reason(reason))
      else
        Recovery.retry(app, reason)
      end

      %{}

    :throw, reason ->
      Recovery.terminal(app, reason)
      %{}
  end

  defp restore_ref(pid, target, deadline) do
    case Solve.subscribe_snapshot(pid, target, self(), Transport.remaining!(deadline)) do
      nil -> nil
      update -> put_ref(update)
    end
  end

  defp restored_updates(pid, targets) do
    refs = Map.take(cache().apps[pid].refs, Map.keys(targets))

    updated =
      Enum.reduce(refs, %Updated{refs: [], collections: []}, fn
        {target, %{kind: :item}}, acc -> %{acc | refs: [target | acc.refs]}
        {target, %{kind: :collection}}, acc -> %{acc | collections: [target | acc.collections]}
      end)

    %{pid => updated}
  end

  defp disconnected_call?({:noproc, _}), do: true
  defp disconnected_call?({{:nodedown, _}, _}), do: true
  defp disconnected_call?(_), do: false
  defp disconnect_reason({:noproc, _}), do: :noproc
  defp disconnect_reason(_), do: :noconnection

  defp put_ref(update) do
    value = augment_value(update)

    ref = %Ref{
      app: update.app,
      controller_name: update.controller_name,
      kind: update.kind,
      version: update.version,
      value: value
    }

    cache = cache()

    app_cache =
      Map.get_lazy(cache.apps, update.app, fn ->
        %{refs: %{}, monitor: Process.monitor(update.app, tag: @down_tag)}
      end)

    app_cache = %{app_cache | refs: Map.put(app_cache.refs, update.controller_name, ref)}
    Process.put(@cache_key, %{cache | apps: Map.put(cache.apps, update.app, app_cache)})
    ref
  end

  defp augment_value(
         %Update{kind: :collection, exposed_state: %Solve.Collection{} = collection} = update
       ) do
    items =
      Map.new(collection.items, fn {id, item} ->
        pid = Map.get(update.routes || %{}, id)
        {id, Map.put(validate_item!(item), @events_key, direct_events(pid, update.events))}
      end)

    %{collection | items: items}
  end

  defp augment_value(%Update{exposed_state: nil}), do: nil

  defp augment_value(%Update{exposed_state: value} = update) do
    Map.put(validate_item!(value), @events_key, direct_events(update.pid, update.events))
  end

  defp direct_events(pid, events) when is_pid(pid) do
    Map.new(events || [], &{&1, {pid, {:solve_event, &1}}})
  end

  defp direct_events(_pid, _events), do: %{}

  defp validate_item!(value) when is_map(value) and not is_struct(value) do
    if Map.has_key?(value, @events_key),
      do:
        raise(
          ArgumentError,
          "Solve.Lookup reserves #{inspect(@events_key)} in exposed controller maps"
        ),
      else: value
  end

  defp validate_item!(value) do
    raise ArgumentError,
          "Solve.Lookup expects exposed controller values to be plain maps, got: #{inspect(value)}"
  end

  defp lookup_ref(app, target), do: get_in(cache(), [:apps, app, :refs, target])
  defp cache, do: Process.get(@cache_key, %{apps: %{}, aliases: %{}})

  defp forget_ref(app, target) do
    refs = Map.delete(cache().apps[app].refs, target)

    if map_size(refs) == 0 do
      forget_app(app)
    else
      Process.put(@cache_key, put_in(cache(), [:apps, app, :refs], refs))
    end
  end

  defp forget_app(pid) do
    cache = cache()

    case Map.get(cache.apps, pid) do
      nil -> :ok
      %{monitor: ref} -> Process.demonitor(ref, [:flush])
    end

    aliases = Map.reject(cache.aliases, fn {_, value} -> value == pid end)
    Process.put(@cache_key, %{cache | apps: Map.delete(cache.apps, pid), aliases: aliases})
  end

  defp context_app!(nil) do
    case Process.get(:solve_app) do
      nil ->
        raise ArgumentError, "Solve.Lookup could not resolve a solve app for the current process"

      app ->
        app
    end
  end

  defp context_app!(app), do: app

  defp resolve_app!(app) do
    app = context_app!(app)

    cond do
      not is_pid(app) ->
        Transport.resolve!(app, Transport.deadline(Transport.timeout!()))

      locally_dead?(app) ->
        retire_app(app, :noproc)
        exit({:noproc, {__MODULE__, :resolve_app, [app]}})

      true ->
        app
    end
  end

  defp retire_app(pid, reason) do
    forget_app(pid)
    Recovery.invalidate(pid, reason)
  end

  defp validate_options!(:helpers, _caller) do
    %{imports: helper_imports(), mode: :helpers, handle_info_mode: nil}
  end

  defp validate_options!(opts, caller) when is_list(opts) do
    handle_info_mode =
      validate_handle_info_option!(Keyword.get(opts, :handle_info, :auto), caller)

    %{imports: default_imports(), mode: handle_info_mode, handle_info_mode: handle_info_mode}
  end

  defp validate_options!(opts, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "use Solve.Lookup expects :helpers or a keyword list, got: #{inspect(opts)}"
  end

  defp default_imports do
    [
      solve: 1,
      solve: 2,
      collection: 1,
      collection: 2,
      event: 2,
      event: 3,
      dispatch: 1,
      dispatch: 2,
      dispatch: 3,
      dispatch: 4,
      events: 1,
      handle_message: 1
    ]
  end

  defp helper_imports do
    [
      solve: 1,
      solve: 2,
      collection: 1,
      collection: 2,
      event: 2,
      event: 3,
      events: 1
    ]
  end

  defp validate_handle_info_option!(:auto, _caller), do: :auto
  defp validate_handle_info_option!(:manual, _caller), do: :manual

  defp validate_handle_info_option!(value, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "Solve.Lookup handle_info option must be :auto or :manual, got: #{inspect(value)}"
  end
end
