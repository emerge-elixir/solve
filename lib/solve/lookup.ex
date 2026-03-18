defmodule Solve.Lookup do
  @moduledoc """
  Process-local facade for interacting with a Solve app.

  `solve/2` subscribes once per process and controller, caches the latest exposed map in the
  process dictionary under `{:solve_lookup_ref, app, controller_name}`, and augments the
  returned map with `:events_` dispatch refs.

  `use Solve.Lookup` injects `handle_info/2` clauses by default and calls `render/1` after a
  `{:solve_update, ...}` message refreshes the local cache. Use `handle_info: false` to opt out
  and forward messages manually with `handle_solve_lookup/2`.

  See `examples/counter_lookup_example.md` for a complete end-to-end example.

  ## Basic usage

      defmodule MyApp.CounterWorker do
        use GenServer
        use Solve.Lookup

        def init(_opts) do
          {:ok, %{}}
        end

        def increment do
          counter = solve(MyApp.State, :counter)
          send(self(), events(counter)[:increment])
        end

        def render(state) do
          counter = solve(MyApp.State, :counter)
          IO.inspect(counter, label: "counter")
          state
        end
      end

  `solve/2` returns the exposed controller map augmented with `:events_`:

      %{
        count: 2,
        events_: %{
          increment: %Solve.Lookup.Dispatch{...}
        }
      }

  Use `events/1` to access event refs safely. If the controller is off, `solve/2` returns
  `nil` and `events(nil)` also returns `nil`.

  ## Manual handle_info forwarding

      defmodule MyApp.ManualWorker do
        use GenServer
        use Solve.Lookup, handle_info: false

        def init(_opts) do
          {:ok, %{}}
        end

        def render(state) do
          counter = solve(MyApp.State, :counter)
          IO.inspect(counter, label: "counter")
          state
        end

        def handle_info(message, state) do
          case handle_solve_lookup(message, state) do
            {:handled, state} -> {:noreply, state}
            :unhandled -> {:noreply, state}
          end
        end
      end

  ## Reserved keys

  `:events_` is reserved for lookup augmentation. Running controllers must expose plain maps
  that do not already contain that key.
  """

  defmodule Ref do
    @moduledoc false

    @enforce_keys [:app, :controller_name, :events, :subscribed?]
    defstruct [:app, :controller_name, :value, :events, :subscribed?]
  end

  defmodule Dispatch do
    @moduledoc false

    @enforce_keys [:app, :controller_name, :event, :payload]
    defstruct [:app, :controller_name, :event, :payload]
  end

  @events_key :events_

  defmacro __using__(opts \\ []) do
    %{handle_info?: handle_info?, on_update: on_update} = validate_options!(opts, __CALLER__)

    quote bind_quoted: [handle_info?: handle_info?, on_update: on_update] do
      import Solve.Lookup,
        only: [solve: 1, solve: 2, dispatch: 2, dispatch: 3, dispatch: 4, events: 1]

      @before_compile Solve.Lookup
      @solve_lookup_handle_info handle_info?
      @solve_lookup_on_update on_update

      def handle_solve_lookup(message, state) do
        Solve.Lookup.__handle_message__(message, state, __MODULE__, @solve_lookup_on_update)
      end

      if handle_info? do
        def handle_info({:solve_update, app, controller_name, exposed_value}, state) do
          {:handled, state} =
            handle_solve_lookup({:solve_update, app, controller_name, exposed_value}, state)

          {:noreply, state}
        end

        def handle_info(%Solve.Lookup.Dispatch{} = dispatch, state) do
          {:handled, state} = handle_solve_lookup(dispatch, state)
          {:noreply, state}
        end

        def handle_info(nil, state) do
          {:handled, state} = handle_solve_lookup(nil, state)
          {:noreply, state}
        end
      end
    end
  end

  defmacro __before_compile__(env) do
    on_update = Module.get_attribute(env.module, :solve_lookup_on_update)

    if is_atom(on_update) and not is_nil(on_update) do
      definitions = MapSet.new(Module.definitions_in(env.module))

      unless MapSet.member?(definitions, {on_update, 1}) do
        raise CompileError,
          file: env.file,
          line: 1,
          description: "#{inspect(env.module)} must define #{on_update}/1 when using Solve.Lookup"
      end
    end

    quote(do: :ok)
  end

  @doc """
  Returns the current exposed map for a controller augmented with `:events_` dispatch refs.
  Returns `nil` when the controller is currently off/stopped.
  """
  @spec solve(atom()) :: map() | nil
  def solve(controller_name) do
    solve(nil, controller_name)
  end

  @spec solve(GenServer.server() | nil, atom()) :: map() | nil
  def solve(app, controller_name) when is_atom(controller_name) do
    app
    |> resolve_app!()
    |> ensure_lookup_ref(controller_name)
    |> augment_lookup_value()
  end

  @doc """
  Dispatches an event through the Solve runtime using the current process app.
  """
  @spec dispatch(atom(), atom()) :: :ok
  def dispatch(controller_name, event) when is_atom(controller_name) do
    dispatch(nil, controller_name, event, %{})
  end

  @spec dispatch(atom(), atom(), term()) :: :ok
  def dispatch(controller_name, event, payload) when is_atom(controller_name) do
    dispatch(nil, controller_name, event, payload)
  end

  @spec dispatch(GenServer.server() | nil, atom(), atom(), term()) :: :ok
  def dispatch(app, controller_name, event, payload) when is_atom(controller_name) do
    app
    |> resolve_app!()
    |> Solve.dispatch(controller_name, event, payload)
  end

  @doc """
  Returns the nested events map from a lookup result.
  """
  @spec events(map() | nil) :: map() | nil
  def events(nil), do: nil
  def events(%{@events_key => events}), do: events
  def events(_value), do: nil

  @doc """
  Handles lookup-related messages and returns `:handled` or `:unhandled`.
  """
  @spec handle_message(term()) :: :handled | :unhandled
  def handle_message(nil), do: :handled

  def handle_message(%Dispatch{} = dispatch) do
    Solve.dispatch(dispatch.app, dispatch.controller_name, dispatch.event, dispatch.payload)
    :handled
  end

  def handle_message({:solve_update, app, controller_name, exposed_value})
      when is_atom(controller_name) do
    case __handle_message__({:solve_update, app, controller_name, exposed_value}, nil, nil, nil) do
      {:handled, _state} -> :handled
      :unhandled -> :unhandled
    end
  end

  def handle_message(_message), do: :unhandled

  @doc false
  def __handle_message__(nil, state, _module, _on_update), do: {:handled, state}

  def __handle_message__(%Dispatch{} = dispatch, state, _module, _on_update) do
    Solve.dispatch(dispatch.app, dispatch.controller_name, dispatch.event, dispatch.payload)
    {:handled, state}
  end

  def __handle_message__(
        {:solve_update, app, controller_name, exposed_value},
        state,
        module,
        on_update
      )
      when is_atom(controller_name) do
    app = resolve_app!(app)

    ref =
      Process.get(ref_key(app, controller_name)) || build_lookup_ref(app, controller_name, nil)

    put_lookup_ref(%{ref | value: validate_lookup_value!(exposed_value), subscribed?: true})
    maybe_call_on_update(module, on_update, state)
    {:handled, state}
  end

  def __handle_message__(_message, _state, _module, _on_update), do: :unhandled

  defp ensure_lookup_ref(app, controller_name) do
    case Process.get(ref_key(app, controller_name)) do
      %Ref{} = ref ->
        ref

      nil ->
        ref =
          build_lookup_ref(
            app,
            controller_name,
            Solve.subscribe(app, controller_name, self())
          )

        put_lookup_ref(ref)
        ref
    end
  end

  defp augment_lookup_value(%Ref{value: nil}), do: nil

  defp augment_lookup_value(%Ref{value: value, events: events}) do
    Map.put(value, @events_key, events)
  end

  defp build_lookup_ref(app, controller_name, value) do
    %Ref{
      app: app,
      controller_name: controller_name,
      value: validate_lookup_value!(value),
      events: build_dispatches(app, controller_name),
      subscribed?: true
    }
  end

  defp build_dispatches(app, controller_name) do
    app
    |> Solve.controller_events(controller_name)
    |> Kernel.||([])
    |> Map.new(fn event ->
      {event, %Dispatch{app: app, controller_name: controller_name, event: event, payload: %{}}}
    end)
  end

  defp validate_lookup_value!(nil), do: nil

  defp validate_lookup_value!(value) when is_map(value) and not is_struct(value) do
    if Map.has_key?(value, @events_key) do
      raise ArgumentError,
            "Solve.Lookup reserves #{inspect(@events_key)} in exposed controller maps"
    else
      value
    end
  end

  defp validate_lookup_value!(value) do
    raise ArgumentError,
          "Solve.Lookup expects exposed controller values to be plain maps or nil, got: #{inspect(value)}"
  end

  defp put_lookup_ref(%Ref{} = ref) do
    Process.put(ref_key(ref.app, ref.controller_name), ref)
    ref
  end

  defp ref_key(app, controller_name), do: {:solve_lookup_ref, app, controller_name}

  defp resolve_app!(nil) do
    case Process.get(:solve_app) do
      nil ->
        raise ArgumentError, "Solve.Lookup could not resolve a solve app for the current process"

      app ->
        app
    end
  end

  defp resolve_app!(app), do: app

  defp maybe_call_on_update(_module, nil, _state), do: :ok

  defp maybe_call_on_update(nil, _on_update, _state), do: :ok

  defp maybe_call_on_update(module, on_update, state) do
    apply(module, on_update, [state])
    :ok
  end

  defp validate_options!(opts, caller) when is_list(opts) do
    handle_info? = validate_handle_info_option!(Keyword.get(opts, :handle_info, true), caller)
    on_update = validate_on_update_option!(Keyword.get(opts, :on_update, :render), caller)

    %{handle_info?: handle_info?, on_update: on_update}
  end

  defp validate_options!(opts, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "use Solve.Lookup expects a keyword list, got: #{inspect(opts)}"
  end

  defp validate_handle_info_option!(value, _caller) when is_boolean(value), do: value

  defp validate_handle_info_option!(value, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "Solve.Lookup handle_info option must be a boolean, got: #{inspect(value)}"
  end

  defp validate_on_update_option!(nil, _caller), do: nil
  defp validate_on_update_option!(value, _caller) when is_atom(value), do: value

  defp validate_on_update_option!(value, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "Solve.Lookup on_update option must be an atom or nil, got: #{inspect(value)}"
  end
end
