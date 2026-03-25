defmodule Solve.Collection do
  @moduledoc """
  Ordered keyed collection used by Solve collection sources, dependencies, and lookups.
  """

  @enforce_keys [:ids, :items]
  defstruct ids: [], items: %{}

  @type id :: term()

  @type t(item) :: %__MODULE__{
          ids: [id()],
          items: %{required(id()) => item}
        }

  @spec empty() :: t(any())
  def empty, do: %__MODULE__{ids: [], items: %{}}

  @spec get(t(item), id()) :: item | nil when item: var
  def get(%__MODULE__{items: items}, id), do: Map.get(items, id)

  @spec fetch(t(item), id()) :: {:ok, item} | :error when item: var
  def fetch(%__MODULE__{items: items}, id), do: Map.fetch(items, id)

  @spec to_list(t(item)) :: [{id(), item}] when item: var
  def to_list(%__MODULE__{ids: ids, items: items}) do
    Enum.map(ids, fn id -> {id, Map.fetch!(items, id)} end)
  end

  @spec put(t(item), id(), item) :: t(item) when item: var
  def put(%__MODULE__{} = collection, id, item) do
    ids = if id in collection.ids, do: collection.ids, else: collection.ids ++ [id]
    %__MODULE__{collection | ids: ids, items: Map.put(collection.items, id, item)}
  end

  @spec delete(t(item), id()) :: t(item) when item: var
  def delete(%__MODULE__{} = collection, id) do
    %__MODULE__{
      collection
      | ids: Enum.reject(collection.ids, &(&1 == id)),
        items: Map.delete(collection.items, id)
    }
  end

  @spec reorder(t(item), [id()]) :: t(item) when item: var
  def reorder(%__MODULE__{} = collection, ids) when is_list(ids) do
    %__MODULE__{collection | ids: ids}
  end

  defimpl Enumerable do
    def reduce(collection, acc, fun) do
      Enumerable.List.reduce(Solve.Collection.to_list(collection), acc, fun)
    end

    def member?(collection, {id, item}) do
      {:ok, Solve.Collection.get(collection, id) == item}
    end

    def member?(_collection, _value), do: {:ok, false}

    def count(%Solve.Collection{ids: ids}), do: {:ok, length(ids)}

    def slice(_collection), do: {:error, __MODULE__}
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(collection, opts) do
      concat([
        "#Solve.Collection<",
        to_doc(Solve.Collection.to_list(collection), opts),
        ">"
      ])
    end
  end
end
