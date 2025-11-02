defmodule Bonseki.App do
  @moduledoc """
  A behavior and macro for defining Bonseki applications.

  An App is a GenServer that manages controller lifecycle and resolves
  dependency graphs. It does NOT route events or state updates - controllers
  communicate directly with their dependents.

  ## Responsibilities

  - Start controllers in dependency order
  - Resolve and validate dependency graphs at compile time
  - Notify dependencies when controllers are added as dependents
  - Provide controller PID lookup for UIs
  - (Future) Manage dynamic controller start/stop based on `on_when` conditions

  ## Example

      defmodule MyApp.App do
        use Bonseki.App

        scene do
          controller(:lemons, LemonController)
          controller(:water, WaterController)
          controller(:sugar, SugarController)

          controller(:lemonade, LemonadeController,
            dependencies: [:lemons, :water, :sugar]
          )
        end
      end

  ## Dependency Graph

  The App validates the dependency graph at compile time and detects cycles:

      scene do
        controller(:a, ControllerA, dependencies: [:b])
        controller(:b, ControllerB, dependencies: [:a])  # CompileError: Cyclic dependency
      end

  ## Controller Naming

  Controllers are registered with atom names (`:lemons`, `:water`, etc.) that
  are used for:
  - Dependency references
  - UI subscriptions
  - Internal controller coordination

  ## Dynamic Controllers with `on_when`

  Controllers can be started and stopped dynamically based on conditions using
  the `on_when` option:

  ### Static Conditions

      scene do
        controller(:base, BaseController)

        # Always start when dependencies are available
        controller(:enabled, EnabledController,
          dependencies: [:base],
          on_when: true
        )

        # Never start (useful for feature flags)
        controller(:disabled, DisabledController,
          dependencies: [:base],
          on_when: false
        )
      end

  ### Dynamic Conditions

  Use a function to determine if a controller should run based on dependency state:

      scene do
        controller(:temperature, TemperatureController)

        # Only run when temperature is above freezing
        controller(:sprinkler, SprinklerController,
          dependencies: [:temperature],
          on_when: fn deps ->
            deps[:temperature].celsius > 0
          end
        )

        # Only run when temperature is below threshold
        controller(:heater, HeaterController,
          dependencies: [:temperature],
          on_when: fn deps ->
            deps[:temperature].celsius < 18
          end
        )
      end

  When a dependency's state changes, all dependent controllers with function-based
  `on_when` conditions are re-evaluated. Controllers automatically start when their
  condition becomes true and stop when it becomes false.

  **Note**: The function receives a map of dependency names to their exposed states,
  allowing you to make decisions based on the current state of your dependencies.
  """

  defmacro __using__(_opts) do
    quote do
      use GenServer
      import Bonseki.App, only: [scene: 1, controller: 2, controller: 3, dependencies: 1]

      @controllers %{}

      def start_link(opts \\ []) do
        # Allow custom naming via :name option
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end
    end
  end

  @doc """
  Define a controller in the scene.

  This macro is intercepted by the `scene` macro and never actually evaluated.
  """
  defmacro controller(_name, _module) do
    # This is never actually called - scene intercepts the AST
    quote do: nil
  end

  @doc """
  Define a controller with options in the scene.

  This macro is intercepted by the `scene` macro and never actually evaluated.
  """
  defmacro controller(_name, _module, _opts) do
    # This is never actually called - scene intercepts the AST
    quote do: nil
  end

  @doc """
  Define dependencies for a controller (used in block form).
  """
  defmacro dependencies(_dep_list) do
    quote do: nil
  end

  @doc """
  Macro for defining a scene with controllers.
  """
  defmacro scene(do: block) do
    # Extract controllers at compile time
    env = __CALLER__
    controllers = Bonseki.App.__extract_controllers__(block, env)

    # Validate dependency graph at compile time
    case Bonseki.DependencyGraph.topological_sort(controllers) do
      {:ok, _sorted} ->
        :ok

      {:error, :cycle} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "Cyclic dependency detected in controller graph"
    end

    quote do
      @controllers unquote(Macro.escape(controllers))

      @impl true
      def init(opts) do
        # Sort controllers by dependency order
        {:ok, sorted_controller_names} = Bonseki.DependencyGraph.topological_sort(@controllers)

        # Build dependents map
        dependents_map = Bonseki.DependencyGraph.build_dependents_map(@controllers)

        # Initialize controllers state (but don't start them yet)
        controllers_state =
          Enum.reduce(sorted_controller_names, %{}, fn controller_name, acc ->
            controller_config = Map.get(@controllers, controller_name, %{})
            controller_module = Map.fetch!(controller_config, :module)
            on_when = Map.get(controller_config, :on_when, true)
            dependency_names = Map.get(controller_config, :dependencies, [])

            Map.put(acc, controller_name, %{
              pid: nil,
              module: controller_module,
              name: controller_name,
              dependencies: dependency_names,
              dependents: Map.get(dependents_map, controller_name, []),
              on_when: on_when,
              status: :stopped
            })
          end)

        # Start controllers in dependency order, evaluating on_when conditions
        controllers_state =
          Enum.reduce(sorted_controller_names, controllers_state, fn controller_name, acc ->
            start_controller_if_ready(controller_name, acc)
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
           dependency_graph: @controllers,
           fully_initialized: MapSet.new()
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

              # Check if it's a function-based on_when (stored as AST)
              should_evaluate =
                case dependent_info.on_when do
                  {:ast, _} -> true
                  condition_fn when is_function(condition_fn, 1) -> true
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

      defp start_controller_if_ready(controller_name, controllers_state) do
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
            # For function-based on_when, skip starting during initial load
            # It will be evaluated after dependencies fully initialize
            case controller_info.on_when do
              {:ast, _} ->
                # Function-based, skip for now
                controllers_state

              _ ->
                # Boolean value, evaluate now
                should_start =
                  evaluate_on_when(
                    controller_info.on_when,
                    controller_info.dependencies,
                    controllers_state
                  )

                if should_start do
                  start_controller(controller_name, controllers_state)
                else
                  controllers_state
                end
            end
          else
            controllers_state
          end
        end
      end

      defp start_controller(controller_name, controllers_state) do
        controller_info = controllers_state[controller_name]

        {:ok, pid} =
          controller_info.module.start_link(
            app_pid: self(),
            controller_name: controller_name,
            dependency_names: controller_info.dependencies
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
          # Evaluate on_when condition
          should_be_running =
            evaluate_on_when(
              controller_info.on_when,
              controller_info.dependencies,
              state.controllers
            )

          cond do
            should_be_running && controller_info.status == :stopped ->
              # Start the controller
              updated_controllers = start_controller(controller_name, state.controllers)
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

      defp evaluate_on_when(on_when, dependency_names, controllers_state) do
        case on_when do
          true ->
            true

          false ->
            false

          {:ast, ast} ->
            # Evaluate the AST to get the function
            {condition_fn, _} = Code.eval_quoted(ast)

            # Build dependencies map with exposed states
            dependencies =
              Enum.into(dependency_names, %{}, fn dep_name ->
                dep_info = controllers_state[dep_name]

                if dep_info && dep_info.status == :running do
                  exposed_state = GenServer.call(dep_info.pid, :get_exposed_state)
                  {dep_name, exposed_state}
                else
                  {dep_name, %{}}
                end
              end)

            condition_fn.(dependencies)

          condition_fn when is_function(condition_fn, 1) ->
            # Direct function (for cases where it's already evaluated)
            dependencies =
              Enum.into(dependency_names, %{}, fn dep_name ->
                dep_info = controllers_state[dep_name]

                if dep_info && dep_info.status == :running do
                  exposed_state = GenServer.call(dep_info.pid, :get_exposed_state)
                  {dep_name, exposed_state}
                else
                  {dep_name, %{}}
                end
              end)

            condition_fn.(dependencies)

          _ ->
            true
        end
      end
    end
  end

  @doc false
  def __extract_controllers__(block, env) do
    case block do
      {:__block__, _meta, expressions} ->
        Enum.reduce(expressions, %{}, fn expr, acc ->
          case extract_controller(expr, env) do
            {name, config} -> Map.put(acc, name, config)
            nil -> acc
          end
        end)

      single_expr ->
        case extract_controller(single_expr, env) do
          {name, config} -> %{name => config}
          nil -> %{}
        end
    end
  end

  # controller(:name, Module)
  defp extract_controller({:controller, _meta, [name, module_ast]}, env) when is_atom(name) do
    module = Macro.expand(module_ast, env)
    {name, %{module: module, dependencies: []}}
  end

  # controller(:name, Module, opts)
  defp extract_controller({:controller, _meta, [name, module_ast, opts]}, env)
       when is_atom(name) do
    module = Macro.expand(module_ast, env)

    # Parse options from AST
    config = parse_controller_opts(opts, env)
    config = Map.put(config, :module, module)

    {name, config}
  end

  # controller :name, Module do ... end (block form)
  defp extract_controller(
         {:controller, _meta, [name, module_ast, [do: block_content]]},
         env
       )
       when is_atom(name) do
    module = Macro.expand(module_ast, env)

    # Extract dependencies from block
    deps = extract_dependencies_from_block(block_content)

    {name, %{module: module, dependencies: deps}}
  end

  defp extract_controller(_, _env), do: nil

  # Extract dependencies from block content
  defp extract_dependencies_from_block({:dependencies, _meta, [deps_ast]}) do
    # Evaluate the deps AST to get actual list of atoms
    {deps_list, _} = Code.eval_quoted(deps_ast)
    deps_list
  end

  defp extract_dependencies_from_block({:__block__, _meta, expressions}) do
    Enum.find_value(expressions, [], fn
      {:dependencies, _meta, [deps_ast]} ->
        {deps_list, _} = Code.eval_quoted(deps_ast)
        deps_list

      _ ->
        nil
    end)
  end

  defp extract_dependencies_from_block(_), do: []

  # Parse controller options from AST
  defp parse_controller_opts(opts_ast, _env) when is_list(opts_ast) do
    # Keep AST for now, will be evaluated at runtime
    # Special handling for on_when functions
    Enum.into(opts_ast, %{}, fn {key, value_ast} ->
      case value_ast do
        # Boolean literals
        true -> {key, true}
        false -> {key, false}
        # Atoms (like dependency names)
        atom when is_atom(atom) -> {key, atom}
        # Numbers
        num when is_number(num) -> {key, num}
        # Strings
        str when is_binary(str) -> {key, str}
        # Lists
        list when is_list(list) -> {key, list}
        # Functions and complex expressions - store as AST
        {:fn, _, _} when key == :on_when -> {key, {:ast, value_ast}}
        # Other expressions for on_when
        _ when key == :on_when -> {key, {:ast, value_ast}}
        # Default
        _ -> {key, value_ast}
      end
    end)
  end

  defp parse_controller_opts(opts_ast, _env) do
    # Try to evaluate if it's a more complex expression
    case Code.eval_quoted(opts_ast, [], __ENV__) do
      {opts, _} when is_list(opts) -> Enum.into(opts, %{})
      _ -> %{}
    end
  end
end
