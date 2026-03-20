defmodule Solve.Lookup do
  @moduledoc """
  Process-local facade for interacting with a Solve app.

  `solve/2` subscribes once per process and controller, caches the latest exposed map in the
  process dictionary under `{:solve_lookup_ref, app, controller_name}`, and augments the
  returned map with `:events_` dispatch refs.

  `use Solve.Lookup` supports two modes:

  - `handle_info: :auto` (default) consumes `%Solve.Message{}` and `nil` in injected
    `handle_info/2` clauses and calls `handle_solve_updated/2` when updates are observed.
  - `handle_info: :manual` injects no `handle_info/2` clauses; match `%Solve.Message{}`
    yourself, handle `nil` explicitly, and call `handle_message/1`.

  See `examples/counter_lookup_example.md` for a complete end-to-end example.

  ## Basic usage

      defmodule MyApp.CounterWorker do
        use GenServer
        use Solve.Lookup

        def start_link(app) do
          GenServer.start_link(__MODULE__, app, name: __MODULE__)
        end

        def init(app) do
          {:ok, %{app: app}}
        end

        def render(state) do
          counter = solve(state.app, :counter)
          IO.inspect(counter, label: "counter")
          state
        end

        @impl Solve.Lookup
        def handle_solve_updated(_updated, state) do
          {:ok, render(state)}
        end
      end

  `solve/2` returns the exposed controller map augmented with `:events_`:

      %{
        count: 2,
        events_: %{
          increment: %Solve.Message{type: :dispatch, payload: %Solve.Dispatch{...}}
        }
      }

  Use `events/1` to access event refs safely. If the controller is off, `solve/2` returns
  `nil` and `events(nil)` also returns `nil`; auto mode ignores that `nil` for you, and
  manual handlers can do the same with `handle_info(nil, state)`.

  ## Manual handle_info forwarding

      defmodule MyApp.ManualWorker do
        use GenServer
        use Solve.Lookup, handle_info: :manual

        def init(app) do
          {:ok, %{app: app}}
        end

        def render(state) do
          counter = solve(state.app, :counter)
          IO.inspect(counter, label: "counter")
          state
        end

        def handle_info(nil, state) do
          {:noreply, state}
        end

        def handle_info(%Solve.Message{} = message, %{app: app} = state) do
          case handle_message(message) do
            %{^app => controllers} ->
              if :counter in controllers,
                do: {:noreply, render(state)},
                else: {:noreply, state}

            %{} ->
              {:noreply, state}
          end
        end

        def handle_info(_message, state) do
          {:noreply, state}
        end
      end

  `handle_message/1` returns a map keyed by the actual Solve app ref/pid, so manual
  handlers typically match the `app` stored in state.

  ## Reserved keys

  `:events_` is reserved for lookup augmentation. Running controllers must expose plain maps
  that do not already contain that key.
  """

  defmodule Ref do
    @moduledoc false

    @enforce_keys [:app, :controller_name, :events, :subscribed?]
    defstruct [:app, :controller_name, :value, :events, :subscribed?]
  end

  @events_key :events_

  @type updated_controllers :: %{optional(GenServer.server()) => [atom()]}

  @callback handle_solve_updated(updated_controllers(), term()) :: {:ok, term()}
  @optional_callbacks handle_solve_updated: 2

  defmacro __using__(opts \\ []) do
    %{handle_info_mode: handle_info_mode} = validate_options!(opts, __CALLER__)

    quote bind_quoted: [handle_info_mode: handle_info_mode] do
      @behaviour Solve.Lookup

      import Solve.Lookup,
        only: [
          solve: 1,
          solve: 2,
          dispatch: 2,
          dispatch: 3,
          dispatch: 4,
          events: 1,
          handle_message: 1
        ]

      @before_compile Solve.Lookup
      @solve_lookup_handle_info_mode handle_info_mode

      if handle_info_mode == :auto do
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
  Consumes a `%Solve.Message{}` and returns a map of updated controllers grouped by the
  actual Solve app ref/pid.

  Returns `%{}` when the message is Solve-related but does not update any cached controller
  value in this process (for example, a dispatch envelope).
  """
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
      })
      when is_atom(controller_name) do
    app = resolve_app!(app)

    ref =
      Process.get(ref_key(app, controller_name)) || build_lookup_ref(app, controller_name, nil)

    put_lookup_ref(%{ref | value: validate_lookup_value!(exposed_value), subscribed?: true})
    %{app => [controller_name]}
  end

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
      {event, Solve.Message.dispatch(app, controller_name, event, %{})}
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

  defp validate_options!(opts, caller) when is_list(opts) do
    handle_info_mode =
      validate_handle_info_option!(Keyword.get(opts, :handle_info, :auto), caller)

    %{handle_info_mode: handle_info_mode}
  end

  defp validate_options!(opts, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "use Solve.Lookup expects a keyword list, got: #{inspect(opts)}"
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
