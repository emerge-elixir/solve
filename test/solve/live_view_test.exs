defmodule Solve.LiveViewTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.JS

  defmodule CounterController do
    use Solve.Controller, events: [:increment, :decrement]

    @impl true
    def init(%{initial: initial}, _dependencies), do: %{count: initial}

    def increment(_payload, state, _dependencies, _callbacks, _init_params) do
      %{state | count: state.count + 1}
    end

    def decrement(_payload, state, _dependencies, _callbacks, _init_params) do
      %{state | count: state.count - 1}
    end
  end

  defmodule TimerController do
    use Solve.Controller, events: [:tick]

    @impl true
    def init(%{seconds: seconds}, _dependencies), do: %{elapsed: seconds}

    def tick(_payload, state, _dependencies, _callbacks, _init_params) do
      %{state | elapsed: state.elapsed + 1}
    end
  end

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

  defmodule FormSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :registration,
          module: Solve.LiveViewTest.FormController
        )
      ]
    end
  end

  defmodule LiveViewSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :counter,
          module: Solve.LiveViewTest.CounterController,
          params: fn %{app_params: app_params} -> %{initial: app_params.initial} end
        ),
        controller!(
          name: :timer,
          module: Solve.LiveViewTest.TimerController,
          params: fn %{app_params: app_params} -> %{seconds: app_params[:seconds] || 0} end
        )
      ]
    end
  end

  defmodule SecondSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :counter,
          module: Solve.LiveViewTest.CounterController,
          params: fn %{app_params: app_params} -> %{initial: app_params.initial} end
        )
      ]
    end
  end

  # -- tests --

  test "solve_state/2 stores AppRef in process dict" do
    app = start_app(LiveViewSolve, %{initial: 0})
    ref = Solve.LiveView.solve_state(app, :myns)

    assert %Solve.LiveView.AppRef{namespace: :myns, app: ^app} = ref
    assert Process.get({:solve_lv_app, :myns}) == ref
  end

  test "solve/2 returns namespace-wrapped flat map with JS events" do
    app = start_app(LiveViewSolve, %{initial: 5})
    app_ref = Solve.LiveView.solve_state(app, :ls)

    assigns = Solve.LiveView.solve(app_ref, [:counter])

    assert %{ls: %{counter: counter_map}} = assigns
    assert counter_map.count == 5

    # Events are JS.push structs
    assert %JS{} = counter_map.increment
    assert %JS{} = counter_map.decrement

    # No :events_ key — it's been stripped
    refute Map.has_key?(counter_map, :events_)
  end

  test "JS events carry correct metadata" do
    app = start_app(LiveViewSolve, %{initial: 0})
    app_ref = Solve.LiveView.solve_state(app, :ls)

    %{ls: %{counter: counter_map}} = Solve.LiveView.solve(app_ref, [:counter])

    # Inspect the JS struct ops to verify metadata
    assert %JS{ops: ops} = counter_map.increment
    assert [["push", %{event: "solve_event", value: value}]] = ops
    assert value["_sn"] == :ls
    assert value["_sc"] == :counter
    assert value["_se"] == :increment
  end

  test "to_assigns returns nil for stopped controllers" do
    app = start_app(LiveViewSolve, %{initial: 0})
    app_ref = Solve.LiveView.solve_state(app, :ls)

    # Subscribe first so Lookup has a ref
    _assigns = Solve.LiveView.solve(app_ref, [:counter])

    # Simulate receiving a nil update (controller stopped)
    socket = fake_socket(%{ls: %{counter: %{count: 0}}})

    updated_socket =
      Solve.LiveView.__handle_info__(socket, app, :counter, nil)

    assert updated_socket.assigns.ls.counter == nil
  end

  test "solve/2 subscribes to multiple controllers" do
    app = start_app(LiveViewSolve, %{initial: 3, seconds: 10})
    app_ref = Solve.LiveView.solve_state(app, :ls)

    assigns = Solve.LiveView.solve(app_ref, [:counter, :timer])

    assert %{ls: %{counter: counter, timer: timer}} = assigns
    assert counter.count == 3
    assert timer.elapsed == 10
    assert %JS{} = counter.increment
    assert %JS{} = timer.tick
  end

  test "__handle_info__ updates socket assigns" do
    app = start_app(LiveViewSolve, %{initial: 1})
    app_ref = Solve.LiveView.solve_state(app, :ls)

    # Initial subscribe
    %{ls: %{counter: _}} = Solve.LiveView.solve(app_ref, [:counter])

    socket = fake_socket(%{ls: %{counter: %{count: 1}}})

    # Simulate a state update
    updated_socket =
      Solve.LiveView.__handle_info__(socket, app, :counter, %{count: 42})

    assert %{ls: %{counter: counter}} = updated_socket.assigns
    assert counter.count == 42
    assert %JS{} = counter.increment
  end

  test "__handle_info__ preserves other controllers in namespace" do
    app = start_app(LiveViewSolve, %{initial: 1, seconds: 5})
    app_ref = Solve.LiveView.solve_state(app, :ls)

    %{ls: controllers} = Solve.LiveView.solve(app_ref, [:counter, :timer])

    socket = fake_socket(%{ls: controllers})

    # Update only counter
    updated_socket =
      Solve.LiveView.__handle_info__(socket, app, :counter, %{count: 99})

    assert updated_socket.assigns.ls.counter.count == 99
    assert updated_socket.assigns.ls.timer.elapsed == 5
  end

  test "__handle_event__ dispatches to correct controller" do
    app = start_app(LiveViewSolve, %{initial: 0})
    app_ref = Solve.LiveView.solve_state(app, :ls)

    _assigns = Solve.LiveView.solve(app_ref, [:counter])

    socket = fake_socket(%{})

    params = %{
      "_sn" => "ls",
      "_sc" => "counter",
      "_se" => "increment"
    }

    result_socket = Solve.LiveView.__handle_event__(socket, params)
    assert result_socket == socket

    # Verify the counter was incremented
    assert Solve.subscribe(app, :counter) == %{count: 1}
  end

  test "__handle_event__ passes form data as payload" do
    app = start_app(LiveViewSolve, %{initial: 0})
    app_ref = Solve.LiveView.solve_state(app, :ls)

    _assigns = Solve.LiveView.solve(app_ref, [:counter])

    socket = fake_socket(%{})

    params = %{
      "_sn" => "ls",
      "_sc" => "counter",
      "_se" => "increment",
      "user" => %{"name" => "test"}
    }

    Solve.LiveView.__handle_event__(socket, params)

    # The event dispatches with payload minus the _s* keys
    # Counter ignores payload, but dispatch succeeds
    assert Solve.subscribe(app, :counter) == %{count: 1}
  end

  test "multiple namespaces work independently" do
    app1 = start_app(LiveViewSolve, %{initial: 10, seconds: 0})
    app2 = start_app(SecondSolve, %{initial: 20})

    ref1 = Solve.LiveView.solve_state(app1, :ns1)
    ref2 = Solve.LiveView.solve_state(app2, :ns2)

    assigns1 = Solve.LiveView.solve(ref1, [:counter])
    assigns2 = Solve.LiveView.solve(ref2, [:counter])

    assert %{ns1: %{counter: %{count: 10}}} = assigns1
    assert %{ns2: %{counter: %{count: 20}}} = assigns2

    # Events target different apps
    %{ns1: %{counter: c1}} = assigns1
    %{ns2: %{counter: c2}} = assigns2

    assert %JS{ops: [[_, %{value: v1}]]} = c1.increment
    assert v1["_sn"] == :ns1

    assert %JS{ops: [[_, %{value: v2}]]} = c2.increment
    assert v2["_sn"] == :ns2
  end

  test "form change, validate, and submit flow" do
    app = start_app(FormSolve, %{})
    app_ref = Solve.LiveView.solve_state(app, :app)

    assigns = Solve.LiveView.solve(app_ref, [:registration])

    assert %{app: %{registration: reg}} = assigns
    assert reg.name == ""
    assert reg.email == ""
    assert %JS{} = reg.change
    assert %JS{} = reg.validate
    assert %JS{} = reg.submit

    socket = fake_socket(assigns)

    # 1. Simulate phx-change: user types into the form
    Solve.LiveView.__handle_event__(socket, %{
      "_sn" => "app",
      "_sc" => "registration",
      "_se" => "change",
      "form" => %{"name" => "Alice", "email" => ""}
    })

    assert %{name: "Alice", email: ""} = Solve.subscribe(app, :registration)

    # 2. Simulate phx-change triggering validation
    Solve.LiveView.__handle_event__(socket, %{
      "_sn" => "app",
      "_sc" => "registration",
      "_se" => "validate",
      "form" => %{"name" => "Alice", "email" => ""}
    })

    state = Solve.subscribe(app, :registration)
    assert state.name == "Alice"
    assert state.errors == %{email: "required"}
    assert state.submitted == false

    # 3. Simulate phx-change with complete form data
    Solve.LiveView.__handle_event__(socket, %{
      "_sn" => "app",
      "_sc" => "registration",
      "_se" => "validate",
      "form" => %{"name" => "Alice", "email" => "alice@example.com"}
    })

    state = Solve.subscribe(app, :registration)
    assert state.errors == %{}

    Solve.LiveView.__handle_event__(socket, %{
      "_sn" => "app",
      "_sc" => "registration",
      "_se" => "submit",
      "form" => %{"name" => "Alice", "email" => "alice@example.com"}
    })

    state = Solve.subscribe(app, :registration)
    assert state.name == "Alice"
    assert state.email == "alice@example.com"
    assert state.errors == %{}
    assert state.submitted == true
  end

  test "__handle_info__ ignores unknown apps" do
    socket = fake_socket(%{some: :data})

    # No solve_state called, so no namespace found
    result = Solve.LiveView.__handle_info__(socket, :unknown_app, :counter, %{count: 1})
    assert result == socket
  end

  # -- helpers --

  defp start_app(module, app_params) do
    name = unique_name(module)
    assert {:ok, pid} = module.start_link(name: name, params: app_params)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    pid
  end

  defp unique_name(prefix) do
    Module.concat(__MODULE__, String.to_atom("#{prefix}_#{System.unique_integer([:positive])}"))
  end

  defp stop_process(pid) do
    GenServer.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp fake_socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end
end
