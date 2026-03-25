defmodule Solve.ControllerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  alias Solve.Collection

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

  defmodule CollectionDependencyController do
    use Solve.Controller, events: []

    @impl true
    def init(%{test_pid: test_pid}, dependencies) do
      send(test_pid, {:collection_dependency_init, dependencies})
      :ready
    end

    @impl true
    def expose(state, dependencies, _init_params) do
      %{state: state, columns: Map.fetch!(dependencies, :columns)}
    end
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

  test "subscribe_with/3 returns current exposed state and sends encoded updates" do
    params = %{initial: 2, test_pid: self()}

    assert {:ok, pid} =
             CounterController.start_link(
               solve_app: :app,
               controller_name: :counter,
               params: params,
               dependencies: %{},
               callbacks: %{}
             )

    assert_receive {:counter_init, %{}, ^params}

    assert {:ok, %{count: 2}, subscription_ref} =
             Solve.Controller.subscribe_with(pid, self(), fn exposed_state ->
               {:encoded_counter_update, exposed_state}
             end)

    assert is_reference(subscription_ref)

    assert :ok = Solve.Controller.dispatch(pid, :increment, 1)

    assert_receive {:encoded_counter_update, %{count: 3}}
  end

  test "unsubscribe/2 removes only the targeted internal subscription" do
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

    assert {:ok, %{count: 1}, first_ref} =
             Solve.Controller.subscribe_with(pid, self(), fn exposed_state ->
               {:first_counter_update, exposed_state}
             end)

    assert {:ok, %{count: 1}, second_ref} =
             Solve.Controller.subscribe_with(pid, self(), fn exposed_state ->
               {:second_counter_update, exposed_state}
             end)

    assert first_ref != second_ref
    assert :ok = Solve.Controller.unsubscribe(pid, first_ref)

    assert :ok = Solve.Controller.dispatch(pid, :increment, 1)

    refute_receive {:first_counter_update, _}, 50
    assert_receive {:second_counter_update, %{count: 2}}
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

  test "update_callbacks/2 changes callbacks for later events without restarting" do
    params = %{initial: 3, test_pid: self()}

    assert {:ok, pid} =
             CounterController.start_link(
               solve_app: :app,
               controller_name: :counter,
               params: params,
               dependencies: %{source: %{value: 10}},
               callbacks: %{audit: :initial}
             )

    assert_receive {:counter_init, %{source: %{value: 10}}, ^params}
    assert Solve.Controller.subscribe(pid) == %{count: 3}

    assert :ok = Solve.Controller.update_callbacks(pid, %{audit: :updated})
    assert :ok = Solve.Controller.dispatch(pid, :increment, 4)

    assert_receive {:increment_args, 4, %{count: 3}, %{source: %{value: 10}}, %{audit: :updated},
                    ^params}

    refute_receive {:counter_init, _, _}, 50

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

  test "dependency update :replace updates the local dependency key" do
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

    send(pid, %Solve.DependencyUpdate{app: :app, key: :source, op: :replace, value: %{value: 42}})

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: :app,
        controller_name: :derived,
        exposed_state: %{state: :ready, source: %{value: 42}, tag: :demo}
      }
    }
  end

  test "dependency update :collection_put inserts or replaces one item" do
    params = %{test_pid: self()}

    assert {:ok, pid} =
             CollectionDependencyController.start_link(
               solve_app: :app,
               controller_name: :collection_dep,
               params: params,
               dependencies: %{columns: Collection.empty()},
               callbacks: %{}
             )

    assert_receive {:collection_dependency_init, %{columns: %Collection{ids: [], items: %{}}}}
    assert Solve.Controller.subscribe(pid) == %{state: :ready, columns: Collection.empty()}

    send(pid, %Solve.DependencyUpdate{
      app: :app,
      key: :columns,
      op: :collection_put,
      id: 2,
      value: %{title: "Doing"}
    })

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: :app,
        controller_name: :collection_dep,
        exposed_state: %{
          state: :ready,
          columns: %Collection{ids: [2], items: %{2 => %{title: "Doing"}}}
        }
      }
    }

    send(pid, %Solve.DependencyUpdate{
      app: :app,
      key: :columns,
      op: :collection_put,
      id: 2,
      value: %{title: "In Progress"}
    })

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: :app,
        controller_name: :collection_dep,
        exposed_state: %{
          state: :ready,
          columns: %Collection{ids: [2], items: %{2 => %{title: "In Progress"}}}
        }
      }
    }
  end

  test "dependency update :collection_delete removes one item" do
    params = %{test_pid: self()}

    initial_columns = %Collection{
      ids: [1, 2],
      items: %{1 => %{title: "Todo"}, 2 => %{title: "Doing"}}
    }

    assert {:ok, pid} =
             CollectionDependencyController.start_link(
               solve_app: :app,
               controller_name: :collection_dep,
               params: params,
               dependencies: %{columns: initial_columns},
               callbacks: %{}
             )

    assert_receive {:collection_dependency_init, %{columns: ^initial_columns}}
    assert Solve.Controller.subscribe(pid) == %{state: :ready, columns: initial_columns}

    send(pid, %Solve.DependencyUpdate{app: :app, key: :columns, op: :collection_delete, id: 1})

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: :app,
        controller_name: :collection_dep,
        exposed_state: %{
          state: :ready,
          columns: %Collection{ids: [2], items: %{2 => %{title: "Doing"}}}
        }
      }
    }
  end

  test "dependency update :collection_reorder updates ids and preserves items" do
    params = %{test_pid: self()}

    initial_columns = %Collection{
      ids: [2, 1],
      items: %{1 => %{title: "Todo"}, 2 => %{title: "Doing"}}
    }

    assert {:ok, pid} =
             CollectionDependencyController.start_link(
               solve_app: :app,
               controller_name: :collection_dep,
               params: params,
               dependencies: %{columns: initial_columns},
               callbacks: %{}
             )

    assert_receive {:collection_dependency_init, %{columns: ^initial_columns}}
    assert Solve.Controller.subscribe(pid) == %{state: :ready, columns: initial_columns}

    send(pid, %Solve.DependencyUpdate{
      app: :app,
      key: :columns,
      op: :collection_reorder,
      ids: [1, 2]
    })

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: :app,
        controller_name: :collection_dep,
        exposed_state: %{
          state: :ready,
          columns: %Collection{
            ids: [1, 2],
            items: %{1 => %{title: "Todo"}, 2 => %{title: "Doing"}}
          }
        }
      }
    }
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

  test "dead internal subscribers are removed from the controller state" do
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

    assert {:ok, %{count: 1}, _first_ref} =
             Solve.Controller.subscribe_with(pid, subscriber, fn exposed_state ->
               {:first_internal_update, exposed_state}
             end)

    assert {:ok, %{count: 1}, _second_ref} =
             Solve.Controller.subscribe_with(pid, subscriber, fn exposed_state ->
               {:second_internal_update, exposed_state}
             end)

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
