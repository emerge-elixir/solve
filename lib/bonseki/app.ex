defmodule Bonseki.App do
  @moduledoc """
  A behavior and macro for defining Bonseki applications.

  An App is a GenServer that coordinates controllers, resolves dependencies,
  and routes state updates to UIs.

  ## Example

      defmodule MyApp.App do
        use Bonseki.App

        scene do
          controller(LemonController)
          controller(WaterController)
          controller(SugarController)

          controller(LemonadeController,
            dependencies: [LemonController, WaterController, SugarController]
          )
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      use GenServer
      import Bonseki.App, only: [scene: 1, controller: 2, controller: 3, dependencies: 1]

      @controllers %{}

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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

        # Start controllers in dependency order
        controllers_state =
          Enum.reduce(sorted_controller_names, %{}, fn controller_name, acc ->
            controller_config = Map.get(@controllers, controller_name, %{})
            controller_module = Map.fetch!(controller_config, :module)
            params = Map.get(controller_config, :params, %{})
            on_when = Map.get(controller_config, :on_when, true)
            dependency_names = Map.get(controller_config, :dependencies, [])

            # Start the controller
            {:ok, pid} =
              controller_module.start_link(
                app_pid: self(),
                controller_name: controller_name,
                dependency_names: dependency_names
              )

            Map.put(acc, controller_name, %{
              pid: pid,
              module: controller_module,
              name: controller_name,
              dependencies: dependency_names,
              dependents: Map.get(dependents_map, controller_name, []),
              on_when: on_when,
              status: :running
            })
          end)

        {:ok,
         %{
           controllers: controllers_state,
           uis: [],
           dependency_graph: @controllers
         }}
      end

      @impl true
      def handle_cast({:controller_started, controller_name, _pid}, state) do
        # Controller has finished initialization
        {:noreply, state}
      end

      @impl true
      def handle_cast({:controller_state_changed, controller_name}, state) do
        IO.inspect("CONTROLLER STATE CHANGED", label: "CONTROLLER STATE CHANGED")
        IO.inspect(controller_name, label: "CONTROLLER NAME")
        IO.inspect(state, label: "STATE")
        # Get the new exposed state
        controller_info = state.controllers[controller_name]
        dbg(controller_info)

        if controller_info do
          exposed_state = GenServer.call(controller_info.pid, :get_exposed_state) |> dbg()

          # Notify all UIs subscribed to this controller
          notify_uis(state.uis, controller_name, exposed_state) |> dbg()

          # Also refresh dependents and notify their UIs

          Enum.each(controller_info.dependents, fn dependent_name ->
            GenServer.cast(state.controllers[dependent_name].pid, :refresh_dependencies) |> dbg()
          end)
        end

        {:noreply, state}
      end

      @impl true
      def handle_cast({:dispatch_event, controller_name, event_name, params}, state) do
        controller_info = state.controllers[controller_name]

        if controller_info do
          # Forward event to controller
          :ok =
            GenServer.cast(controller_info.pid, {:event, event_name, params})

          {:noreply, state}
        else
          {:noreply, state}
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
      def handle_call({:register_ui, ui_pid, subscriptions}, _from, state) do
        # Monitor the UI process
        Process.monitor(ui_pid)

        # Get initial state for each subscription
        initial_states =
          Enum.into(subscriptions, %{}, fn {assign_name, controller_name} ->
            IO.inspect(controller_name, label: "CONTROLLER NAME")
            IO.inspect(state.controllers, label: "STATE CONTROLLERS")
            controller_info = state.controllers[assign_name]
            IO.inspect(controller_info, label: "CONTROLLER INFO")

            if controller_info do
              exposed_state = GenServer.call(controller_info.pid, :get_exposed_state)
              IO.inspect(exposed_state, label: "EXPOSED STATE")
              events = controller_info.module.definition()
              {assign_name, {controller_name, exposed_state, events}}
            else
              {assign_name, {controller_name, %{}, []}}
            end
          end)

        ui_entry = %{
          pid: ui_pid,
          subscriptions: subscriptions
        }

        {:reply, {:ok, initial_states}, %{state | uis: [ui_entry | state.uis]}}
      end

      @impl true
      def handle_call({:unregister_ui, ui_pid}, _from, state) do
        new_uis = Enum.reject(state.uis, fn ui -> ui.pid == ui_pid end)
        {:reply, :ok, %{state | uis: new_uis}}
      end

      @impl true
      def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
        # Remove UI from registry when it terminates
        new_uis = Enum.reject(state.uis, fn ui -> ui.pid == pid end)
        {:noreply, %{state | uis: new_uis}}
      end

      defp notify_uis(uis, controller_name, exposed_state) do
        dbg(controller_name)
        dbg(exposed_state)

        Enum.each(uis, fn ui ->
          dbg(ui)
          # Check if this UI is subscribed to this controller
          subscribed_assigns =
            Enum.filter(ui.subscriptions, fn {assign_name, _} ->
              assign_name == controller_name
            end)

          dbg(subscribed_assigns)

          Enum.each(subscribed_assigns, fn {assign_name, _} ->
            dbg(assign_name)
            dbg(controller_name)
            dbg(exposed_state)
            send(ui.pid, {:bonseki_update, assign_name, controller_name, exposed_state}) |> dbg()
          end)
        end)
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
  defp parse_controller_opts(opts_ast, env) when is_list(opts_ast) do
    # It's already a list of tuples at compile time
    Enum.into(opts_ast, %{})
  end

  defp parse_controller_opts(opts_ast, _env) do
    # Try to evaluate if it's a more complex expression
    case Code.eval_quoted(opts_ast, [], __ENV__) do
      {opts, _} when is_list(opts) -> Enum.into(opts, %{})
      _ -> %{}
    end
  end

  # Expand module aliases in the dependencies list
  defp expand_dependencies(opts_ast, env) do
    Macro.prewalk(opts_ast, fn
      # Match module aliases (atoms that start with uppercase)
      {:__aliases__, _, _} = alias_ast ->
        Macro.expand(alias_ast, env)

      other ->
        other
    end)
  end
end
