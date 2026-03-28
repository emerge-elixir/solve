defmodule Solve.DependencyUpdate do
  @moduledoc false

  @enforce_keys [:app, :key, :op]
  defstruct [:app, :key, :op, :id, :value, :ids]

  @type op :: :replace | :collection_put | :collection_delete | :collection_reorder

  @type t :: %__MODULE__{
          app: GenServer.server() | nil,
          key: atom(),
          op: op(),
          id: Solve.Collection.id() | nil,
          value: term(),
          ids: [Solve.Collection.id()] | nil
        }

  @spec replace(GenServer.server() | nil, atom(), term()) :: t()
  def replace(app, key, value) when is_atom(key) do
    %__MODULE__{app: app, key: key, op: :replace, value: value}
  end

  @spec collection_put(GenServer.server() | nil, atom(), Solve.Collection.id(), map()) :: t()
  def collection_put(app, key, id, value) when is_atom(key) and is_map(value) do
    %__MODULE__{app: app, key: key, op: :collection_put, id: id, value: value}
  end

  @spec collection_delete(GenServer.server() | nil, atom(), Solve.Collection.id()) :: t()
  def collection_delete(app, key, id) when is_atom(key) do
    %__MODULE__{app: app, key: key, op: :collection_delete, id: id}
  end

  @spec collection_reorder(GenServer.server() | nil, atom(), [Solve.Collection.id()]) :: t()
  def collection_reorder(app, key, ids) when is_atom(key) and is_list(ids) do
    %__MODULE__{app: app, key: key, op: :collection_reorder, ids: ids}
  end
end
