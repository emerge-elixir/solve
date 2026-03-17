defmodule Solve.InitRuntimeTest do
  use ExUnit.Case, async: true

  defmodule CounterController do
  end

  defmodule StatsController do
  end

  defmodule ExampleSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(name: :counter, module: Solve.InitRuntimeTest.CounterController),
        controller!(
          name: :stats,
          module: Solve.InitRuntimeTest.StatsController,
          dependencies: [:counter]
        )
      ]
    end
  end

  test "init_runtime/2 returns compiled graph data and app params" do
    assert {:ok, state} = Solve.init_runtime(ExampleSolve, params: %{user_id: 123})

    assert state.app_params == %{user_id: 123}
    assert Map.keys(state.controller_specs_by_name) |> Enum.sort() == [:counter, :stats]
    assert state.sorted_controller_names == [:counter, :stats]

    assert state.dependents_map == %{
             counter: [:stats],
             stats: []
           }

    counter_spec = state.controller_specs_by_name.counter

    assert counter_spec.dependencies == []
    assert counter_spec.callbacks == []
    assert is_function(counter_spec.params, 1)
    assert counter_spec.params.(%{}) == true
  end
end
