defmodule Solve.Update do
  @moduledoc """
  Update payload used in `%Solve.Message{type: :update}` envelopes.
  """

  @enforce_keys [:app, :controller_name, :exposed_state]
  defstruct [:app, :controller_name, :exposed_state]

  @type t :: %__MODULE__{
          app: GenServer.server() | nil,
          controller_name: atom(),
          exposed_state: term()
        }

  @spec new(GenServer.server() | nil, atom(), term()) :: t()
  def new(app, controller_name, exposed_state) when is_atom(controller_name) do
    %__MODULE__{app: app, controller_name: controller_name, exposed_state: exposed_state}
  end
end
