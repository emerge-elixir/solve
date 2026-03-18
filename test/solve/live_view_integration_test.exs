defmodule Solve.LiveViewIntegrationTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SolveTest.Endpoint

  defmodule CounterController do
    use Solve.Controller, events: [:increment, :decrement]

    @impl true
    def init(_params, _dependencies), do: %{count: 0}

    def increment(_payload, state, _dependencies, _callbacks, _init_params) do
      %{state | count: state.count + 1}
    end

    def decrement(_payload, state, _dependencies, _callbacks, _init_params) do
      %{state | count: state.count - 1}
    end
  end

  defmodule CounterApp do
    use Solve

    @impl true
    def controllers do
      [
        controller!(name: :counter, module: CounterController)
      ]
    end
  end

  defmodule CounterLive do
    use Phoenix.LiveView
    use Solve.LiveView

    def mount(_params, _session, socket) do
      state = solve_start(CounterApp)
      assigns = solve(state, [:counter])
      {:ok, assign(socket, assigns)}
    end

    def render(assigns) do
      ~H"""
      <button phx-click={@state.counter[:increment]} id="inc">+</button>
      <h1 id="count">{@state.counter.count}</h1>
      <button phx-click={@state.counter[:decrement]} id="dec">-</button>
      """
    end
  end

  setup do
    {:ok, app} = CounterApp.start_link()
    %{app: app}
  end

  test "renders initial count of 0" do
    {:ok, _view, html} = live_isolated(build_conn(), CounterLive)

    assert html =~ "<h1 id=\"count\">0</h1>"
  end

  test "increment button increases count", %{app: app} do
    {:ok, view, _html} = live_isolated(build_conn(), CounterLive)
    view |> element("#inc") |> render_click()

    assert flush_solve(view, app, :counter) =~ "<h1 id=\"count\">1</h1>"
  end

  test "decrement button decreases count", %{app: app} do
    {:ok, view, _html} = live_isolated(build_conn(), CounterLive)

    view |> element("#inc") |> render_click()
    assert flush_solve(view, app, :counter) =~ "<h1 id=\"count\">1</h1>"

    view |> element("#dec") |> render_click()
    assert flush_solve(view, app, :counter) =~ "<h1 id=\"count\">0</h1>"
  end

  test "multiple increments accumulate", %{app: app} do
    {:ok, view, _html} = live_isolated(build_conn(), CounterLive)
    for _ <- 1..5, do: view |> element("#inc") |> render_click()

    assert flush_solve(view, app, :counter) =~ "<h1 id=\"count\">5</h1>"
  end

  test "increment then decrement returns to previous value", %{app: app} do
    {:ok, view, _html} = live_isolated(build_conn(), CounterLive)
    view |> element("#inc") |> render_click()
    view |> element("#inc") |> render_click()
    view |> element("#dec") |> render_click()

    assert flush_solve(view, app, :counter) =~ "<h1 id=\"count\">1</h1>"
  end

  # Drains the async Solve dispatch pipeline (app cast → controller cast → LV message)
  # by routing a sync call through app → controller, then rendering the LiveView.
  defp flush_solve(view, app, controller_name) do
    Solve.subscribe(app, controller_name)
    render(view)
  end
end
