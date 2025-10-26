defmodule Bonseki.Controller do
  @moduledoc """
  A behavior and macro for defining Bonseki controllers.

  Controllers are GenServers that manage state and handle events.
  They can declare events they respond to and provide an `expose/1`
  function to control what state is visible to UIs.

  ## Example

      defmodule MyApp.CounterController do
        use Bonseki.Controller, events: [:increment, :decrement, :reset]

        def init(_params) do
          %{count: 0}
        end

        def increment(state) do
          %{state | count: state.count + 1}
        end

        def decrement(state) do
          %{state | count: state.count - 1}
        end

        def reset(_state) do
          %{count: 0}
        end

        def expose(state) do
          %{count: state.count}
        end
      end
  """

  @doc """
  Exposes the controller's state to UIs. Defaults to returning the full state.
  Can optionally receive dependencies as second argument.
  """
  @callback expose(state :: map(), dependencies :: map()) :: map()

  defmacro __using__(opts) do
    events = Keyword.get(opts, :events, [])

    quote do
      use GenServer
      @behaviour Bonseki.Controller

      @events unquote(events)

      def definition do
        @events
      end

      # Default init - can be overridden
      # Receives dependencies map (e.g., %{lemons: %{count: 0}, water: %{count: 0}})
      def init(_dependencies) do
        %{}
      end

      # Default expose - can be overridden
      # Receives state and dependencies
      def expose(state, _dependencies) do
        state
      end

      defoverridable init: 1, expose: 2

      # GenServer callbacks
      def start_link(opts) do
        app_pid = Keyword.fetch!(opts, :app_pid)
        controller_name = Keyword.fetch!(opts, :controller_name)
        dependency_names = Keyword.get(opts, :dependency_names, [])
        GenServer.start_link(__MODULE__, {app_pid, controller_name, dependency_names})
      end

      @impl true
      def init({app_pid, controller_name, dependency_names}) do
        # Initialize with empty dependencies - controllers should handle this gracefully
        initial_state = init(%{})

        # Register with the app as started
        GenServer.cast(app_pid, {:controller_started, controller_name, self()})

        {:ok,
         %{
           state: initial_state,
           app_pid: app_pid,
           controller_name: controller_name,
           dependency_names: dependency_names,
           dependencies: %{}
         }, {:continue, :init_with_dependencies}}
      end

      @impl true
      def handle_continue(:init_with_dependencies, server_state) do
        # Now reinitialize with actual dependencies after all controllers are up
        if length(server_state.dependency_names) > 0 do
          # Give other controllers time to start and initialize
          # Need enough time for dependencies with no deps to fully init

          dependencies =
            get_dependencies_state(server_state.app_pid, server_state.dependency_names)

          new_state = init(dependencies)
          {:noreply, %{server_state | state: new_state, dependencies: dependencies}}
        else
          {:noreply, server_state}
        end
      end

      @impl true
      def handle_cast({:event, event_name, event_params}, server_state) do
        current_state = server_state.state

        # Call the event handler if it exists in our events list
        new_state =
          if event_name in @events do
            apply(__MODULE__, event_name, [current_state, event_params])
          else
            current_state
          end

        dbg(new_state)
        dbg(current_state)
        # Notify app of state change
        if new_state != current_state do
          GenServer.cast(
            server_state.app_pid,
            {:controller_state_changed, server_state.controller_name}
          )
        end

        {:noreply, %{server_state | state: new_state}}
      end

      @impl true
      def handle_call(:get_exposed_state, _from, server_state) do
        # Use cached dependencies to avoid circular calls
        dependencies = server_state.dependencies

        exposed_state = expose(server_state.state, dependencies)

        {:reply, exposed_state, %{server_state | state: exposed_state}}
      end

      @impl true
      def handle_call(:get_state, _from, server_state) do
        {:reply, server_state.state, server_state}
      end

      @impl true
      def handle_cast(:refresh_dependencies, server_state) do
        # Refresh cached dependencies when a dependency changes
        IO.inspect("REFRESH DEPENDENCIES", label: "REFRESH DEPENDENCIES")
        IO.inspect(server_state, label: "STATE")

        if length(server_state.dependency_names) > 0 do
          dependencies =
            get_dependencies_state(server_state.app_pid, server_state.dependency_names)

          exposed_state = expose(server_state.state, dependencies)

          if exposed_state != server_state.state do
            GenServer.cast(
              server_state.app_pid,
              {:controller_state_changed, server_state.controller_name}
            )
          end

          {:noreply, %{server_state | dependencies: dependencies, state: exposed_state}}
        else
          {:noreply, server_state}
        end
      end

      # Helper to get dependencies state from app
      defp get_dependencies_state(_app_pid, []), do: %{}

      defp get_dependencies_state(app_pid, dependency_names) do
        GenServer.call(app_pid, {:get_dependencies_state, dependency_names}, 100_000)
      end

      # Compile-time validation that all declared events have handlers
      @after_compile __MODULE__

      def __after_compile__(_env, _bytecode) do
        # Verify all events have corresponding functions
        for event <- @events do
          unless function_exported?(__MODULE__, event, 2) do
            raise CompileError,
              description:
                "Event handler #{event}/2 not defined in #{__MODULE__}. " <>
                  "All events declared in `use Bonseki.Controller` must have a corresponding function."
          end
        end

        :ok
      end
    end
  end
end
