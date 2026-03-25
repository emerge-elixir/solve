defmodule Solve.Message do
  @moduledoc """
  Envelope for Solve runtime messages exchanged between subscribers and controllers.
  """

  @enforce_keys [:type, :payload]
  defstruct [:type, :payload]

  @typedoc "Supported Solve message kinds"
  @type type :: :update | :dispatch

  @type payload :: Solve.Update.t() | Solve.Dispatch.t()

  @type t :: %__MODULE__{type: type(), payload: payload()}

  @spec update(GenServer.server() | nil, Solve.Update.controller_name(), term()) :: t()
  def update(app, controller_name, exposed_state)
      when is_atom(controller_name) or is_tuple(controller_name) do
    %__MODULE__{type: :update, payload: Solve.Update.new(app, controller_name, exposed_state)}
  end

  @spec dispatch(GenServer.server() | nil, Solve.Dispatch.controller_name(), atom(), term()) ::
          t()
  def dispatch(app, controller_name, event, payload \\ %{})
      when (is_atom(controller_name) or is_tuple(controller_name)) and is_atom(event) do
    %__MODULE__{
      type: :dispatch,
      payload: Solve.Dispatch.new(app, controller_name, event, payload)
    }
  end
end
