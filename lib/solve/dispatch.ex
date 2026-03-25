defmodule Solve.Dispatch do
  @moduledoc """
  Dispatch payload used in `%Solve.Message{type: :dispatch}` envelopes.
  """

  @type controller_name :: atom() | {atom(), Solve.Collection.id()}

  @enforce_keys [:app, :controller_name, :event, :payload]
  defstruct [:app, :controller_name, :event, :payload]

  @type t :: %__MODULE__{
          app: GenServer.server() | nil,
          controller_name: controller_name(),
          event: atom(),
          payload: term()
        }

  @spec new(GenServer.server() | nil, controller_name(), atom(), term()) :: t()
  def new(app, controller_name, event, payload)
      when (is_atom(controller_name) or is_tuple(controller_name)) and is_atom(event) do
    %__MODULE__{app: app, controller_name: controller_name, event: event, payload: payload}
  end
end
