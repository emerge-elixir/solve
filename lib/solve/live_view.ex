defmodule Solve.LiveView do
  @moduledoc """
  LiveView adapter for Solve, layered on top of `Solve.Lookup`.

  Provides namespace-scoped socket assigns where controller data and events
  are merged flat, enabling clean template access like `@ls.counter.increment`.

  ## Usage

      defmodule MyAppWeb.CounterLive do
        use Phoenix.LiveView
        use Solve.LiveView

        def mount(_, _, socket) do
          solve_app = solve_start(MyApp.State, :ls)
          assigns = solve(solve_app, [:counter])
          {:ok, assign(socket, assigns)}
        end

        def render(assigns) do
          ~H\"\"\"
          <button phx-click={@ls.counter.increment}>+</button>
          <h1>{@ls.counter.count}</h1>
          <button phx-click={@ls.counter.decrement}>-</button>
          \"\"\"
        end
      end

  `solve_start/2` binds a Solve app to a namespace atom. `solve/2` subscribes to
  controllers and returns a map suitable for `assign/2`, with data and `JS.push`
  event commands merged flat under `namespace.controller_name`.

  Updates arrive via `handle_info` and automatically refresh socket assigns.
  Template events dispatch through an injected `handle_event("solve_event", ...)`.
  """

  defmodule AppRef do
    @moduledoc false
    @enforce_keys [:app, :namespace]
    defstruct [:app, :namespace]
    @type t() :: %__MODULE__{app: atom(), namespace: atom()}
  end

  @solve_event "solve_event"

  defmacro __using__(_opts \\ []) do
    quote do
      import Solve.LiveView, only: [solve_start: 1, solve_start: 2, solve: 2]
      import Solve.Lookup, only: [dispatch: 2, dispatch: 3, dispatch: 4]

      def handle_info({:solve_update, app, controller_name, exposed_value}, socket) do
        {:noreply, Solve.LiveView.__handle_info__(socket, app, controller_name, exposed_value)}
      end

      def handle_event(unquote(@solve_event), params, socket) do
        {:noreply, Solve.LiveView.__handle_event__(socket, params)}
      end
    end
  end

  @doc """
  Binds a Solve app to a namespace for this LiveView process.

  Returns an `AppRef` used by `solve/2`.
  """
  @spec solve_start(GenServer.server(), atom()) :: AppRef.t()
  def solve_start(app, namespace \\ :state) when is_atom(namespace) do
    tap(%AppRef{namespace: namespace, app: app}, &Process.put({:solve_lv_app, namespace}, &1))
  end

  @doc """
  Subscribes to controllers and returns a map of namespace-scoped assigns.

  Each controller's exposed data is merged flat with `JS.push` commands for its
  declared events. The result is directly passable to `assign/2`.

      assigns = solve(app_ref, [:counter, :timer])
      # => %{ls: %{counter: %{count: 0, increment: %JS{...}}, timer: %{...}}}
  """
  @spec solve(AppRef.t(), [atom()]) :: map()
  def solve(%AppRef{namespace: namespace, app: app}, controller_names)
      when is_list(controller_names) do
    %{
      namespace =>
        Map.new(controller_names, fn controller_name ->
          lookup_result = Solve.Lookup.solve(app, controller_name)
          assigns = to_assigns(namespace, controller_name, lookup_result)
          {controller_name, assigns}
        end)
    }
  end

  @doc false
  def __handle_info__(socket, app, controller_name, exposed_value) do
    case find_namespace_for_app(app) do
      nil ->
        socket

      {namespace, stored_app} ->
        message = {:solve_update, stored_app, controller_name, exposed_value}
        Solve.Lookup.__handle_message__(message, nil, nil, nil)
        lookup_result = Solve.Lookup.solve(stored_app, controller_name)
        assigns = to_assigns(namespace, controller_name, lookup_result)
        current_ns = Map.get(socket.assigns, namespace, %{})
        updated_ns = Map.put(current_ns, controller_name, assigns)
        Phoenix.Component.assign(socket, namespace, updated_ns)
    end
  end

  @doc false
  def __handle_event__(socket, params) do
    namespace = String.to_existing_atom(params["_sn"])
    controller_name = String.to_existing_atom(params["_sc"])
    event = String.to_existing_atom(params["_se"])
    payload = Map.drop(params, ["_sn", "_sc", "_se"])

    case Process.get({:solve_lv_app, namespace}) do
      %AppRef{app: app} -> Solve.dispatch(app, controller_name, event, payload)
      nil -> :ok
    end

    socket
  end

  defp to_assigns(_namespace, _controller_name, nil), do: nil

  defp to_assigns(namespace, controller_name, lookup_result) do
    lookup_result
    |> Solve.Lookup.events()
    |> Map.new(fn {event_name, %Solve.Lookup.Dispatch{}} ->
      {event_name, push_event(namespace, controller_name, event_name)}
    end)
    |> then(fn js_events ->
      lookup_result
      |> Map.delete(:events_)
      |> Map.merge(js_events)
    end)
  end

  defp find_namespace_for_app(app) do
    Enum.find_value(Process.get_keys(), fn
      {:solve_lv_app, namespace} ->
        case Process.get({:solve_lv_app, namespace}) do
          %AppRef{app: stored_app} ->
            if is_pid(app) and GenServer.whereis(stored_app) == app do
              {namespace, stored_app}
            end
        end

      _ ->
        nil
    end)
  end

  defp push_event(namespace, controller_name, event_name) do
    value = %{"_sn" => namespace, "_sc" => controller_name, "_se" => event_name}
    Phoenix.LiveView.JS.push(@solve_event, value: value)
  end
end
