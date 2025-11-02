defmodule Bonseki.UI do
  @moduledoc """
  A macro for integrating Bonseki with Phoenix LiveView.

  UIs subscribe directly to controllers and communicate with them without
  any intermediary. This provides a clean, efficient architecture with
  minimal message passing overhead.

  ## Direct Communication

  - **Subscriptions**: UIs subscribe directly to controllers during mount
  - **Events**: UIs send events directly to controller PIDs
  - **Updates**: UIs receive state updates directly from controllers

  ## Multiple UI Instances

  Each UI instance automatically gets its own isolated app instance with
  independent controllers. This allows multiple users or sessions to have
  completely separate state:

      defmodule MyAppWeb.DashboardLive do
        use Bonseki.UI, app: MyApp.App

        def init(_params) do
          %{counter: :counter}
        end
      end

  When multiple DashboardLive instances mount, each gets a uniquely named
  app (e.g., `MyAppWeb.DashboardLive.App.1`, `MyAppWeb.DashboardLive.App.2`, etc.)
  with its own controller processes and state.

  ## Example

      defmodule MyAppWeb.DashboardLive do
        use Bonseki.UI, app: MyApp.App

        def init(_params) do
          %{
            lemons: :lemons,  # assign_name => controller_name
            water: :water
          }
        end

        def render(assigns) do
          ~H\"\"\"
          <div>
            <h1>Lemons: {@lemons.count}</h1>
            <button phx-click={@lemons.add}>Add Lemon</button>

            <h1>Water: {@water.count}</h1>
            <button phx-click={@water.add}>Add Water</button>
          </div>
          \"\"\"
        end
      end

  ## How It Works

  1. **Mount**: The `init/1` function returns a map of subscriptions
  2. **App Creation**: A unique app instance is automatically started for this UI
  3. **Subscribe**: Each controller is subscribed to directly via `GenServer.call`
  4. **Initial State**: Controllers return their current state and event list
  5. **Event Binding**: Event functions are automatically generated (e.g., `@lemons.add`)
  6. **Updates**: Controllers send `{:bonseki_update, ...}` messages directly to the UI

  ## Event Format

  Event strings use the format `"bonseki:assign_name:event_name"` and are
  automatically generated for each controller event. When clicked, they
  dispatch directly to the controller PID.
  """

  @doc """
  Ensures an app is started for the given UI module and returns its unique name.

  This function generates a unique app name based on the UI module and starts
  the app if it doesn't already exist. Each call with the same UI module will
  create a new instance with an incrementing counter.

  ## Examples

      iex> Bonseki.UI.ensure_app_started(MyApp.App, MyAppWeb.DashboardLive)
      MyAppWeb.DashboardLive.App.1

      iex> Bonseki.UI.ensure_app_started(MyApp.App, MyAppWeb.DashboardLive)
      MyAppWeb.DashboardLive.App.2
  """
  def ensure_app_started(app_module, ui_module) do
    counter = System.unique_integer([:positive])
    counter_atom = String.to_atom(Integer.to_string(counter))
    app_name = Module.concat([ui_module, App, counter_atom])
    app_module.start_link(name: app_name)
  end

  defmacro __using__(opts) do
    app_module = Keyword.fetch!(opts, :app)

    quote do
      use Phoenix.LiveView

      @app_module unquote(app_module)

      @impl true
      def mount(params, session, socket) do
        {:ok, app_pid} = Bonseki.UI.ensure_app_started(@app_module, __MODULE__)

        socket =
          params
          |> init()
          |> Enum.into(%{}, fn {assign_name, controller_name} ->
            controller_pid = GenServer.call(app_pid, {:fetch_controller_pid, assign_name})
            controller_pid || raise "Controller #{assign_name} is not alive"
            {:ok, state, events} = GenServer.call(controller_pid, {:subscribe_ui, assign_name})
            {assign_name, {controller_name, controller_pid, state, events}}
          end)
          |> Enum.reduce(socket, fn params, socket ->
            {assign_name, {controller_name, controller_pid, state, events}} = params
            assign_values = build_assign(assign_name, state, controller_pid, events)
            Phoenix.Component.assign(socket, assign_name, assign_values)
          end)

        {:ok, socket}
      end

      @impl true
      def handle_event("bonseki:" <> event_string, params, socket) do
        [assign_name_str, event_name] = String.split(event_string, ":", parts: 2)
        assign_name = String.to_existing_atom(assign_name_str)
        event_atom = String.to_existing_atom(event_name)
        controller_pid = socket.assigns[assign_name].pid
        GenServer.cast(controller_pid, {:event, event_atom, params})
        {:noreply, socket}
      end

      @impl true
      def handle_info({:bonseki_update, assign_name, _controller_name, new_state}, socket) do
        updated_assign = Map.merge(socket.assigns[assign_name], new_state)
        {:noreply, assign(socket, assign_name, updated_assign)}
      end

      defp build_assign(assign_name, state, pid, events) do
        state = Map.put(state, :pid, pid)
        events = Enum.into(events, %{}, &{&1, "bonseki:#{assign_name}:#{&1}"})
        Map.merge(state, events)
      end

      @doc """
      Initialize the LiveView. Use this to subscribe to controllers.
      """
      @callback init(params :: map()) :: :ok

      def init(_params) do
        :ok
      end

      defoverridable init: 1
    end
  end
end
