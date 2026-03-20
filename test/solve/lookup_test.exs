defmodule Solve.LookupTest do
  use ExUnit.Case, async: false

  defmodule CounterController do
    use Solve.Controller, events: [:increment]

    @impl true
    def init(%{initial: initial}, _dependencies), do: %{count: initial}

    def increment(_payload, state, _dependencies, _callbacks, _init_params) do
      %{state | count: state.count + 1}
    end
  end

  defmodule CollisionController do
    use Solve.Controller, events: []

    @impl true
    def init(_params, _dependencies), do: %{count: 1}

    @impl true
    def expose(_state, _dependencies, _init_params), do: %{events_: %{bad: true}}
  end

  defmodule LookupSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :counter,
          module: Solve.LookupTest.CounterController,
          params: fn %{app_params: app_params} -> %{initial: app_params.initial} end
        )
      ]
    end
  end

  defmodule CollisionSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :collision,
          module: Solve.LookupTest.CollisionController,
          params: fn %{app_params: _app_params} -> %{ok: true} end
        )
      ]
    end
  end

  defmodule AutoLookupWorker do
    use GenServer
    use Solve.Lookup

    def start_link(app, test_pid) do
      GenServer.start_link(__MODULE__, {app, test_pid})
    end

    @impl true
    def init({app, test_pid}), do: {:ok, %{app: app, test_pid: test_pid}}

    @impl true
    def handle_call({:solve, controller_name}, _from, state) do
      {:reply, solve(state.app, controller_name), state}
    end

    @impl true
    def handle_cast({:send_event, controller_name, event_name}, state) do
      controller = solve(state.app, controller_name)
      send(self(), events(controller)[event_name])
      {:noreply, state}
    end

    @impl Solve.Lookup
    def handle_solve_updated(updated, state) do
      send(state.test_pid, {:solve_updated, updated, solve(state.app, :counter)})
      {:ok, state}
    end
  end

  defmodule ManualLookupWorker do
    use GenServer
    use Solve.Lookup, handle_info: :manual

    def start_link(app, test_pid) do
      GenServer.start_link(__MODULE__, {app, test_pid})
    end

    @impl true
    def init({app, test_pid}), do: {:ok, %{app: app, test_pid: test_pid, unhandled: []}}

    @impl true
    def handle_call({:solve, controller_name}, _from, state) do
      {:reply, solve(state.app, controller_name), state}
    end

    @impl true
    def handle_call(:unhandled, _from, state) do
      {:reply, Enum.reverse(state.unhandled), state}
    end

    @impl true
    def handle_cast({:send_event, controller_name, event_name}, state) do
      controller = solve(state.app, controller_name)
      send(self(), events(controller)[event_name])
      {:noreply, state}
    end

    @impl true
    def handle_info(nil, state) do
      {:noreply, state}
    end

    def handle_info(%Solve.Message{} = message, %{app: app} = state) do
      case handle_message(message) do
        %{^app => controllers} ->
          if :counter in controllers,
            do: {:noreply, render(state)},
            else: {:noreply, state}

        %{} ->
          {:noreply, state}
      end
    end

    def handle_info(message, state) do
      {:noreply, %{state | unhandled: [message | state.unhandled]}}
    end

    def render(state) do
      send(state.test_pid, {:manual_rendered, solve(state.app, :counter)})
      state
    end
  end

  test "solve/2 returns exposed map with nested events and tracks updates" do
    app = start_app(LookupSolve, %{initial: 1})
    assert {:ok, worker} = AutoLookupWorker.start_link(app, self())

    counter = GenServer.call(worker, {:solve, :counter})

    assert counter.count == 1

    assert Solve.Lookup.events(counter).increment ==
             %Solve.Message{
               type: :dispatch,
               payload: %Solve.Dispatch{
                 app: app,
                 controller_name: :counter,
                 event: :increment,
                 payload: %{}
               }
             }

    assert Solve.controller_events(app, :counter) == [:increment]

    assert :ok = GenServer.cast(worker, {:send_event, :counter, :increment})

    assert await_lookup_count(worker) == 2
    assert_receive {:solve_updated, %{^app => [:counter]}, %{count: 2, events_: events}}
    assert Map.has_key?(events, :increment)
  end

  test "events(nil) returns nil and injected nil handle_info is a no-op" do
    app = start_app(LookupSolve, %{initial: 1})
    assert {:ok, worker} = AutoLookupWorker.start_link(app, self())

    assert Solve.Lookup.events(nil) == nil

    send(worker, nil)
    send(worker, Solve.Lookup.events(nil)[:increment])

    assert Process.alive?(worker)
    assert GenServer.call(worker, {:solve, :counter}).count == 1
    refute_receive {:solve_updated, _, _}, 50
  end

  test "manual handle_info forwarding works when lookup auto wiring is disabled" do
    app = start_app(LookupSolve, %{initial: 1})
    assert {:ok, worker} = ManualLookupWorker.start_link(app, self())

    assert GenServer.call(worker, {:solve, :counter}).count == 1

    send(worker, nil)
    refute_receive {:manual_rendered, _}, 50

    assert :ok = GenServer.cast(worker, {:send_event, :counter, :increment})
    assert await_lookup_count(worker) == 2
    assert_receive {:manual_rendered, %{count: 2, events_: events}}
    assert Map.has_key?(events, :increment)

    send(worker, {:custom, :message})
    Process.sleep(10)

    assert GenServer.call(worker, :unhandled) == [{:custom, :message}]
  end

  test "handle_message/1 updates local lookup cache for update envelopes" do
    app = start_app(LookupSolve, %{initial: 1})

    assert %{^app => [:counter]} =
             Solve.Lookup.handle_message(Solve.Message.update(app, :counter, %{count: 5}))

    assert Solve.Lookup.solve(app, :counter).count == 5
  end

  test "handle_message/1 returns empty map for dispatch envelopes" do
    app = start_app(LookupSolve, %{initial: 1})

    assert %{} ==
             Solve.Lookup.handle_message(Solve.Message.dispatch(app, :counter, :increment, %{}))

    assert await_counter_value(app, 2) == 2
  end

  test "handle_message/1 accepts only Solve.Message" do
    assert_raise FunctionClauseError, fn ->
      apply(Solve.Lookup, :handle_message, [nil])
    end
  end

  test "compile-time requirements follow handle_info mode" do
    module = unique_name("MissingCallback")

    assert_raise CompileError, ~r/must define handle_solve_updated\/2/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use GenServer
        use Solve.Lookup

        def init(state), do: {:ok, state}
      end
      """)
    end

    module = unique_name("ManualNoCallback")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use GenServer
      use Solve.Lookup, handle_info: :manual

      def init(state), do: {:ok, state}
    end
    """)

    module = unique_name("InvalidHandleInfo")

    assert_raise CompileError, ~r/must be :auto or :manual/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use GenServer
        use Solve.Lookup, handle_info: false

        def init(state), do: {:ok, state}
      end
      """)
    end
  end

  test "lookup raises when controller expose map collides with events_ key" do
    app = start_app(CollisionSolve, %{})

    assert_raise ArgumentError, ~r/reserves :events_/, fn ->
      Solve.Lookup.solve(app, :collision)
    end
  end

  defp await_lookup_count(worker, attempts \\ 50)

  defp await_lookup_count(_worker, 0) do
    flunk("lookup worker did not observe expected update in time")
  end

  defp await_lookup_count(worker, attempts) do
    case GenServer.call(worker, {:solve, :counter}) do
      %{count: 2} = counter ->
        counter.count

      _counter ->
        Process.sleep(10)
        await_lookup_count(worker, attempts - 1)
    end
  end

  defp await_counter_value(app, value, attempts \\ 50)

  defp await_counter_value(_app, _value, 0) do
    flunk("counter value did not update in time")
  end

  defp await_counter_value(app, value, attempts) do
    case Solve.Lookup.solve(app, :counter) do
      %{count: ^value} ->
        value

      _ ->
        Process.sleep(10)
        await_counter_value(app, value, attempts - 1)
    end
  end

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
end
