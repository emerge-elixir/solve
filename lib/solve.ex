defmodule Solve do
  @moduledoc """
  Coordinates controller graph validation, lifecycle management, and subscriptions.

  Explicit app dispatch requires `dispatch/4`, including a payload (or `%{}`).
  The implicit `dispatch/2` and `dispatch/3` variants use controller callback context.

  Apps own a temporary-child supervisor. `start_link/1` accepts `:name`, `:params`,
  and a positive `:controller_start_timeout` in milliseconds (default 5,000).
  Controller shutdown is bounded to 1,000 ms.
  """

  alias Solve.Collection
  alias Solve.ControllerSpec

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
      def init(opts), do: Solve.Runtime.init(__MODULE__, opts)

      @impl true
      def terminate(reason, state), do: Solve.Runtime.terminate(reason, state)

      @impl true
      def handle_call(message, from, state), do: Solve.Runtime.handle_call(message, from, state)

      @impl true
      def handle_cast(message, state), do: Solve.Runtime.handle_cast(message, state)

      @impl true
      def handle_info(message, state), do: Solve.Runtime.handle_info(message, state)
    end
  end

  @doc """
  Subscribes a PID and returns raw exposed state, a collection, or nil.

  If a live controller's subscription handshake times out, returns its last accepted
  cached snapshot and schedules bounded attachment retries without restarting it.
  """
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
  def dispatch(controller_name, event, payload)
      when is_atom(event) and
             (is_atom(controller_name) or
                (is_tuple(controller_name) and tuple_size(controller_name) == 2 and
                   is_atom(elem(controller_name, 0)))) do
    resolve_current_app!()
    |> dispatch(controller_name, event, payload)
  end

  def dispatch(_app, _target, _event) do
    raise ArgumentError, "explicit app dispatch requires dispatch/4, including a payload (or %{})"
  end

  @spec dispatch(GenServer.server(), controller_target(), term(), term()) :: :ok
  def dispatch(app, controller_name, event, payload) do
    GenServer.cast(app, {:dispatch, controller_name, event, payload})
  end

  @doc false
  def subscribe_snapshot(app, target, subscriber \\ self()) do
    GenServer.call(app, {:snapshot, target, subscriber})
  end

  defp resolve_current_app! do
    case Process.get(:solve_app) do
      nil ->
        raise ArgumentError,
              "Solve.dispatch/2 and dispatch/3 require a current solve app; use dispatch/4 for an explicit app"

      app ->
        app
    end
  end
end
