defmodule Solve.ParamsTest do
  use ExUnit.Case, async: false

  defmodule UserController do
    use Solve.Controller, events: []

    @impl true
    def init(params, _dependencies) do
      %{user: params[:user], name: params[:name]}
    end

    @impl true
    def expose(state, _dependencies) do
      state
    end
  end

  defmodule ParamsSolve do
    use Solve

    @impl true
    def scene(params) do
      %{
        # Test passing params directly to a controller
        current_user: {Solve.ParamsTest.UserController, params: fn _ -> params end}
      }
    end
  end

  test "Solve params are accessible in controller params function" do
    user_data = %{id: 1, email: "test@example.com"}
    {:ok, solve_pid} = ParamsSolve.start_link(params: %{user: user_data, name: "Test User"})

    state = :sys.get_state(solve_pid)
    controller_pid = state.controllers[:current_user].pid

    assert controller_pid != nil
    assert Process.alive?(controller_pid)

    # Get the controller state to verify params were passed correctly
    controller_state = GenServer.call(controller_pid, :get_state)
    assert controller_state.user == user_data
    assert controller_state.name == "Test User"
  end

  test "params can extract nested values" do
    {:ok, solve_pid} =
      ParamsSolve.start_link(
        params: %{
          user: %{id: 42, email: "nested@example.com"},
          name: "Nested Test"
        }
      )

    state = :sys.get_state(solve_pid)
    controller_pid = state.controllers[:current_user].pid

    controller_state = GenServer.call(controller_pid, :get_state)
    assert controller_state.user.id == 42
    assert controller_state.user.email == "nested@example.com"
  end
end
