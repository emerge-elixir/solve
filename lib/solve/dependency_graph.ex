defmodule Solve.DependencyGraph do
  @moduledoc """
  Utilities for building and validating dependency graphs.
  """

  @doc """
  Performs topological sort on a dependency graph and detects cycles.

  ## Parameters
  - controllers: Map of controller modules to their config (including dependencies)

  ## Returns
  - `{:ok, sorted_list}` - Controllers in dependency order (dependencies first)
  - `{:error, :cycle}` - Cyclic dependency detected
  """
  def topological_sort(controllers) do
    # Build dependents map (reverse dependencies)
    dependents_map = build_dependents_map(controllers)
    # Build in-degrees (number of dependencies for each controller)
    in_degrees = build_in_degrees(controllers)

    case kahn_algorithm(dependents_map, in_degrees, Map.keys(controllers)) do
      {:ok, sorted} -> {:ok, sorted}
      {:error, :cycle} -> {:error, :cycle}
    end
  end

  @doc """
  Builds a map of dependents (reverse dependencies) for each controller.
  Used to know which controllers to notify when a dependency changes.
  """
  def build_dependents_map(controllers) do
    Enum.reduce(controllers, %{}, fn {controller, config}, acc ->
      dependencies = Map.get(config, :dependencies, [])

      # For each dependency, add this controller as a dependent
      Enum.reduce(dependencies, acc, fn dep, acc_inner ->
        Map.update(acc_inner, dep, [controller], fn existing ->
          [controller | existing]
        end)
      end)
    end)
  end

  # Private functions

  defp build_in_degrees(controllers) do
    # Build a map of how many dependencies each controller has (in-degree)
    Enum.into(controllers, %{}, fn {controller, config} ->
      dependencies = Map.get(config, :dependencies, [])
      {controller, length(dependencies)}
    end)
  end

  # Kahn's algorithm for topological sort with cycle detection
  defp kahn_algorithm(dependents_map, in_degrees, all_nodes) do
    # Find all nodes with no incoming edges (no dependencies)
    initial_queue =
      in_degrees
      |> Enum.filter(fn {_node, degree} -> degree == 0 end)
      |> Enum.map(fn {node, _} -> node end)

    process_queue(initial_queue, dependents_map, in_degrees, all_nodes, [])
  end

  defp process_queue([], _dependents_map, _in_degrees, all_nodes, result) do
    # If we've processed all nodes, success
    if length(result) == length(all_nodes) do
      {:ok, Enum.reverse(result)}
    else
      # Still have nodes left -> cycle detected
      {:error, :cycle}
    end
  end

  defp process_queue([node | rest], dependents_map, in_degrees, all_nodes, result) do
    # Remove this node
    new_in_degrees = Map.delete(in_degrees, node)

    # Get its dependents (nodes that depend on this node)
    dependents = Map.get(dependents_map, node, [])

    # Decrease in-degree of dependents, add to queue if they reach 0
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
end
