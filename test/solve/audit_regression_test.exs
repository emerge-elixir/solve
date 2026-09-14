defmodule Solve.AuditRegressionTest do
  use ExUnit.Case, async: false

  alias Solve.Collection

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
