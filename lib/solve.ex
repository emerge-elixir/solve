defmodule Solve do
  @moduledoc """
  Solve - A declarative state management architecture for Phoenix LiveView.

  Solve provides a clean separation between state management (Controllers),
  coordination (Solve), and presentation (LiveView). It enables dependency management
  between state containers with direct communication between all components.

  ## Architecture

  - **Controller**: A GenServer that manages state, handles events, and communicates
    directly with LiveViews and dependent controllers
  - **Solve**: A coordinator that manages controller lifecycle and dependency graph resolution
  - **LiveView**: A Phoenix LiveView that subscribes directly to controllers and dispatches events to them

  ## Communication Flow

  Controllers communicate directly with their dependents (LiveViews and other controllers),
  eliminating the need for a central routing hub. This provides:

  - Better performance (fewer GenServer hops)
  - Clearer separation of concerns
  - Improved scalability

  ## Responsibilities

  - Start controllers in dependency order
  - Resolve and validate dependency graphs at compile time
  - Notify dependencies when controllers are added as dependents
  - Provide controller PID lookup for LiveViews
  - (Future) Manage dynamic controller start/stop based on `on_when` conditions

  ## Quick Example

      # Define a controller
      defmodule MyApp.CounterController do
        use Solve.Controller, events: [:increment, :decrement]

        @impl true
        def init(_params, _dependencies) do
          %{count: 0}
        end

        def increment(state, _params), do: %{state | count: state.count + 1}
        def decrement(state, _params), do: %{state | count: state.count - 1}

        @impl true
        def expose(state, _dependencies), do: state
      end

      # Define a Solve scene
      defmodule MyApp do
        use Solve

        @impl true
        def scene(_params) do
          %{
            # Controller always starts (default params: fn _ -> true end)
            counter: MyApp.CounterController
          }
        end
      end

      # Define a LiveView
      defmodule MyAppWeb.CounterLive do
        use Solve.LiveView, scene: MyApp

        def init(_params) do
          %{counter: :counter}  # subscribe to :counter controller
        end

        def render(assigns) do
          ~H\"\"\"
          <div>
            <h1>Count: {@counter.count}</h1>
            <button phx-click={@counter.increment}>+</button>
            <button phx-click={@counter.decrement}>-</button>
          </div>
          \"\"\"
        end
      end

  ## Dependency Graph

  Solve validates the dependency graph at runtime and detects cycles:

      @impl true
      def scene(_params) do
        %{
          a: {ControllerA, dependencies: [:b]},
          b: {ControllerB, dependencies: [:a]}  # RuntimeError: Cyclic dependency
        }
      end

  ## Controller Naming

  Controllers are registered with atom names (`:lemons`, `:water`, etc.) that
  are used for:
  - Dependency references
  - LiveView subscriptions
  - Internal controller coordination

  ## Dynamic Controllers with `params`

  Controllers use the `params` option for dual purposes:
  1. Determine whether the controller should run
  2. Pass initialization data to the controller

  If `params` returns `nil` or `false`, the controller won't start.
  Any other value is passed to the controller's `init/2` function.

  ### Static Values

      @impl true
      def scene(_params) do
        %{
          base: BaseController,
          # Always start (default behavior)
          enabled: {EnabledController,
            dependencies: [:base],
            params: fn _ -> true end
          },
          # Never start (useful for feature flags)
          disabled: {DisabledController,
            dependencies: [:base],
            params: fn _ -> false end
          }
        }
      end

  ### Passing Data and Conditional Starting

  Use a function to pass data and control when a controller should run:

      @impl true
      def scene(params) do
        %{
          # Pass user from scene params
          current_user: {CurrentUserController,
            params: fn _ -> params[:current_user] end
          },
          # Only run when temperature is above freezing
          sprinkler: {SprinklerController,
            dependencies: [:temperature],
            params: fn deps ->
              if deps[:temperature].celsius > 0 do
                %{threshold: 0}
              else
                nil  # Don't start
              end
            end
          }
        }
      end

  In the controller, you receive the params value:

      def init(current_user, _dependencies) do
        # If controller is running, current_user is guaranteed to be truthy
        %{current_user: current_user}
      end

  When a dependency's state changes, all dependent controllers with function-based
  `params` are re-evaluated. Controllers automatically start when their params
  returns a truthy value and stop when it returns `nil` or `false`.

  **Note**: The function receives a map of dependency names to their exposed states,
  allowing you to make decisions based on the current state of your dependencies.

  ## Multiple Scenes with Pattern Matching

  You can define multiple scene clauses with different patterns to configure
  controllers based on runtime params:

      defmodule MyApp do
        use Solve

        @impl true
        # Scene for logged-out users
        def scene(%{current_user: nil}) do
          %{auth: AuthController}
        end

        # Scene for logged-in users
        def scene(%{current_user: _user}) do
          %{
            current_user: CurrentUserController,
            dashboard: DashboardController
          }
        end
      end

  At runtime, the first matching pattern will be used to determine which controllers to start.

  See `MULTIPLE_SCENES_FEATURE.md` for comprehensive documentation.

  ## Features

  - Declarative state management with direct communication
  - Multiple scene patterns for conditional controller configurations
  - Dependency resolution between controllers
  - Automatic state propagation to LiveViews and dependent controllers
  - Type-safe event handling
  - Compile-time dependency cycle detection
  - Process monitoring and automatic cleanup
  """

  @doc """
  Callback to define the scene based on params.

  Implement this function with pattern matching to return different controller
  configurations based on the params.

  Returns a map where keys are controller names and values are either:
  - A module atom: `%{counter: CounterController}`
  - A tuple `{module, opts}`: `%{user: {UserController, params: fn _ -> params[:user] end}}`

  ## Examples

      def scene(%{current_user: nil}) do
        %{auth: AuthController}
      end

      def scene(%{current_user: user}) do
        %{
          current_user: {CurrentUserController, params: fn _ -> user end},
          dashboard: DashboardController
        }
      end
  """
  @callback scene(params :: map()) :: map()

  defmacro __using__(_opts) do
    quote do
      @behaviour Solve
      @behaviour GenServer

      @before_compile Solve

      def start_link(opts \\ []) do
        # Allow custom naming via :name option and params via :params option
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      # Helper to convert controller map from scene/1 into internal format
      defp controllers_from_scene(params) do
        params
        |> scene()
        |> Enum.into(%{}, fn {name, controller_spec} ->
          # Parse controller spec - can be either Module or {Module, opts}
          {module, opts} =
            case controller_spec do
              {mod, opts} when is_atom(mod) and is_list(opts) -> {mod, opts}
              mod when is_atom(mod) -> {mod, []}
              _ -> raise "Invalid controller spec for #{name}: #{inspect(controller_spec)}"
            end

          config = %{
            module: module,
            dependencies: Keyword.get(opts, :dependencies, []),
            params: Keyword.get(opts, :params, fn _deps -> true end),
            after_action: Keyword.get(opts, :after_action, fn socket, _state -> socket end)
          }

          {name, config}
        end)
      end

      @impl true
      def init(opts) do
        # Extract params from opts (passed from LiveView)
        params = Keyword.get(opts, :params, %{})

        # Get controllers from scene/1 function
        controllers = controllers_from_scene(params)

        # Sort controllers by dependency order
        {:ok, sorted_controller_names} = Solve.DependencyGraph.topological_sort(controllers)

        # Build dependents map
        dependents_map = Solve.DependencyGraph.build_dependents_map(controllers)

        # Initialize controllers state (but don't start them yet)
        controllers_state =
          Enum.reduce(sorted_controller_names, %{}, fn controller_name, acc ->
            controller_config = Map.get(controllers, controller_name, %{})
            controller_module = Map.fetch!(controller_config, :module)
            dependency_names = Map.get(controller_config, :dependencies, [])
            params_fn = Map.get(controller_config, :params, fn _deps -> true end)

            after_action =
              Map.get(controller_config, :after_action, fn socket, _state -> socket end)

            Map.put(acc, controller_name, %{
              pid: nil,
              module: controller_module,
              name: controller_name,
              dependencies: dependency_names,
              dependents: Map.get(dependents_map, controller_name, []),
              params_fn: params_fn,
              after_action: after_action,
              status: :stopped
            })
          end)

        # Start controllers in dependency order, evaluating on_when conditions
        controllers_state =
          Enum.reduce(sorted_controller_names, controllers_state, fn controller_name, acc ->
            start_controller_if_ready(controller_name, acc, params)
          end)

        # Notify dependencies about their dependents (only for running controllers)
        Enum.each(sorted_controller_names, fn controller_name ->
          controller_info = Map.get(controllers_state, controller_name)

          if controller_info.status == :running do
            dependency_names = controller_info.dependencies

            # Tell each dependency that this controller depends on it
            Enum.each(dependency_names, fn dep_name ->
              dep_info = controllers_state[dep_name]

              if dep_info && dep_info.status == :running do
                GenServer.cast(dep_info.pid, {
                  :add_dependent,
                  :controller,
                  controller_info.pid,
                  %{name: controller_name}
                })
              end
            end)
          end
        end)

        {:ok,
         %{
           controllers: controllers_state,
           dependency_graph: controllers,
           fully_initialized: MapSet.new(),
           scene_params: params
         }}
      end

      @impl true
      def handle_cast({:controller_started, controller_name, _pid}, state) do
        # Controller has finished basic initialization
        {:noreply, state}
      end

      @impl true
      def handle_cast({:controller_fully_initialized, controller_name}, state) do
        # Mark controller as fully initialized
        new_fully_initialized = MapSet.put(state.fully_initialized, controller_name)
        new_state = %{state | fully_initialized: new_fully_initialized}

        # Re-evaluate dependents of this controller
        controller_info = new_state.controllers[controller_name]

        if controller_info do
          final_state =
            Enum.reduce(controller_info.dependents, new_state, fn dependent_name, acc ->
              # Check if all dependencies of the dependent are fully initialized
              dependent_info = acc.controllers[dependent_name]

              all_deps_ready =
                Enum.all?(dependent_info.dependencies, fn dep_name ->
                  MapSet.member?(acc.fully_initialized, dep_name)
                end)

              # Check if it's a function-based params (stored as AST)
              should_evaluate =
                case dependent_info.params_fn do
                  {:ast, _} -> true
                  params_fn when is_function(params_fn, 1) -> true
                  _ -> false
                end

              if all_deps_ready && should_evaluate do
                re_evaluate_controller(dependent_name, acc)
              else
                acc
              end
            end)

          {:noreply, final_state}
        else
          {:noreply, new_state}
        end
      end

      @impl true
      def handle_call({:get_dependencies_state, dependency_names}, _from, state) do
        # Build a map of dependency states

        dependencies_state =
          Enum.into(dependency_names, %{}, fn dep_name ->
            controller_info = state.controllers[dep_name]

            if controller_info do
              exposed_state = GenServer.call(controller_info.pid, :get_exposed_state, 100_000)
              {dep_name, exposed_state}
            else
              {dep_name, %{}}
            end
          end)

        {:reply, dependencies_state, state}
      end

      @impl true
      def handle_call({:fetch_controller_pid, controller_name}, _from, state) do
        controller_info = state.controllers[controller_name]

        pid =
          if controller_info && controller_info.status == :running do
            controller_info.pid
          end

        {:reply, pid, state}
      end

      @impl true
      def handle_call({:apply_after_action, controller_name, socket, exposed_state}, _from, state) do
        controller_info = state.controllers[controller_name]

        updated_socket =
          if controller_info do
            controller_info.after_action.(socket, exposed_state)
          else
            socket
          end

        {:reply, updated_socket, state}
      end

      @impl true
      def handle_cast({:controller_state_changed, controller_name}, state) do
        controller_info = state.controllers[controller_name]

        if controller_info do
          new_state =
            Enum.reduce(controller_info.dependents, state, fn dependent_name, acc ->
              re_evaluate_controller(dependent_name, acc)
            end)

          {:noreply, new_state}
        else
          {:noreply, state}
        end
      end

      defp start_controller_if_ready(controller_name, controllers_state, app_params) do
        controller_info = controllers_state[controller_name]

        # Check if already running
        if controller_info.status == :running do
          controllers_state
        else
          # Check if dependencies are satisfied
          deps_satisfied =
            Enum.all?(controller_info.dependencies, fn dep_name ->
              dep = controllers_state[dep_name]
              dep && dep.status == :running
            end)

          if deps_satisfied do
            # For function-based params with dependencies, skip starting during initial load
            # It will be evaluated after dependencies fully initialize
            # But if controller has no dependencies, evaluate immediately
            has_no_dependencies = Enum.empty?(controller_info.dependencies)

            case controller_info.params_fn do
              {:ast, _} when not has_no_dependencies ->
                # Function-based with dependencies, skip for now
                controllers_state

              _ ->
                # Static value or no dependencies, evaluate now
                params_value =
                  evaluate_params_fn(
                    controller_info.params_fn,
                    controller_info.dependencies,
                    controllers_state,
                    app_params
                  )

                # Start controller if params is not nil or false
                if params_value != nil && params_value != false do
                  start_controller(controller_name, controllers_state, app_params, params_value)
                else
                  controllers_state
                end
            end
          else
            controllers_state
          end
        end
      end

      defp start_controller(controller_name, controllers_state, app_params, params_value \\ nil) do
        controller_info = controllers_state[controller_name]

        # If params_value not provided, evaluate it
        controller_params =
          if params_value == nil do
            evaluate_params_fn(
              controller_info.params_fn,
              controller_info.dependencies,
              controllers_state,
              app_params
            )
          else
            params_value
          end

        {:ok, pid} =
          controller_info.module.start_link(
            app_pid: self(),
            controller_name: controller_name,
            dependency_names: controller_info.dependencies,
            params: controller_params
          )

        updated_info = %{controller_info | pid: pid, status: :running}
        updated_state = Map.put(controllers_state, controller_name, updated_info)

        # Notify dependencies that this controller is now a dependent
        Enum.each(controller_info.dependencies, fn dep_name ->
          dep_info = updated_state[dep_name]

          if dep_info && dep_info.status == :running do
            GenServer.cast(dep_info.pid, {
              :add_dependent,
              :controller,
              pid,
              %{name: controller_name}
            })
          end
        end)

        updated_state
      end

      defp stop_controller(controller_name, controllers_state) do
        controller_info = controllers_state[controller_name]

        if controller_info.status == :running && controller_info.pid do
          # Notify dependencies to remove this controller as dependent
          Enum.each(controller_info.dependencies, fn dep_name ->
            dep_info = controllers_state[dep_name]

            if dep_info && dep_info.status == :running do
              GenServer.cast(dep_info.pid, {:remove_dependent, controller_info.pid})
            end
          end)

          # Stop the controller process gracefully (async to avoid blocking)
          if Process.alive?(controller_info.pid) do
            Process.exit(controller_info.pid, :normal)
          end

          # Update state
          updated_info = %{controller_info | pid: nil, status: :stopped}
          Map.put(controllers_state, controller_name, updated_info)
        else
          controllers_state
        end
      end

      defp re_evaluate_controller(controller_name, state) do
        controller_info = state.controllers[controller_name]
        # Check if dependencies are satisfied
        deps_satisfied =
          Enum.all?(controller_info.dependencies, fn dep_name ->
            dep = state.controllers[dep_name]
            dep && dep.status == :running
          end)

        if deps_satisfied do
          # Evaluate params function
          params_value =
            evaluate_params_fn(
              controller_info.params_fn,
              controller_info.dependencies,
              state.controllers,
              state.scene_params
            )

          # Start if params is truthy, stop if nil or false
          should_be_running = params_value != nil && params_value != false

          cond do
            should_be_running && controller_info.status == :stopped ->
              # Start the controller with the params value
              updated_controllers =
                start_controller(
                  controller_name,
                  state.controllers,
                  state.scene_params,
                  params_value
                )

              %{state | controllers: updated_controllers}

            !should_be_running && controller_info.status == :running ->
              # Stop the controller
              updated_controllers = stop_controller(controller_name, state.controllers)
              %{state | controllers: updated_controllers}

            true ->
              # No change needed
              state
          end
        else
          # Dependencies not satisfied, stop if running
          if controller_info.status == :running do
            updated_controllers = stop_controller(controller_name, state.controllers)
            %{state | controllers: updated_controllers}
          else
            state
          end
        end
      end

      defp evaluate_params_fn(params_fn, dependency_names, controllers_state, app_params) do
        # Build dependencies map with exposed states
        dependencies =
          Enum.into(dependency_names, %{}, fn dep_name ->
            dep_info = controllers_state[dep_name]

            if dep_info && dep_info.status == :running do
              exposed_state = GenServer.call(dep_info.pid, :get_exposed_state)
              {dep_name, exposed_state}
            else
              {dep_name, nil}
            end
          end)

        case params_fn do
          {:ast, ast} ->
            # Evaluate the AST to get the function, with params bound
            {fn_value, _} = Code.eval_quoted(ast, params: app_params)
            fn_value.(dependencies)

          fn_value when is_function(fn_value, 1) ->
            fn_value.(dependencies)

          _ ->
            %{}
        end
      end
    end
  end
end
