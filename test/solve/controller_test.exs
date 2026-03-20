defmodule Solve.ControllerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule CounterController do
    use Solve.Controller, events: [:increment]

    @impl true
    def init(%{initial: initial, test_pid: test_pid} = init_params, dependencies) do
      send(test_pid, {:counter_init, dependencies, init_params})
      %{count: initial}
    end

    def increment(payload, state, dependencies, callbacks, init_params) do
      send(
        init_params.test_pid,
        {:increment_args, payload, state, dependencies, callbacks, init_params}
      )

      %{state | count: state.count + payload}
    end
  end

  defmodule DerivedController do
    use Solve.Controller, events: []

    @impl true
    def init(%{test_pid: test_pid}, dependencies) do
      send(test_pid, {:derived_init, dependencies})
      :ready
    end

    @impl true
    def expose(state, dependencies, %{tag: tag}) do
      %{state: state, source: Map.get(dependencies, :source), tag: tag}
    end
  end

  defmodule StaticExposeController do
    use Solve.Controller, events: [:flip]

    @impl true
    def init(_init_params, _dependencies), do: :first

    @impl true
    def expose(_state, _dependencies, _init_params), do: %{mode: :stable}

    def flip(_payload, _state, _dependencies, _callbacks, _init_params), do: :second
  end

  test "use Solve.Controller rejects invalid events lists" do
    module = unique_module_name("InvalidEvents")

    assert_raise CompileError, ~r/events must be a list of unique atoms/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Solve.Controller, events: [:increment, :increment]

        def init(_params, _dependencies), do: %{}

        def increment(payload, state, dependencies, callbacks, init_params) do
          {payload, state, dependencies, callbacks, init_params}
        end
      end
      """)
    end
  end

  test "use Solve.Controller requires declared event callbacks to exist as /5" do
    module = unique_module_name("MissingEvent")

    assert_raise CompileError, ~r/must define declared event callback\(s\): increment\/5/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Solve.Controller, events: [:increment]

        def init(_params, _dependencies), do: %{}
      end
      """)
    end
  end

  test "subscribe/2 returns the current exposed state using default expose/3" do
    params = %{initial: 2, test_pid: self()}
    callbacks = %{audit: fn _ -> :ok end}

    assert {:ok, pid} =
             CounterController.start_link(
               solve_app: :app,
               controller_name: :counter,
               params: params,
               dependencies: %{},
               callbacks: callbacks
             )

    assert_receive {:counter_init, %{}, ^params}
    assert Solve.Controller.subscribe(pid) == %{count: 2}
  end

  test "dispatch/3 passes payload, state, dependencies, callbacks, and init params to events" do
    params = %{initial: 3, test_pid: self()}
    callbacks = %{audit: fn _ -> :ok end}

    assert {:ok, pid} =
             CounterController.start_link(
               solve_app: :app,
               controller_name: :counter,
               params: params,
               dependencies: %{source: %{value: 10}},
               callbacks: callbacks
             )

    assert_receive {:counter_init, %{source: %{value: 10}}, ^params}
    assert Solve.Controller.subscribe(pid) == %{count: 3}

    assert :ok = Solve.Controller.dispatch(pid, :increment, 4)

    assert_receive {:increment_args, 4, %{count: 3}, %{source: %{value: 10}}, ^callbacks, ^params}

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{app: :app, controller_name: :counter, exposed_state: %{count: 7}}
    }
  end

  test "init stops when params are falsy" do
    original = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, original) end)

    assert {:error, {:invalid_init_params, :counter, nil}} =
             CounterController.start_link(controller_name: :counter, params: nil)

    assert {:error, {:invalid_init_params, :counter, false}} =
             CounterController.start_link(controller_name: :counter, params: false)
  end

  test "dependency updates refresh cached dependencies without rerunning init" do
    params = %{tag: :demo, test_pid: self()}

    assert {:ok, pid} =
             DerivedController.start_link(
               solve_app: :app,
               controller_name: :derived,
               params: params,
               dependencies: %{source: nil},
               callbacks: %{}
             )

    assert_receive {:derived_init, %{source: nil}}

    assert Solve.Controller.subscribe(pid) == %{state: :ready, source: nil, tag: :demo}

    send(pid, Solve.Message.update(:app, :source, %{value: 42}))

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: :app,
        controller_name: :derived,
        exposed_state: %{state: :ready, source: %{value: 42}, tag: :demo}
      }
    }

    refute_receive {:derived_init, _}
  end

  test "undeclared events are logged and discarded" do
    params = %{initial: 5, test_pid: self()}

    assert {:ok, pid} =
             CounterController.start_link(
               solve_app: :app,
               controller_name: :counter,
               params: params,
               dependencies: %{},
               callbacks: %{}
             )

    assert_receive {:counter_init, %{}, ^params}
    assert Solve.Controller.subscribe(pid) == %{count: 5}

    log =
      capture_log(fn ->
        assert :ok = Solve.Controller.dispatch(pid, :unknown, %{value: 1})
        :sys.get_state(pid)
      end)

    assert log =~ "discarding undeclared Solve controller event :unknown for :counter"

    refute_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{app: :app, controller_name: :counter, exposed_state: _}
    }

    assert Solve.Controller.subscribe(pid) == %{count: 5}
  end

  test "state changes that do not affect expose/3 are not rebroadcast" do
    assert {:ok, pid} =
             StaticExposeController.start_link(
               solve_app: :app,
               controller_name: :static,
               params: %{ok: true},
               dependencies: %{},
               callbacks: %{}
             )

    assert Solve.Controller.subscribe(pid) == %{mode: :stable}
    assert :ok = Solve.Controller.dispatch(pid, :flip, :ignored)
    :sys.get_state(pid)

    refute_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{app: :app, controller_name: :static, exposed_state: _}
    }
  end

  test "dead subscribers are removed from the controller state" do
    params = %{initial: 1, test_pid: self()}

    assert {:ok, pid} =
             CounterController.start_link(
               solve_app: :app,
               controller_name: :counter,
               params: params,
               dependencies: %{},
               callbacks: %{}
             )

    assert_receive {:counter_init, %{}, ^params}

    subscriber = spawn(fn -> Process.sleep(:infinity) end)

    assert Solve.Controller.subscribe(pid, subscriber) == %{count: 1}

    Process.exit(subscriber, :shutdown)
    Process.sleep(10)

    state = :sys.get_state(pid)
    assert state.subscribers == %{}
  end

  defp unique_module_name(prefix) do
    Module.concat(
      __MODULE__,
      String.to_atom(prefix <> Integer.to_string(System.unique_integer([:positive])))
    )
  end
end
