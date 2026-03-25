defmodule Solve.DependencyGraphTest do
  use ExUnit.Case, async: true

  alias Solve.DependencyGraph

  import Solve.ControllerSpec, only: [controller!: 1, collection: 1]

  defmodule RootController do
  end

  defmodule LeftController do
  end

  defmodule RightController do
  end

  defmodule LeafController do
  end

  defmodule AController do
  end

  defmodule BController do
  end

  defmodule CController do
  end

  defmodule CollectionController do
  end

  defmodule NoControllersModule do
  end

  defmodule InvalidControllersReturnModule do
    def controllers, do: :invalid
  end

  test "compile/1 returns an empty graph for empty specs" do
    assert {:ok,
            %{controller_specs_by_name: %{}, sorted_controller_names: [], dependents_map: %{}}} =
             DependencyGraph.compile([])
  end

  test "compile/1 builds dependency order and dependents for a chain" do
    specs = [
      controller!(name: :a, module: AController),
      controller!(name: :b, module: BController, dependencies: [:a]),
      controller!(name: :c, module: CController, dependencies: [:b])
    ]

    assert {:ok, graph} = DependencyGraph.compile(specs)

    assert graph.sorted_controller_names == [:a, :b, :c]

    assert graph.dependents_map == %{
             a: [:b],
             b: [:c],
             c: []
           }
  end

  test "compile/1 preserves dependency ordering across branches" do
    specs = [
      controller!(name: :root, module: RootController),
      controller!(name: :left, module: LeftController, dependencies: [:root]),
      controller!(name: :right, module: RightController, dependencies: [:root]),
      controller!(name: :leaf, module: LeafController, dependencies: [:left, :right])
    ]

    assert {:ok, graph} = DependencyGraph.compile(specs)

    assert_before(graph.sorted_controller_names, :root, :left)
    assert_before(graph.sorted_controller_names, :root, :right)
    assert_before(graph.sorted_controller_names, :left, :leaf)
    assert_before(graph.sorted_controller_names, :right, :leaf)

    assert sort_dependents(graph.dependents_map) == %{
             leaf: [],
             left: [:leaf],
             right: [:leaf],
             root: [:left, :right]
           }
  end

  test "compile/1 rejects duplicate controller names" do
    specs = [
      controller!(name: :counter, module: AController),
      controller!(name: :counter, module: BController)
    ]

    assert {:error, {:duplicate_controller, :counter}} = DependencyGraph.compile(specs)
  end

  test "compile/1 rejects unknown dependencies" do
    specs = [
      controller!(name: :counter, module: AController, dependencies: [:missing])
    ]

    assert {:error, {:unknown_dependency, :counter, :missing}} = DependencyGraph.compile(specs)
  end

  test "compile/1 rejects self dependencies" do
    specs = [
      controller!(name: :counter, module: AController, dependencies: [:counter])
    ]

    assert {:error, {:self_dependency, :counter}} = DependencyGraph.compile(specs)
  end

  test "compile/1 returns cycle information for cyclic dependencies" do
    specs = [
      controller!(name: :a, module: AController, dependencies: [:b]),
      controller!(name: :b, module: BController, dependencies: [:a])
    ]

    assert {:error, {:cycle, cycle}} = DependencyGraph.compile(specs)

    assert length(cycle) == 3
    assert hd(cycle) == List.last(cycle)
    assert MapSet.new(Enum.drop(cycle, -1)) == MapSet.new([:a, :b])
  end

  test "compile/1 builds edges from source names for collection bindings" do
    specs = [
      controller!(name: :board, module: RootController),
      controller!(
        name: :column,
        module: CollectionController,
        variant: :collection,
        dependencies: [:board],
        collect: fn _ctx -> [] end
      ),
      controller!(
        name: :summary,
        module: LeafController,
        dependencies: [columns: collection(:column)]
      )
    ]

    assert {:ok, graph} = DependencyGraph.compile(specs)

    assert_before(graph.sorted_controller_names, :board, :column)
    assert_before(graph.sorted_controller_names, :column, :summary)

    assert sort_dependents(graph.dependents_map) == %{
             board: [:column],
             column: [:summary],
             summary: []
           }
  end

  test "compile/1 rejects plain dependencies on collection sources" do
    specs = [
      controller!(
        name: :column,
        module: CollectionController,
        variant: :collection,
        collect: fn _ctx -> [] end
      ),
      controller!(
        name: :summary,
        module: LeafController,
        dependencies: [:column]
      )
    ]

    assert {:error, {:plain_dependency_on_collection, :summary, :column}} =
             DependencyGraph.compile(specs)
  end

  test "compile/1 rejects collection bindings to singleton sources" do
    specs = [
      controller!(name: :board, module: RootController),
      controller!(
        name: :summary,
        module: LeafController,
        dependencies: [columns: collection(:board)]
      )
    ]

    assert {:error, {:collection_dependency_on_singleton, :summary, :columns, :board}} =
             DependencyGraph.compile(specs)
  end

  test "resolve_module!/2 raises ArgumentError when controllers/0 is missing" do
    assert_raise ArgumentError, ~r/must implement controllers\/0/, fn ->
      DependencyGraph.resolve_module!(NoControllersModule)
    end
  end

  test "resolve_module!/2 raises CompileError when compile context is provided" do
    assert_raise CompileError, ~r/controllers\/0 must return a list of controller specs/, fn ->
      DependencyGraph.resolve_module!(InvalidControllersReturnModule,
        file: "test/support/invalid_graph.ex",
        line: 7
      )
    end
  end

  defp assert_before(sorted_controller_names, left, right) do
    assert Enum.find_index(sorted_controller_names, &(&1 == left)) <
             Enum.find_index(sorted_controller_names, &(&1 == right))
  end

  defp sort_dependents(dependents_map) do
    Map.new(dependents_map, fn {controller_name, dependents} ->
      {controller_name, Enum.sort(dependents)}
    end)
  end
end
