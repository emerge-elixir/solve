defmodule Solve.Lookup do
  @moduledoc """
  Process-local facade for interacting with a Solve app.
  """

  defmodule Ref do
    @moduledoc false

    @enforce_keys [:app, :controller_name, :kind, :events, :subscribed?]
    defstruct [:app, :controller_name, :kind, :value, :events, :subscribed?]
  end

  defmodule Updated do
    @moduledoc false

    @enforce_keys [:refs, :collections]
    defstruct refs: [], collections: []
  end

  @events_key :events_

  @type target :: Solve.controller_target()
  @type updated_controllers :: %{optional(GenServer.server()) => Updated.t()}

  @callback handle_solve_updated(updated_controllers(), term()) :: {:ok, term()}
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

          def handle_info(%Solve.Message{} = message, state) do
            updated = handle_message(message)

            if map_size(updated) == 0 do
              {:noreply, state}
            else
              {:ok, state} = handle_solve_updated(updated, state)
              {:noreply, state}
            end
          end
        end
      end
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
  def solve(controller_name) do
    solve(nil, controller_name)
  end

  @spec solve(GenServer.server() | nil, target()) :: map() | nil
  def solve(app, controller_name) do
    app = resolve_app!(app)

    case lookup_kind(app, controller_name) do
      :item ->
        app
        |> ensure_lookup_ref(controller_name, :item)
        |> augment_lookup_value()

      :collection ->
        raise ArgumentError,
              "Solve.Lookup.solve/2 does not support collection source #{inspect(controller_name)}; use collection/2"

      :unknown ->
        nil
    end
  end

  @spec collection(atom()) :: Solve.Collection.t(map())
  def collection(controller_name) when is_atom(controller_name) do
    collection(nil, controller_name)
  end

  @spec collection(GenServer.server() | nil, atom()) :: Solve.Collection.t(map())
  def collection(app, controller_name) when is_atom(controller_name) do
    app = resolve_app!(app)

    case lookup_kind(app, controller_name) do
      :collection ->
        app
        |> ensure_lookup_ref(controller_name, :collection)
        |> augment_lookup_value()

      :item ->
        raise ArgumentError,
              "Solve.Lookup.collection/2 requires a collection source, got singleton #{inspect(controller_name)}"

      :unknown ->
        raise ArgumentError,
              "Solve.Lookup.collection/2 could not resolve collection source #{inspect(controller_name)}"
    end
  end

  @spec dispatch(target(), atom()) :: :ok
  def dispatch(controller_name, event) do
    dispatch(nil, controller_name, event, %{})
  end

  @spec dispatch(target(), atom(), term()) :: :ok
  def dispatch(controller_name, event, payload) do
    dispatch(nil, controller_name, event, payload)
  end

  @spec dispatch(GenServer.server() | nil, target(), atom(), term()) :: :ok
  def dispatch(app, controller_name, event, payload) when is_atom(event) do
    app
    |> resolve_app!()
    |> Solve.dispatch(controller_name, event, payload)
  end

  @doc """
  Reads one direct `{pid, message}` event tuple from a lookup item.

  This is a convenience wrapper over `events(controller)[event_name]`.
  """
  @spec event(map() | nil | Solve.Collection.t(any()), atom()) :: {pid(), term()} | nil
  def event(controller, event_name) when is_atom(event_name) do
    case events(controller) do
      nil -> nil
      events -> Map.get(events, event_name)
    end
  end

  @doc """
  Builds a direct `{pid, message}` event tuple with a fixed payload for a lookup item.
  """
  @spec event(map() | nil | Solve.Collection.t(any()), atom(), term()) :: {pid(), term()} | nil
  def event(controller, event_name, payload) when is_atom(event_name) do
    case event(controller, event_name) do
      {pid, {:solve_event, ^event_name}} -> {pid, {:solve_event, event_name, payload}}
      _ -> nil
    end
  end

  @spec events(map() | nil | Solve.Collection.t(any())) :: map() | nil
  def events(nil), do: nil
  def events(%Solve.Collection{}), do: nil
  def events(%{@events_key => events}), do: events
  def events(_value), do: nil

  @spec handle_message(Solve.Message.t()) :: updated_controllers()
  def handle_message(%Solve.Message{type: :dispatch, payload: %Solve.Dispatch{} = dispatch}) do
    app = resolve_app!(dispatch.app)
    Solve.dispatch(app, dispatch.controller_name, dispatch.event, dispatch.payload)
    %{}
  end

  def handle_message(%Solve.Message{
        type: :update,
        payload: %Solve.Update{
          app: app,
          controller_name: controller_name,
          exposed_state: exposed_value
        }
      }) do
    app = resolve_app!(app)

    kind =
      cond do
        match?(%Solve.Collection{}, exposed_value) -> :collection
        true -> :item
      end

    ref = lookup_ref(app, controller_name) || build_lookup_ref(app, controller_name, kind, nil)

    put_lookup_ref(%{
      ref
      | kind: kind,
        value: validate_lookup_value!(exposed_value),
        events: build_events_for_kind(app, controller_name, kind),
        subscribed?: true
    })

    updated =
      case kind do
        :collection -> %Updated{refs: [], collections: [controller_name]}
        :item -> %Updated{refs: [controller_name], collections: []}
      end

    %{app => updated}
  end

  defp ensure_lookup_ref(app, controller_name, kind) do
    case lookup_ref(app, controller_name) do
      %Ref{kind: ^kind} = ref ->
        ref

      %Ref{} = ref when kind == :collection ->
        ref

      %Ref{} = ref when kind == :item ->
        ref

      nil ->
        ref =
          build_lookup_ref(
            app,
            controller_name,
            kind,
            Solve.subscribe(app, controller_name, self())
          )

        put_lookup_ref(ref)
        ref
    end
  end

  defp augment_lookup_value(%Ref{kind: :item, value: nil}), do: nil

  defp augment_lookup_value(%Ref{kind: :item, value: value, events: events}) do
    Map.put(value, @events_key, events)
  end

  defp augment_lookup_value(%Ref{
         kind: :collection,
         app: app,
         controller_name: controller_name,
         value: value
       }) do
    augment_collection_value(app, controller_name, value)
  end

  defp build_lookup_ref(app, controller_name, kind, value) do
    %Ref{
      app: app,
      controller_name: controller_name,
      kind: kind,
      value: validate_lookup_value!(value),
      events: build_events_for_kind(app, controller_name, kind),
      subscribed?: true
    }
  end

  defp build_events_for_kind(_app, _controller_name, :collection), do: nil

  defp build_events_for_kind(app, controller_name, :item),
    do: build_direct_events(app, controller_name)

  defp build_direct_events(app, controller_name) do
    case Solve.controller_pid(app, controller_name) do
      pid when is_pid(pid) ->
        app
        |> Solve.controller_events(controller_name)
        |> Kernel.||([])
        |> Map.new(fn event -> {event, {pid, {:solve_event, event}}} end)

      _ ->
        %{}
    end
  end

  defp augment_collection_value(_app, _controller_name, nil) do
    Solve.Collection.empty()
  end

  defp augment_collection_value(app, controller_name, %Solve.Collection{} = collection) do
    items =
      Map.new(collection.items, fn {id, value} ->
        {id, Map.put(value, @events_key, build_direct_events(app, {controller_name, id}))}
      end)

    %Solve.Collection{collection | items: items}
  end

  defp validate_lookup_value!(nil), do: nil

  defp validate_lookup_value!(value) when is_map(value) and not is_struct(value) do
    validate_lookup_item!(value)
  end

  defp validate_lookup_value!(%Solve.Collection{} = collection) do
    items = Map.new(collection.items, fn {id, item} -> {id, validate_lookup_item!(item)} end)
    %Solve.Collection{collection | items: items}
  end

  defp validate_lookup_value!(value) do
    raise ArgumentError,
          "Solve.Lookup expects exposed controller values to be plain maps, Solve.Collection structs, or nil, got: #{inspect(value)}"
  end

  defp validate_lookup_item!(value) do
    if Map.has_key?(value, @events_key) do
      raise ArgumentError,
            "Solve.Lookup reserves #{inspect(@events_key)} in exposed controller maps"
    else
      value
    end
  end

  defp lookup_ref(app, controller_name) do
    app
    |> ref_keys(controller_name)
    |> Enum.find_value(&Process.get/1)
  end

  defp put_lookup_ref(%Ref{} = ref) do
    ref_keys(ref.app, ref.controller_name)
    |> Enum.each(&Process.put(&1, ref))

    ref
  end

  defp ref_key(app, controller_name), do: {:solve_lookup_ref, app, controller_name}

  defp ref_keys(app, controller_name) do
    [app | app_aliases(app)]
    |> Enum.uniq()
    |> Enum.map(&ref_key(&1, controller_name))
  end

  defp lookup_kind(app, controller_name) when is_atom(controller_name) do
    case Solve.controller_variant(app, controller_name) do
      :collection -> :collection
      :singleton -> :item
      nil -> :unknown
    end
  end

  defp lookup_kind(app, {source_name, _id}) when is_atom(source_name) do
    case Solve.controller_variant(app, source_name) do
      :collection -> :item
      _ -> :unknown
    end
  end

  defp lookup_kind(_app, _controller_name), do: :unknown

  defp app_aliases(app) do
    pid = app_pid(app)

    case {app, pid} do
      {_app, nil} ->
        []

      {app, pid} when is_pid(app) ->
        registered_name_aliases(pid)

      {_app, pid} ->
        [pid | registered_name_aliases(pid)]
    end
  end

  defp app_pid(app) when is_pid(app), do: app
  defp app_pid(app), do: GenServer.whereis(app)

  defp registered_name_aliases(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> [name]
      _ -> []
    end
  end

  defp resolve_app!(nil) do
    case Process.get(:solve_app) do
      nil ->
        raise ArgumentError, "Solve.Lookup could not resolve a solve app for the current process"

      app ->
        app
    end
  end

  defp resolve_app!(app), do: app

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
