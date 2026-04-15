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

    def flip(_payload), do: :second
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

  defmodule FlexibleArityController do
    use Solve.Controller, events: [:one, :two, :three, :four, :five]

    @impl true
    def init(%{test_pid: test_pid}, dependencies) do
      send(test_pid, {:flexible_arity_init, dependencies})
      %{test_pid: test_pid, last: nil}
    end

    def one(%{test_pid: test_pid, value: value} = payload) do
      send(test_pid, {:one_args, payload})
      %{test_pid: test_pid, last: {:one, value}}
    end

    def two(payload, state) do
      send(state.test_pid, {:two_args, payload, state})
      %{state | last: {:two, payload}}
    end

    def three(payload, state, dependencies) do
      send(state.test_pid, {:three_args, payload, state, dependencies})
      %{state | last: {:three, payload}}
    end

    def four(payload, state, dependencies, callbacks) do
      send(state.test_pid, {:four_args, payload, state, dependencies, callbacks})
      %{state | last: {:four, payload}}
    end

    def five(payload, state, dependencies, callbacks, init_params) do
      send(state.test_pid, {:five_args, payload, state, dependencies, callbacks, init_params})
      %{state | last: {:five, payload}}
    end

    @impl true
    def expose(state, _dependencies, _init_params) do
      %{last: state.last}
    end
  end

  defmodule ExternalPublisher do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, MapSet.new(), opts)
    end

    def subscribe(server, subscriber \\ self()) when is_pid(subscriber) do
      GenServer.call(server, {:subscribe, subscriber})
    end

    def publish(server, message) do
      GenServer.cast(server, {:publish, message})
    end

    @impl true
    def init(subscribers), do: {:ok, subscribers}

    @impl true
    def handle_call({:subscribe, subscriber}, _from, subscribers) do
      {:reply, :ok, MapSet.put(subscribers, subscriber)}
    end

    @impl true
    def handle_cast({:publish, message}, subscribers) do
      Enum.each(subscribers, &send(&1, message))
      {:noreply, subscribers}
    end
  end

  defmodule HandleInfoController do
    use Solve.Controller, events: [:increment]

    @impl true
    def init(%{test_pid: test_pid} = params, dependencies) do
      if publisher = params[:publisher] do
        :ok = ExternalPublisher.subscribe(publisher)
      end

      if monitor_pid = params[:monitor_pid] do
        Process.monitor(monitor_pid)
      end

      send(test_pid, {:handle_info_init, dependencies, params})

      %{
        count: Map.get(params, :initial, 0),
        messages: [],
        test_pid: test_pid
      }
    end

    def increment(payload, state) do
      %{state | count: state.count + payload}
    end

    @impl true
    def expose(state, dependencies, _init_params) do
      %{
        count: state.count,
        messages: Enum.reverse(state.messages),
        source: Map.get(dependencies, :source)
      }
    end

    def handle_info(message, state, dependencies, callbacks, init_params) do
      send(
        state.test_pid,
        {:handle_info_args, message, state, dependencies, callbacks, init_params}
      )

      new_state =
        case message do
          {:external_increment, value} -> %{state | count: state.count + value}
          _ -> state
        end

      %{new_state | messages: [message | new_state.messages]}
    end
  end

  defmodule HandleInfoArityTwoController do
    use Solve.Controller, events: []

    @impl true
    def init(%{publisher: publisher, test_pid: test_pid} = params, dependencies) do
      :ok = ExternalPublisher.subscribe(publisher)
      send(test_pid, {:handle_info_two_init, dependencies, params})

      %{
        count: Map.get(params, :initial, 0),
        test_pid: test_pid
      }
    end

    @impl true
    def expose(state, _dependencies, _init_params) do
      %{count: state.count}
    end

    def handle_info({:external_increment, value}, state) do
      send(state.test_pid, {:handle_info_two_args, {:external_increment, value}, state})
      %{state | count: state.count + value}
    end

    def handle_info(message, state) do
      send(state.test_pid, {:handle_info_two_args, message, state})
      state
    end
  end

  test "use Solve.Controller rejects invalid events lists" do
    module = unique_module_name("InvalidEvents")

    assert_raise CompileError, ~r/events must be a list of unique atoms/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use Solve.Controller, events: [:increment, :increment]

        def init(_params, _dependencies), do: %{}

        def increment(payload), do: %{payload: payload}
      end
      """)
    end
  end

  test "use Solve.Controller requires declared event callbacks to exist with arity 1 through 5" do
    module = unique_module_name("MissingEvent")

    assert_raise CompileError,
                 ~r/must define declared event callback\(s\) with exactly one arity between \/1 and \/5: increment/,
                 fn ->
                   Code.compile_string("""
                   defmodule #{inspect(module)} do
                     use Solve.Controller, events: [:increment]

                     def init(_params, _dependencies), do: %{}
                   end
                   """)
                 end
  end

  test "use Solve.Controller rejects declared event callbacks defined at multiple arities" do
    module = unique_module_name("DuplicateEventArity")

    assert_raise CompileError,
                 ~r/must not define declared event callback\(s\) at multiple arities: increment \(increment\/1, increment\/2\)/,
                 fn ->
                   Code.compile_string("""
                   defmodule #{inspect(module)} do
                    use Solve.Controller, events: [:increment]

                    def init(_params, _dependencies), do: %{}

                    def increment(payload), do: %{payload: payload}
                    def increment(payload, state), do: {payload, state}
                   end
                   """)
                 end
  end

  test "use Solve.Controller requires handle_info callbacks to use arity 2 through 5" do
    module = unique_module_name("InvalidHandleInfoArity")

    assert_raise CompileError,
                 ~r/must define handle_info callback\(s\) with exactly one arity between \/2 and \/5: handle_info\/1/,
                 fn ->
                   Code.compile_string("""
                   defmodule #{inspect(module)} do
                     use Solve.Controller, events: []

                     def init(_params, _dependencies), do: %{}

                     def handle_info(message), do: message
                   end
                   """)
                 end
  end

  test "use Solve.Controller rejects handle_info callbacks defined at multiple arities" do
    module = unique_module_name("DuplicateHandleInfoArity")

    assert_raise CompileError,
                 ~r/must not define handle_info callback\(s\) at multiple arities: handle_info\/2, handle_info\/3/,
                 fn ->
                   Code.compile_string("""
                   defmodule #{inspect(module)} do
                     use Solve.Controller, events: []

                     def init(_params, _dependencies), do: %{}

                     def handle_info(_message, state), do: state
                     def handle_info(_message, state, _dependencies), do: state
                   end
                   """)
                 end
  end

  test "dispatch/3 supports declared handlers with arity 1 through 5" do
    params = %{test_pid: self()}
    callbacks = %{audit: :ok}

    assert {:ok, pid} =
             FlexibleArityController.start_link(
               solve_app: :app,
               controller_name: :flexible,
               params: params,
               dependencies: %{source: %{value: 10}},
               callbacks: callbacks
             )

    assert_receive {:flexible_arity_init, %{source: %{value: 10}}}
    assert Solve.Controller.subscribe(pid) == %{last: nil}

    one_payload = %{test_pid: self(), value: 1}
    assert :ok = Solve.Controller.dispatch(pid, :one, one_payload)
    assert_receive {:one_args, ^one_payload}
    assert Solve.Controller.subscribe(pid) == %{last: {:one, 1}}

    assert :ok = Solve.Controller.dispatch(pid, :two, :two_payload)
    assert_receive {:two_args, :two_payload, %{test_pid: test_pid, last: {:one, 1}}}
    assert test_pid == self()
    assert Solve.Controller.subscribe(pid) == %{last: {:two, :two_payload}}

    assert :ok = Solve.Controller.dispatch(pid, :three, :three_payload)

    assert_receive {:three_args, :three_payload,
                    %{test_pid: test_pid, last: {:two, :two_payload}}, %{source: %{value: 10}}}

    assert test_pid == self()
    assert Solve.Controller.subscribe(pid) == %{last: {:three, :three_payload}}

    assert :ok = Solve.Controller.dispatch(pid, :four, :four_payload)

    assert_receive {:four_args, :four_payload,
                    %{test_pid: test_pid, last: {:three, :three_payload}},
                    %{source: %{value: 10}}, ^callbacks}

    assert test_pid == self()
    assert Solve.Controller.subscribe(pid) == %{last: {:four, :four_payload}}

    assert :ok = Solve.Controller.dispatch(pid, :five, :five_payload)

    assert_receive {:five_args, :five_payload,
                    %{test_pid: test_pid, last: {:four, :four_payload}}, %{source: %{value: 10}},
                    ^callbacks, ^params}

    assert test_pid == self()
    assert Solve.Controller.subscribe(pid) == %{last: {:five, :five_payload}}
  end

  test "ordinary handle_info receives external messages with Solve context and rebroadcasts exposed state" do
    assert {:ok, publisher} = ExternalPublisher.start_link()

    callbacks = %{audit: :enabled}
    params = %{initial: 1, label: :demo, publisher: publisher, test_pid: self()}

    assert {:ok, pid} =
             HandleInfoController.start_link(
               solve_app: :app,
               controller_name: :handle_info,
               params: params,
               dependencies: %{source: %{value: 10}},
               callbacks: callbacks
             )

    assert_receive {:handle_info_init, %{source: %{value: 10}}, ^params}

    assert Solve.Controller.subscribe(pid) == %{
             count: 1,
             messages: [],
             source: %{value: 10}
           }

    assert :ok = ExternalPublisher.publish(publisher, {:external_increment, 2})

    assert_receive {:handle_info_args, {:external_increment, 2}, %{count: 1, messages: []},
                    %{source: %{value: 10}}, ^callbacks, ^params},
                   100

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: :app,
        controller_name: :handle_info,
        exposed_state: %{
          count: 3,
          messages: [{:external_increment, 2}],
          source: %{value: 10}
        }
      }
    }

    assert Solve.Controller.subscribe(pid) == %{
             count: 3,
             messages: [{:external_increment, 2}],
             source: %{value: 10}
           }
  end

  test "handle_info/2 returns Solve state directly for non-Solve messages" do
    assert {:ok, publisher} = ExternalPublisher.start_link()

    params = %{initial: 2, publisher: publisher, test_pid: self()}

    assert {:ok, pid} =
             HandleInfoArityTwoController.start_link(
               solve_app: :app,
               controller_name: :handle_info_two,
               params: params,
               dependencies: %{},
               callbacks: %{}
             )

    assert_receive {:handle_info_two_init, %{}, ^params}
    assert Solve.Controller.subscribe(pid) == %{count: 2}

    assert :ok = ExternalPublisher.publish(publisher, {:external_increment, 3})

    assert_receive {:handle_info_two_args, {:external_increment, 3}, %{count: 2}}, 100

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: :app,
        controller_name: :handle_info_two,
        exposed_state: %{count: 5}
      }
    }

    assert Solve.Controller.subscribe(pid) == %{count: 5}
  end

  test "direct solve_event messages stay reserved when controller defines handle_info" do
    callbacks = %{audit: :enabled}
    params = %{initial: 2, test_pid: self()}

    assert {:ok, pid} =
             HandleInfoController.start_link(
               solve_app: :app,
               controller_name: :handle_info,
               params: params,
               dependencies: %{source: nil},
               callbacks: callbacks
             )

    assert_receive {:handle_info_init, %{source: nil}, ^params}
    assert Solve.Controller.subscribe(pid) == %{count: 2, messages: [], source: nil}

    send(pid, {:solve_event, :increment, 3})

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: :app,
        controller_name: :handle_info,
        exposed_state: %{count: 5, messages: [], source: nil}
      }
    }

    refute_receive {:handle_info_args, {:solve_event, :increment, 3}, _, _, _, _}, 50
  end

  test "dependency updates stay reserved when controller defines handle_info" do
    callbacks = %{audit: :enabled}
    params = %{test_pid: self()}

    assert {:ok, pid} =
             HandleInfoController.start_link(
               solve_app: :app,
               controller_name: :handle_info,
               params: params,
               dependencies: %{source: nil},
               callbacks: callbacks
             )

    assert_receive {:handle_info_init, %{source: nil}, ^params}
    assert Solve.Controller.subscribe(pid) == %{count: 0, messages: [], source: nil}

    send(pid, Solve.Message.update(:app, :source, %{value: 42}))

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: :app,
        controller_name: :handle_info,
        exposed_state: %{count: 0, messages: [], source: %{value: 42}}
      }
    }

    refute_receive {:handle_info_args, %Solve.Message{}, _, _, _, _}, 50
  end

  test "raw Solve messages remain reserved from controller handle_info" do
    callbacks = %{audit: :enabled}
    params = %{test_pid: self()}

    assert {:ok, pid} =
             HandleInfoController.start_link(
               solve_app: :app,
               controller_name: :handle_info,
               params: params,
               dependencies: %{source: nil},
               callbacks: callbacks
             )

    assert_receive {:handle_info_init, %{source: nil}, ^params}
    assert Solve.Controller.subscribe(pid) == %{count: 0, messages: [], source: nil}

    send(pid, Solve.Message.dispatch(:app, :handle_info, :increment, 4))

    send(pid, %Solve.DependencyUpdate{app: :other_app, key: :source, op: :replace, value: %{x: 1}})

    refute_receive {:handle_info_args, %Solve.Message{}, _, _, _, _}, 50
    refute_receive {:handle_info_args, %Solve.DependencyUpdate{}, _, _, _, _}, 50

    assert Solve.Controller.subscribe(pid) == %{count: 0, messages: [], source: nil}
  end

  test "unrelated DOWN messages fall through to controller handle_info" do
    monitored = spawn(fn -> Process.sleep(:infinity) end)
    callbacks = %{audit: :enabled}
    params = %{monitor_pid: monitored, test_pid: self()}

    assert {:ok, pid} =
             HandleInfoController.start_link(
               solve_app: :app,
               controller_name: :handle_info,
               params: params,
               dependencies: %{source: nil},
               callbacks: callbacks
             )

    assert_receive {:handle_info_init, %{source: nil}, ^params}
    assert Solve.Controller.subscribe(pid) == %{count: 0, messages: [], source: nil}

    Process.exit(monitored, :shutdown)

    assert_receive {:handle_info_args, {:DOWN, _ref, :process, ^monitored, :shutdown},
                    %{count: 0}, %{source: nil}, ^callbacks, ^params},
                   100

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: :app,
        controller_name: :handle_info,
        exposed_state: %{
          count: 0,
          messages: [{:DOWN, _, :process, ^monitored, :shutdown}],
          source: nil
        }
      }
    }
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

  test "direct solve_event messages invoke controller events" do
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

    send(pid, {:solve_event, :increment, 4})

    assert_receive {:increment_args, 4, %{count: 3}, %{source: %{value: 10}}, ^callbacks, ^params}

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{app: :app, controller_name: :counter, exposed_state: %{count: 7}}
    }
  end

  test "direct solve_event messages use empty map payload when omitted" do
    assert {:ok, pid} =
             StaticExposeController.start_link(
               solve_app: :app,
               controller_name: :static,
               params: %{ok: true},
               dependencies: %{},
               callbacks: %{}
             )

    assert Solve.Controller.subscribe(pid) == %{mode: :stable}

    send(pid, {:solve_event, :flip})

    assert :sys.get_state(pid).state == :second
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
