defmodule Solve.DependencyGraph do
  @moduledoc """
  Compiles controller specs into dependency graph data.
  """

  alias Solve.ControllerSpec

  @type compiled_graph :: %{
          controller_specs_by_name: %{ControllerSpec.name() => ControllerSpec.t()},
          sorted_controller_names: [ControllerSpec.name()],
          dependents_map: %{ControllerSpec.name() => [ControllerSpec.name()]}
        }

  @spec resolve_module!(module(), keyword()) :: compiled_graph()
  def resolve_module!(module, opts \\ []) do
    with :ok <- ensure_controllers_callback(module),
         {:ok, controller_specs} <- ControllerSpec.validate_many(module.controllers()),
         {:ok, dependency_graph} <- compile(controller_specs) do
      dependency_graph
    else
      {:error, reason} ->
        raise_invalid_graph!(module, reason, opts)
    end
  rescue
    error in CompileError ->
      reraise error, __STACKTRACE__

    error ->
      raise_resolution_error!(module, error, opts)
  end

  @spec compile([ControllerSpec.t()]) :: {:ok, compiled_graph()} | {:error, term()}
  def compile(controller_specs) when is_list(controller_specs) do
    with {:ok, controller_specs_by_name} <- index_controller_specs(controller_specs),
         :ok <- validate_dependency_references(controller_specs_by_name),
         :ok <- validate_self_dependencies(controller_specs_by_name),
         {:ok, sorted_controller_names} <- topological_sort(controller_specs_by_name) do
      {:ok,
       %{
         controller_specs_by_name: controller_specs_by_name,
         sorted_controller_names: sorted_controller_names,
         dependents_map: build_dependents_map(controller_specs_by_name)
       }}
    end
  end

  def compile(other), do: {:error, {:invalid_controller_specs, other}}

  defp ensure_controllers_callback(module) do
    if function_exported?(module, :controllers, 0) do
      :ok
    else
      {:error, :missing_controllers_callback}
    end
  end

  defp raise_invalid_graph!(module, reason, opts) do
    case Keyword.fetch(opts, :file) do
      {:ok, file} ->
        raise CompileError,
          file: file,
          line: Keyword.get(opts, :line, 1),
          description: format_error(module, reason)

      :error ->
        raise ArgumentError, format_error(module, reason)
    end
  end

  defp raise_resolution_error!(module, error, opts) do
    description =
      "unable to validate controller graph for #{inspect(module)}: " <> Exception.message(error)

    case Keyword.fetch(opts, :file) do
      {:ok, file} ->
        raise CompileError,
          file: file,
          line: Keyword.get(opts, :line, 1),
          description: description

      :error ->
        raise ArgumentError, description
    end
  end

  defp format_error(module, :missing_controllers_callback) do
    "#{inspect(module)} must implement controllers/0"
  end

  defp format_error(module, {:invalid_controllers_return, value}) do
    "invalid controller graph in #{inspect(module)}: controllers/0 must return a list of controller specs, got #{inspect(value)}"
  end

  defp format_error(module, {:invalid_controller_spec, spec}) do
    "invalid controller graph in #{inspect(module)}: expected %Solve.ControllerSpec{} or controller!(...), got #{inspect(spec)}"
  end

  defp format_error(module, {:invalid_controller_name, name}) do
    "invalid controller graph in #{inspect(module)}: controller names must be atoms, got #{inspect(name)}"
  end

  defp format_error(module, {:invalid_controller_module, name, value}) do
    "invalid controller graph in #{inspect(module)}: controller #{inspect(name)} must reference a module atom, got #{inspect(value)}"
  end

  defp format_error(module, {:duplicate_controller, name}) do
    "invalid controller graph in #{inspect(module)}: duplicate controller #{inspect(name)}"
  end

  defp format_error(module, {:invalid_dependencies, name, dependencies}) do
    "invalid controller graph in #{inspect(module)}: controller #{inspect(name)} dependencies must be a list of atoms, got #{inspect(dependencies)}"
  end

  defp format_error(module, {:duplicate_dependency, controller, dependency}) do
    "invalid controller graph in #{inspect(module)}: controller #{inspect(controller)} lists dependency #{inspect(dependency)} more than once"
  end

  defp format_error(module, {:unknown_dependency, controller, dependency}) do
    "invalid controller graph in #{inspect(module)}: controller #{inspect(controller)} depends on unknown controller #{inspect(dependency)}"
  end

  defp format_error(module, {:self_dependency, controller}) do
    "invalid controller graph in #{inspect(module)}: controller #{inspect(controller)} cannot depend on itself"
  end

  defp format_error(module, {:cycle, cycle}) when is_list(cycle) and cycle != [] do
    "invalid controller graph in #{inspect(module)}: cyclic dependencies detected: " <>
      Enum.map_join(cycle, " -> ", &inspect/1)
  end

  defp format_error(module, {:cycle, _cycle}) do
    "invalid controller graph in #{inspect(module)}: cyclic dependencies detected"
  end

  defp format_error(module, {:invalid_controller_specs, value}) do
    "invalid controller graph in #{inspect(module)}: expected a list of %Solve.ControllerSpec{}, got #{inspect(value)}"
  end

  defp format_error(module, reason) do
    "invalid controller graph in #{inspect(module)}: #{inspect(reason)}"
  end

  defp build_dependents_map(controller_specs_by_name) when is_map(controller_specs_by_name) do
    initial_dependents_map = Map.new(Map.keys(controller_specs_by_name), &{&1, []})

    Enum.reduce(controller_specs_by_name, initial_dependents_map, fn {controller_name, spec},
                                                                     acc ->
      Enum.reduce(spec.dependencies, acc, fn dependency_name, acc_inner ->
        Map.update!(acc_inner, dependency_name, &[controller_name | &1])
      end)
    end)
  end

  defp find_cycle(controller_specs_by_name) when is_map(controller_specs_by_name) do
    controller_specs_by_name
    |> Map.keys()
    |> Enum.find_value([], fn controller_name ->
      case do_find_cycle(
             controller_name,
             controller_specs_by_name,
             MapSet.new(),
             [],
             MapSet.new()
           ) do
        {:cycle, cycle, _visited} -> cycle
        {:ok, _visited} -> nil
      end
    end)
  end

  defp index_controller_specs(controller_specs) do
    Enum.reduce_while(controller_specs, {:ok, %{}}, fn
      %ControllerSpec{name: name} = controller_spec, {:ok, acc} ->
        if Map.has_key?(acc, name) do
          {:halt, {:error, {:duplicate_controller, name}}}
        else
          {:cont, {:ok, Map.put(acc, name, controller_spec)}}
        end

      controller_spec, {:ok, _acc} ->
        {:halt, {:error, {:invalid_controller_spec, controller_spec}}}
    end)
  end

  defp validate_dependency_references(controller_specs_by_name) do
    Enum.reduce_while(controller_specs_by_name, :ok, fn {controller_name, controller_spec}, :ok ->
      case Enum.find(
             controller_spec.dependencies,
             &(not Map.has_key?(controller_specs_by_name, &1))
           ) do
        nil ->
          {:cont, :ok}

        dependency_name ->
          {:halt, {:error, {:unknown_dependency, controller_name, dependency_name}}}
      end
    end)
  end

  defp validate_self_dependencies(controller_specs_by_name) do
    Enum.reduce_while(controller_specs_by_name, :ok, fn {controller_name, controller_spec}, :ok ->
      if controller_name in controller_spec.dependencies do
        {:halt, {:error, {:self_dependency, controller_name}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp topological_sort(controller_specs_by_name) do
    dependents_map = build_dependents_map(controller_specs_by_name)
    in_degrees = build_in_degrees(controller_specs_by_name)

    case kahn_algorithm(dependents_map, in_degrees, Map.keys(controller_specs_by_name)) do
      {:ok, sorted_controller_names} -> {:ok, sorted_controller_names}
      {:error, :cycle} -> {:error, {:cycle, find_cycle(controller_specs_by_name)}}
    end
  end

  defp build_in_degrees(controller_specs_by_name) do
    Enum.into(controller_specs_by_name, %{}, fn {controller_name, controller_spec} ->
      {controller_name, length(controller_spec.dependencies)}
    end)
  end

  defp kahn_algorithm(dependents_map, in_degrees, all_nodes) do
    initial_queue =
      in_degrees
      |> Enum.filter(fn {_node, degree} -> degree == 0 end)
      |> Enum.map(fn {node, _degree} -> node end)

    process_queue(initial_queue, dependents_map, in_degrees, all_nodes, [])
  end

  defp process_queue([], _dependents_map, _in_degrees, all_nodes, result) do
    if length(result) == length(all_nodes) do
      {:ok, Enum.reverse(result)}
    else
      {:error, :cycle}
    end
  end

  defp process_queue([node | rest], dependents_map, in_degrees, all_nodes, result) do
    new_in_degrees = Map.delete(in_degrees, node)
    dependents = Map.get(dependents_map, node, [])

    {new_queue, updated_in_degrees} =
      Enum.reduce(dependents, {rest, new_in_degrees}, fn dependent, {queue, degrees} ->
        case Map.get(degrees, dependent) do
          nil ->
            {queue, degrees}

          degree ->
            new_degree = degree - 1
            new_degrees = Map.put(degrees, dependent, new_degree)

            if new_degree == 0 do
              {queue ++ [dependent], new_degrees}
            else
              {queue, new_degrees}
            end
        end
      end)

    process_queue(new_queue, dependents_map, updated_in_degrees, all_nodes, [node | result])
  end

  defp do_find_cycle(node, controller_specs_by_name, visited, stack, stack_set) do
    cond do
      MapSet.member?(stack_set, node) ->
        {:cycle, cycle_from_stack(node, stack), visited}

      MapSet.member?(visited, node) ->
        {:ok, visited}

      true ->
        visited = MapSet.put(visited, node)
        stack = [node | stack]
        stack_set = MapSet.put(stack_set, node)
        dependencies = controller_specs_by_name |> Map.fetch!(node) |> Map.get(:dependencies, [])

        Enum.reduce_while(dependencies, {:ok, visited}, fn dependency, {:ok, acc_visited} ->
          case do_find_cycle(dependency, controller_specs_by_name, acc_visited, stack, stack_set) do
            {:cycle, cycle, new_visited} -> {:halt, {:cycle, cycle, new_visited}}
            {:ok, new_visited} -> {:cont, {:ok, new_visited}}
          end
        end)
    end
  end

  defp cycle_from_stack(node, stack) do
    stack
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 != node))
    |> Kernel.++([node])
  end
end
