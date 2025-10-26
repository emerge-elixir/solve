defmodule Bonseki.UI do
  @moduledoc """
  A macro for integrating Bonseki with Phoenix LiveView.

  Provides helpers for subscribing to controllers and automatically
  handling state updates and event dispatching.

  ## Example

      defmodule MyAppWeb.DashboardLive do
        use Bonseki.UI, app: MyApp.App

        def init(_params) do
          subscribe(LemonController, :lemons)
          subscribe(WaterController, :water)
        end

        def render(assigns) do
          ~H\"\"\"
          <div>
            <h1>Lemons: {@lemons.count}</h1>
            <button phx-click={@lemons.increment}>Add Lemon</button>
          </div>
          \"\"\"
        end
      end
  """

  defmacro __using__(opts) do
    app_module = Keyword.fetch!(opts, :app)

    quote do
      use Phoenix.LiveView

      @app_module unquote(app_module)
      Module.register_attribute(__MODULE__, :subscriptions, accumulate: true)

      @doc """
      Subscribe to a controller's state by name.
      """
      def subscribe(params, subscriptions) do
        # We can't use Module.put_attribute here since it's runtime
        # Instead, we need a different approach
        Map.merge(params, subscriptions)
      end

      # Helper to get subscriptions (can be used at runtime)
      def __bonseki_subscriptions__, do: @subscriptions

      @impl true
      def mount(params, session, socket) do
        dbg(@subscriptions)
        dbg(params)
        # Call user-defined init
        subscriptions = init(params) |> dbg()

        # Get accumulated subscriptions
        app_pid = Process.whereis(@app_module)
        # Register with app and get initial states
        dbg(subscriptions)

        {:ok, initial_states} =
          GenServer.call(app_pid, {:register_ui, self(), subscriptions})

        dbg(initial_states)
        # Build assigns from initial states
        socket =
          Enum.reduce(initial_states, socket, fn {assign_name, {controller_name, state, events}},
                                                 socket_acc ->
            # Build assign with state and event functions
            assign_value = build_assign(assign_name, state, events)
            Phoenix.Component.assign(socket_acc, assign_name, assign_value)
          end)

        # Store subscriptions in socket for later use

        {:ok, socket}
      end

      @impl true
      def handle_event("bonseki:" <> event_string, params, socket) do
        # Parse event string: "controller_name:event_name"
        case String.split(event_string, ":", parts: 2) do
          [controller_name_str, event_name] ->
            # Convert to atoms
            controller_name = String.to_existing_atom(controller_name_str)
            event_atom = String.to_existing_atom(event_name)
            app_pid = Process.whereis(@app_module)

            # Dispatch to app
            GenServer.cast(app_pid, {:dispatch_event, controller_name, event_atom, params})
            |> dbg()

            {:noreply, socket}

          _ ->
            {:noreply, socket}
        end
      end

      @impl true
      def handle_info({:bonseki_update, assign_name, controller_name, new_state}, socket) do
        dbg(assign_name)
        dbg(controller_name)
        dbg(new_state)
        {:noreply, assign(socket, assign_name, Map.merge(socket.assigns[assign_name], new_state))}
      end

      defp build_assign(assign_name, state, events) do
        # Build event functions map
        event_functions =
          Enum.into(events, %{}, fn event ->
            # Create event string that handle_event can parse
            event_string = "bonseki:#{assign_name}:#{event}"
            {event, event_string}
          end)

        # Merge state with event functions
        Map.merge(state, event_functions)
      end

      # User must implement init/1
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
