defmodule Solve.CollectionTest do
  use ExUnit.Case, async: true

  alias Solve.Collection

  test "empty/0 returns an empty collection" do
    assert Collection.empty() == %Collection{ids: [], items: %{}}
  end

  test "get/2 and fetch/2 read items by id" do
    collection = %Collection{
      ids: [2, 1],
      items: %{
        1 => %{title: "one"},
        2 => %{title: "two"}
      }
    }

    assert Collection.get(collection, 2) == %{title: "two"}
    assert Collection.get(collection, 3) == nil

    assert Collection.fetch(collection, 1) == {:ok, %{title: "one"}}
    assert Collection.fetch(collection, 3) == :error
  end

  test "to_list/1 follows ids order, not map order" do
    collection = %Collection{
      ids: [3, 1, 2],
      items: %{
        1 => %{title: "one"},
        2 => %{title: "two"},
        3 => %{title: "three"}
      }
    }

    assert Collection.to_list(collection) == [
             {3, %{title: "three"}},
             {1, %{title: "one"}},
             {2, %{title: "two"}}
           ]
  end

  test "Enumerable yields ordered {id, item} tuples" do
    collection = %Collection{
      ids: [2, 1],
      items: %{
        1 => %{title: "one"},
        2 => %{title: "two"}
      }
    }

    assert Enum.count(collection) == 2

    assert Enum.to_list(collection) == [
             {2, %{title: "two"}},
             {1, %{title: "one"}}
           ]

    assert Enum.map(collection, fn {id, item} -> {id, item.title} end) == [
             {2, "two"},
             {1, "one"}
           ]
  end

  test "Inspect prints ordered pairs" do
    collection = %Collection{
      ids: [2, 1],
      items: %{
        1 => %{title: "one"},
        2 => %{title: "two"}
      }
    }

    assert inspect(collection) ==
             "#Solve.Collection<[{2, %{title: \"two\"}}, {1, %{title: \"one\"}}]>"
  end
end
