defmodule Solve.Controller do
  @moduledoc """
  A behavior and macro for defining Solve controllers.

  Controllers are GenServers that manage state, handle events, and communicate
  directly with their dependents (UIs and other controllers). They maintain a
  list of dependents and notify them automatically when state changes.

  ## Responsibilities

  - Manage internal state
  - Handle events from UIs
  - Track dependents (both UIs and other controllers)
  - Send state updates directly to dependents
  - Monitor dependent processes and clean up on termination
  - Refresh state when dependencies change

  ## Direct Communication

  Controllers communicate directly with:
  - **UIs**: Send `{:solve_update, assign_name, controller_name, state}` messages
  - **Dependent Controllers**: Send `:refresh_dependencies` cast messages

  ## Example

      defmodule MyApp.CounterController do
        use Solve.Controller, events: [:increment, :decrement, :reset]

        @impl true
        def init(_params, _dependencies) do
          %{
            count: 0,
            private_data: "secret"
          }
        end

        def increment(state, _params) do
          %{state | count: state.count + 1}
        end

        def decrement(state, _params) do
          %{state | count: state.count - 1}
        end

        def reset(_state, _params) do
          %{
            count: 0,
            private_data: "secret"
          }
        end

        @impl true
        def expose(state, _dependencies) do
          # Only expose public state
          %{count: state.count}
        end
      end

  ## With Dependencies

      defmodule MyApp.ComputedController do
        use Solve.Controller, events: []

        @impl true
        def init(_params, _dependencies) do
          %{result: 0}
        end

        @impl true
        def expose(_state, dependencies) do
          # Compute based on dependencies
          source_value = dependencies[:source].value
          %{result: source_value * 10}
        end
      end

  ## With Params from Scene

      defmodule MyApp.CurrentUserController do
        use Solve.Controller, events: [:update_profile]

        @impl true
        def init(current_user, _dependencies) do
          # If controller is running, current_user is guaranteed to be truthy
          %{current_user: current_user}
        end

        def update_profile(state, params) do
          updated_user = %{state.current_user | name: params["name"]}
          %{state | current_user: updated_user}
        end

        @impl true
        def expose(state, _dependencies) do
          state.current_user
        end
      end

      # In scene:
      # scene params do
      #   controller(:current_user, MyApp.CurrentUserController,
      #     params: fn _ -> params[:current_user] end)
      # end

  ## Using Structs for State (Recommended)

  While controllers work with plain maps, using structs is recommended for
  better documentation, type safety, and tooling support:

      defmodule MyApp.AuthController do
        use Solve.Controller, events: [:submit, :validate]

        defmodule State do
          @moduledoc "State for authentication form"
          defstruct [
            :email,
            :password,
            :errors
          ]

          @type t :: %__MODULE__{
            email: String.t(),
            password: String.t(),
            errors: map()
          }
        end

        @impl true
        def init(_params, _dependencies) do
          %State{
            email: "",
            password: "",
            errors: %{}
          }
        end

        def validate(state, params) do
          errors = validate_form(params)
          %State{state | errors: errors}
        end

        def submit(%State{} = state, params) do
          case authenticate(params) do
            {:ok, user} ->
              %State{state | errors: %{}}

            {:error, reason} ->
              %State{state | errors: %{auth: reason}}
          end
        end

        @impl true
        def expose(%State{} = state, _dependencies) do
          # Expose as map or struct - both work
          %{
            email: state.email,
            errors: state.errors,
            valid?: map_size(state.errors) == 0
          }
        end

        defp validate_form(params), do: %{}
        defp authenticate(_params), do: {:ok, %{}}
      end

  Using structs provides:
  - **Clear documentation** of all state fields
  - **Compile-time checking** for typos in field names
  - **Better tooling** (autocomplete, dialyzer)
  - **Type specifications** for better maintainability
  """

  @doc """
  Initializes the controller state.
  Receives params value from the scene and dependencies (exposed states from other controllers).
  The params value can be any truthy value (if nil or false, the controller won't start).
  """
  @callback init(params :: any(), dependencies :: map()) :: map()

  @doc """
  Exposes the controller's state to UIs and other controllers.
  Defaults to returning the full state. Can compute based on dependencies.
  """
  @callback expose(state :: map(), dependencies :: map()) :: any()

  defmacro __using__(opts) do
    events = Keyword.get(opts, :events, [])

    quote do
      use GenServer
      @behaviour Solve.Controller

      @events unquote(events)

      def definition do
        @events
      end

      # Default init - can be overridden
      # Receives params value from the scene (if true, returns empty map)
      # and dependencies map (e.g., %{lemons: %{count: 0}, water: %{count: 0}})
      def init(params, _dependencies) do
        if params == true do
          %{}
        else
          params
        end
      end

      # Default expose - can be overridden
      # Receives state and dependencies
      def expose(state, _dependencies) do
        state
      end

      defoverridable init: 2, expose: 2

      # GenServer callbacks
      def start_link(opts) do
        app_pid = Keyword.fetch!(opts, :app_pid)
        controller_name = Keyword.fetch!(opts, :controller_name)
        dependency_names = Keyword.get(opts, :dependency_names, [])
        params = Keyword.get(opts, :params, %{})

        GenServer.start_link(
          __MODULE__,
          {app_pid, controller_name, dependency_names, params}
        )
      end

      @impl true
      def init({app_pid, controller_name, dependency_names, params}) do
        # Initialize with empty dependencies - controllers should handle this gracefully
        initial_state = init(params, %{})

        # Register with the app as started
        GenServer.cast(app_pid, {:controller_started, controller_name, self()})

        {:ok,
         %{
           state: initial_state,
           app_pid: app_pid,
           controller_name: controller_name,
           dependency_names: dependency_names,
           dependencies: %{},
           dependents: [],
           params: params
         }, {:continue, :init_with_dependencies}}
      end

      @impl true
      def handle_continue(:init_with_dependencies, server_state) do
        # Now reinitialize with actual dependencies after all controllers are up
        dependencies =
          get_dependencies_state(server_state.app_pid, server_state.dependency_names)

        new_state = init(server_state.params, dependencies)

        server_state = %{server_state | state: new_state, dependencies: dependencies}

        # Notify app that this controller is fully initialized
        GenServer.cast(
          server_state.app_pid,
          {:controller_fully_initialized, server_state.controller_name}
        )

        {:noreply, server_state}
      end

      # Generate event handlers conditionally based on whether events are defined
      if length(unquote(events)) > 0 do
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

          # If state changed, notify all dependents directly
          if new_state != current_state do
            notify_dependents(server_state, new_state)
          end

          {:noreply, %{server_state | state: new_state}}
        end

        @impl true
        def handle_call({:event, event_name, event_params}, _from, server_state) do
          current_state = server_state.state

          # Call the event handler if it exists in our events list
          new_state =
            if event_name in @events do
              apply(__MODULE__, event_name, [current_state, event_params])
            else
              current_state
            end

          # If state changed, notify all dependents directly and trigger App re-evaluation
          if new_state != current_state do
            notify_dependents(server_state, new_state)

            # Notify app to re-evaluate on_when conditions for dependents (async to avoid deadlock)
            GenServer.cast(
              server_state.app_pid,
              {:controller_state_changed, server_state.controller_name}
            )
          end

          {:reply, new_state, %{server_state | state: new_state}}
        end
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
        if length(server_state.dependency_names) > 0 do
          dependencies =
            get_dependencies_state(server_state.app_pid, server_state.dependency_names)

          new_exposed_state = expose(server_state.state, dependencies)

          # If exposed state changed, notify dependents
          if new_exposed_state != server_state.state do
            notify_dependents(%{server_state | dependencies: dependencies}, new_exposed_state)
          end

          {:noreply, %{server_state | dependencies: dependencies, state: new_exposed_state}}
        else
          {:noreply, server_state}
        end
      end

      @impl true
      def handle_call({:subscribe_ui, assign_name}, {ui_pid, _}, server_state) do
        # Monitor the UI process
        Process.monitor(ui_pid)

        # Add UI to dependents list
        dependent = %{type: :ui, pid: ui_pid, assign_name: assign_name}
        new_dependents = [dependent | server_state.dependents]

        # Get current exposed state and events
        exposed_state = expose(server_state.state, server_state.dependencies)
        events = @events

        {:reply, {:ok, exposed_state, events}, %{server_state | dependents: new_dependents}}
      end

      @impl true
      def handle_cast({:add_dependent, type, pid, data}, server_state) do
        # Monitor the dependent process
        Process.monitor(pid)

        # Add to dependents list
        dependent = Map.merge(%{type: type, pid: pid}, data)
        new_dependents = [dependent | server_state.dependents]

        {:noreply, %{server_state | dependents: new_dependents}}
      end

      @impl true
      def handle_cast({:remove_dependent, pid}, server_state) do
        # Remove from dependents list
        new_dependents = Enum.reject(server_state.dependents, fn dep -> dep.pid == pid end)
        {:noreply, %{server_state | dependents: new_dependents}}
      end

      @impl true
      def handle_info({:DOWN, _ref, :process, pid, _reason}, server_state) do
        # Remove dependent when it terminates
        new_dependents = Enum.reject(server_state.dependents, fn dep -> dep.pid == pid end)
        {:noreply, %{server_state | dependents: new_dependents}}
      end

      defp get_dependencies_state(_app_pid, []), do: %{}

      defp get_dependencies_state(app_pid, dependency_names) do
        GenServer.call(app_pid, {:get_dependencies_state, dependency_names}, 100_000)
      end

      # Helper to notify all dependents of state change
      defp notify_dependents(server_state, new_state) do
        exposed_state = expose(new_state, server_state.dependencies)

        Enum.each(server_state.dependents, fn dependent ->
          case dependent.type do
            :ui ->
              send(dependent.pid, {
                :solve_update,
                dependent.assign_name,
                server_state.controller_name,
                exposed_state
              })

            :controller ->
              GenServer.cast(dependent.pid, :refresh_dependencies)
          end
        end)
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
                  "All events declared in `use Solve.Controller` must have a corresponding function."
          end
        end

        :ok
      end
    end
  end
end
