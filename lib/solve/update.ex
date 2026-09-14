defmodule Solve.Update do
  @moduledoc """
  Update payload used in `%Solve.Message{type: :update}` envelopes.
  """

  @type controller_name :: atom() | {atom(), Solve.Collection.id()}

  @enforce_keys [:app, :controller_name, :exposed_state]
  defstruct [
    :app,
    :controller_name,
    :exposed_state,
    :version,
    :pid,
    :events,
    :routes,
    kind: :item
  ]

  @type version :: {non_neg_integer(), non_neg_integer()} | nil

  @type t :: %__MODULE__{
          app: GenServer.server() | nil,
          controller_name: controller_name(),
          exposed_state: term(),
          version: version(),
          pid: pid() | nil,
          events: [atom()] | nil,
          routes: map() | nil,
          kind: :item | :collection
        }

  @doc false
  @spec newer?(version(), version()) :: boolean()
  def newer?(nil, nil), do: true

  def newer?({generation, revision}, previous)
      when is_integer(generation) and generation >= 0 and is_integer(revision) and revision >= 0 do
    previous == nil or {generation, revision} > previous
  end

  def newer?(_version, _previous), do: false

  @doc false
  @spec message(t()) :: Solve.Message.t()
  def message(update), do: %Solve.Message{type: :update, payload: update}

  @spec new(GenServer.server() | nil, controller_name(), term()) :: t()
  def new(app, controller_name, exposed_state)
      when is_atom(controller_name) or is_tuple(controller_name) do
    %__MODULE__{app: app, controller_name: controller_name, exposed_state: exposed_state}
  end
end
