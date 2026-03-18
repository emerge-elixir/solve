defmodule Solve.LiveViewFormIntegrationTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SolveTest.Endpoint

  defmodule FormController do
    use Solve.Controller, events: [:change, :validate, :submit]

    @impl true
    def init(_params, _dependencies) do
      %{name: "", email: "", errors: %{}, submitted: false}
    end

    def change(payload, state, _dependencies, _callbacks, _init_params) do
      form = payload["form"] || %{}
      %{state | name: form["name"] || state.name, email: form["email"] || state.email}
    end

    def validate(payload, state, _dependencies, _callbacks, _init_params) do
      form = payload["form"] || %{}
      name = form["name"] || state.name
      email = form["email"] || state.email

      errors =
        %{}
        |> then(fn e -> if name == "", do: Map.put(e, :name, "required"), else: e end)
        |> then(fn e -> if email == "", do: Map.put(e, :email, "required"), else: e end)

      %{state | name: name, email: email, errors: errors}
    end

    def submit(payload, state, _dependencies, _callbacks, _init_params) do
      form = payload["form"] || %{}
      name = form["name"] || state.name
      email = form["email"] || state.email

      errors =
        %{}
        |> then(fn e -> if name == "", do: Map.put(e, :name, "required"), else: e end)
        |> then(fn e -> if email == "", do: Map.put(e, :email, "required"), else: e end)

      if errors == %{} do
        %{state | name: name, email: email, errors: %{}, submitted: true}
      else
        %{state | name: name, email: email, errors: errors, submitted: false}
      end
    end
  end

  defmodule FormApp do
    use Solve

    @impl true
    def controllers do
      [
        controller!(name: :registration, module: FormController)
      ]
    end
  end

  defmodule FormLive do
    use Phoenix.LiveView
    use Solve.LiveView

    def mount(_params, _session, socket) do
      state = solve_start(FormApp)
      assigns = solve(state, [:registration])
      {:ok, assign(socket, assigns)}
    end

    def render(assigns) do
      ~H"""
      <form phx-change={@state.registration[:validate]} phx-submit={@state.registration[:submit]} id="form">
        <input type="text" name="form[name]" value={@state.registration.name} id="name" />
        <%= if @state.registration.errors[:name] do %>
          <span class="error" id="name-error">{@state.registration.errors[:name]}</span>
        <% end %>

        <input type="email" name="form[email]" value={@state.registration.email} id="email" />
        <%= if @state.registration.errors[:email] do %>
          <span class="error" id="email-error">{@state.registration.errors[:email]}</span>
        <% end %>

        <button type="submit" id="submit">Submit</button>

        <%= if @state.registration.submitted do %>
          <p id="success">Registration complete!</p>
        <% end %>
      </form>
      """
    end
  end

  setup do
    {:ok, app} = FormApp.start_link()
    %{app: app}
  end

  test "renders empty form initially" do
    {:ok, _view, html} = live_isolated(build_conn(), FormLive)

    assert html =~ ~s(id="name")
    assert html =~ ~s(id="email")
    refute html =~ "error"
    refute html =~ "Registration complete!"
  end

  test "phx-change triggers validation and shows errors for empty fields", %{app: app} do
    {:ok, view, _html} = live_isolated(build_conn(), FormLive)

    view |> form("#form") |> render_change(%{"form" => %{"name" => "", "email" => ""}})
    html = flush_solve(view, app, :registration)

    assert html =~ "required"
    assert html =~ ~s(id="name-error")
    assert html =~ ~s(id="email-error")
  end

  test "phx-change clears errors when fields are valid", %{app: app} do
    {:ok, view, _html} = live_isolated(build_conn(), FormLive)

    # First trigger errors
    view |> form("#form") |> render_change(%{"form" => %{"name" => "", "email" => ""}})
    assert flush_solve(view, app, :registration) =~ "required"

    # Then fill in valid data
    view
    |> form("#form")
    |> render_change(%{"form" => %{"name" => "Alice", "email" => "alice@example.com"}})

    html = flush_solve(view, app, :registration)

    refute html =~ ~s(id="name-error")
    refute html =~ ~s(id="email-error")
  end

  test "phx-submit with valid data shows success", %{app: app} do
    {:ok, view, _html} = live_isolated(build_conn(), FormLive)

    view
    |> form("#form")
    |> render_submit(%{"form" => %{"name" => "Alice", "email" => "alice@example.com"}})

    html = flush_solve(view, app, :registration)

    assert html =~ "Registration complete!"
    assert html =~ ~s(id="success")
  end

  test "phx-submit with invalid data shows errors", %{app: app} do
    {:ok, view, _html} = live_isolated(build_conn(), FormLive)

    view |> form("#form") |> render_submit(%{"form" => %{"name" => "", "email" => ""}})
    html = flush_solve(view, app, :registration)

    assert html =~ "required"
    assert html =~ ~s(id="name-error")
    assert html =~ ~s(id="email-error")
    refute html =~ "Registration complete!"
  end

  # Drains the async Solve dispatch pipeline (app cast → controller cast → LV message)
  # by routing a sync call through app → controller, then rendering the LiveView.
  defp flush_solve(view, app, controller_name) do
    Solve.subscribe(app, controller_name)
    render(view)
  end
end
