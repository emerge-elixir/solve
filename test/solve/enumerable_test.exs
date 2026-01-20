defmodule Solve.EnumerableTest do
  use ExUnit.Case, async: false

  defmodule ArticlesController do
    use Solve.Controller, events: []

    @impl true
    def init(_params, _dependencies) do
      %{
        articles: [
          %{id: 1, title: "Article 1"},
          %{id: 2, title: "Article 2"},
          %{id: 3, title: "Article 3"}
        ]
      }
    end

    @impl true
    def expose(state, _dependencies) do
      # Expose the list directly
      state.articles
    end
  end

  defmodule EnumerableSolve do
    use Solve

    @impl true
    def scene(_params) do
      %{articles: Solve.EnumerableTest.ArticlesController}
    end
  end

  test "can enumerate over exposed list" do
    {:ok, solve_pid} = EnumerableSolve.start_link()

    state = :sys.get_state(solve_pid)
    controller_pid = state.controllers[:articles].pid

    # Subscribe to get the ControllerAssign wrapper
    {:ok, exposed_state, events} =
      GenServer.call(controller_pid, {:subscribe_ui, :articles})

    controller_assign =
      Solve.ControllerAssign.new(controller_pid, events, exposed_state, :articles)

    # Test Enum.map
    titles = Enum.map(controller_assign, fn article -> article.title end)
    assert titles == ["Article 1", "Article 2", "Article 3"]

    # Test Enum.count
    assert Enum.count(controller_assign) == 3

    # Test Enum.filter
    filtered = Enum.filter(controller_assign, fn article -> article.id > 1 end)
    assert length(filtered) == 2

    # Test for comprehension
    ids = for article <- controller_assign, do: article.id
    assert ids == [1, 2, 3]
  end

  test "enumeration fails gracefully for non-enumerable exposed values" do
    defmodule SingleValueController do
      use Solve.Controller, events: []

      @impl true
      def init(_params, _dependencies), do: %{value: 42}

      @impl true
      def expose(state, _dependencies), do: state.value
    end

    defmodule SingleValueSolve do
      use Solve

      @impl true
      def scene(_params) do
        %{single: Solve.EnumerableTest.SingleValueController}
      end
    end

    {:ok, solve_pid} = SingleValueSolve.start_link()

    state = :sys.get_state(solve_pid)
    controller_pid = state.controllers[:single].pid

    {:ok, exposed_state, events} =
      GenServer.call(controller_pid, {:subscribe_ui, :single})

    controller_assign =
      Solve.ControllerAssign.new(controller_pid, events, exposed_state, :single)

    # Should raise Protocol.UndefinedError for non-enumerable values
    assert_raise Protocol.UndefinedError, fn ->
      Enum.map(controller_assign, fn x -> x end)
    end
  end
end
