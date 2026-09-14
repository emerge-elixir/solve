defmodule Solve.Lookup do
  @moduledoc """
  Process-local facade for interacting with a Solve app.
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

  alias Solve.Update

  @type target :: Solve.controller_target()

  @callback handle_solve_updated(map(), term()) :: {:ok, term()}
  @optional_callbacks handle_solve_updated: 2

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

          def handle_info({:solve_lookup_down, _ref, :process, _pid, _reason} = message, state) do
            Solve.Lookup.handle_message(message)
            {:noreply, state}
          end

          def handle_info(%Solve.Message{} = message, state) do
            Solve.Lookup.__handle_update__(message, state, &handle_solve_updated/2)
          end
        end
      end
    end
  end

  @doc false
  def __handle_update__(message, state, callback) do
    case handle_message(message) do
      updated when map_size(updated) == 0 ->
        {:noreply, state}

      updated ->
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

    quote(do: :ok)
  end

  @spec solve(target()) :: map() | nil
  def solve(target), do: solve(nil, target)

  @spec solve(GenServer.server() | nil, target()) :: map() | nil
  def solve(app, target) do
    case read_ref(app, target) do
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
    case read_ref(app, source) do
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
  Consumes update/dispatch envelopes, or owned `:solve_lookup_down` monitor messages.

  Manual mode should forward the tagged monitor messages here as well as envelopes.
  Acquire a target with `solve/2` or `collection/2` before forwarding its updates.
  Only versioned updates carrying the canonical app PID for an existing ref are
  accepted. Unsolicited, versionless, obsolete, and retired-app updates are ignored;
  messages never create subscriptions or seed the cache. Forward the complete runtime
  envelope rather than rebuilding an update from its value.
  """
  @spec handle_message(
          Solve.Message.t()
          | {:solve_lookup_down, reference(), :process, pid(), term()}
        ) :: map()
  def handle_message({@down_tag, ref, :process, pid, _reason}) do
    case Map.get(cache().apps, pid) do
      %{monitor: ^ref} -> forget_app(pid)
      _ -> :ok
    end

    %{}
  end

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
        if alive?(app) do
          accept_update(update, ref)
        else
          forget_app(app)
          %{}
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

      %{update.app => updated}
    else
      %{}
    end
  end

  @doc "Drops cached refs and monitors for retired local app instances. No live subscriptions are removed."
  @spec cleanup() :: :ok
  def cleanup do
    Enum.each(cache().apps, fn {pid, _} -> if not alive?(pid), do: forget_app(pid) end)
    cache = cache()
    aliases = Map.filter(cache.aliases, fn {_, pid} -> Map.has_key?(cache.apps, pid) end)
    Process.put(@cache_key, %{cache | aliases: aliases})
    :ok
  end

  defp read_ref(app, target) do
    app = context_app!(app)
    previous = Map.get(cache().aliases, app)
    if previous != nil and not alive?(previous), do: forget_app(previous)
    pid = resolve_app!(app)
    ref = ensure_ref(pid, target)

    if ref != nil and not is_pid(app) do
      cache = cache()
      Process.put(@cache_key, %{cache | aliases: Map.put(cache.aliases, app, pid)})
    end

    ref
  end

  defp ensure_ref(app, target) do
    case lookup_ref(app, target) do
      nil ->
        case Solve.subscribe_snapshot(app, target) do
          nil -> nil
          update -> put_ref(update)
        end

      ref ->
        ref
    end
  end

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

  defp resolve_app!(nil), do: resolve_app!(context_app!(nil))

  defp resolve_app!(app) when is_pid(app) do
    if alive?(app) do
      app
    else
      forget_app(app)
      exit({:noproc, {__MODULE__, :resolve_app, [app]}})
    end
  end

  defp resolve_app!(app) do
    pid = resolve_named_app(app)

    if is_pid(pid) do
      pid
    else
      exit({:noproc, {__MODULE__, :resolve_app, [app]}})
    end
  end

  defp resolve_named_app({name, remote_node}) when is_atom(name) and is_atom(remote_node) do
    case :rpc.call(remote_node, Process, :whereis, [name]) do
      pid when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp resolve_named_app(app), do: GenServer.whereis(app)

  defp alive?(pid) when node(pid) == node(), do: Process.alive?(pid)

  defp alive?(pid) do
    case :rpc.call(node(pid), Process, :alive?, [pid]) do
      true -> true
      _ -> false
    end
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
