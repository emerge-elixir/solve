defmodule Solve.AuditRegressionTest do
  use ExUnit.Case, async: false

  alias Solve.Collection

  defmodule Value do
    use Solve.Controller, events: [:set]
    @impl true
    def init(params, _dependencies), do: Map.take(params, [:value])
    def set(value), do: %{value: value}
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "collection identity and membership use exact comparisons" do
    collection = Collection.empty() |> Collection.put(1, :integer) |> Collection.put(1.0, :float)
    assert Collection.delete(collection, 1.0) == %Collection{ids: [1], items: %{1 => :integer}}
    refute Enum.member?(Collection.empty(), {:absent, nil})
    refute Enum.member?(Collection.put(Collection.empty(), :key, 1), {:key, 1.0})
    assert Enum.member?(Collection.put(Collection.empty(), :key, nil), {:key, nil})
  end

  test "reorder rejects missing, duplicate and omitted ids at the boundary" do
    collection = Collection.put(Collection.empty(), :a, %{})

    for ids <- [[:missing], [:a, :a], []] do
      assert_raise ArgumentError, fn -> Collection.reorder(collection, ids) end
    end
  end

  test "pre-populated bindings cannot hide self or unknown graph edges" do
    for {source, reason} <- [
          a: {:self_dependency, :a},
          missing: {:unknown_dependency, :a, :missing}
        ] do
      spec =
        Solve.ControllerSpec.controller!(
          name: :a,
          module: Value,
          dependency_bindings: [%{key: :dep, source: source, kind: :single, filter: nil}]
        )

      assert Solve.DependencyGraph.compile([spec]) == {:error, reason}
    end
  end

  test "managed dependencies ignore older revisions, generations and unversioned messages" do
    {:ok, controller} =
      Value.start_link(
        solve_app: self(),
        params: %{value: 0},
        generation: 10,
        dependencies: %{source: %{value: 1}},
        dependency_versions: %{source: {4, 1}}
      )

    on_exit(fn -> Process.exit(controller, :kill) end)
    send(controller, Solve.DependencyUpdate.replace(self(), :source, %{value: 2}, {5, 0}))

    for version <- [{4, 99}, {5, 0}, nil] do
      send(controller, Solve.DependencyUpdate.replace(self(), :source, %{value: 999}, version))
    end

    assert :sys.get_state(controller).dependencies.source == %{value: 2}
    send(controller, Solve.DependencyUpdate.replace(self(), :source, %{value: 3}, {5, 1}))
    assert :sys.get_state(controller).dependencies.source == %{value: 3}
  end

  test "graph canonicalization is idempotent and rejects inconsistent or cyclic bindings" do
    import Solve.ControllerSpec
    a = controller!(name: :a, module: Value)
    b = controller!(name: :b, module: Value, dependencies: [:a])
    assert {:ok, normalized} = Solve.ControllerSpec.validate(b)
    assert Solve.ControllerSpec.validate(normalized) == {:ok, normalized}

    assert {:error, {:inconsistent_dependency_sources, :b}} =
             Solve.ControllerSpec.validate(%{normalized | dependencies: [:wrong]})

    circular = %{a | dependency_bindings: [%{key: :b, source: :b, kind: :single, filter: nil}]}
    assert {:error, {:cycle, _}} = Solve.DependencyGraph.compile([circular, normalized])
  end

  test "bulk collections and operation sequences preserve exact ordered keys" do
    assert_raise ArgumentError, fn -> Collection.new(a: 1, a: 2) end
    entries = for id <- [1, 1.0, nil, false, :a, {:tuple, 1}], do: {id, %{id: id}}
    initial = Collection.new(entries)
    assert Collection.to_list(initial) === entries

    Enum.reduce(1..100, initial, fn step, collection ->
      id = Enum.at(initial.ids, rem(step, length(initial.ids)))
      next = collection |> Collection.delete(id) |> Collection.put(id, %{step: step})
      next = Collection.reorder(next, Enum.reverse(next.ids))
      assert MapSet.new(next.ids) == MapSet.new(Map.keys(next.items))
      assert length(next.ids) == map_size(next.items)
      assert Enum.to_list(next) == Enum.map(next.ids, &{&1, Map.fetch!(next.items, &1)})
      next
    end)
  end
end
