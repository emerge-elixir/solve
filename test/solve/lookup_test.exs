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

    def render(state) do
      send(state.test_pid, {:rendered, solve(state.app, :counter)})
    end
  end

  defmodule ManualLookupWorker do
    use GenServer
    use Solve.Lookup, handle_info: false

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
    def handle_info(message, state) do
      case handle_solve_lookup(message, state) do
        {:handled, state} -> {:noreply, state}
        :unhandled -> {:noreply, %{state | unhandled: [message | state.unhandled]}}
      end
    end

    def render(state) do
      send(state.test_pid, {:manual_rendered, solve(state.app, :counter)})
    end
  end

  defmodule NoRenderLookupWorker do
    use GenServer
    use Solve.Lookup, on_update: nil

    @impl true
    def init(state), do: {:ok, state}
  end

  test "solve/2 returns exposed map with nested events and tracks updates" do
    app = start_app(LookupSolve, %{initial: 1})
    assert {:ok, worker} = AutoLookupWorker.start_link(app, self())

    counter = GenServer.call(worker, {:solve, :counter})

    assert counter.count == 1

    assert Solve.Lookup.events(counter).increment == %Solve.Lookup.Dispatch{
             app: app,
             controller_name: :counter,
             event: :increment,
             payload: %{}
           }

    assert Solve.controller_events(app, :counter) == [:increment]

    assert :ok = GenServer.cast(worker, {:send_event, :counter, :increment})

    assert await_lookup_count(worker) == 2
    assert_receive {:rendered, %{count: 2, events_: events}}
    assert Map.has_key?(events, :increment)
  end

  test "events(nil) returns nil and injected nil handle_info is a no-op" do
    app = start_app(LookupSolve, %{initial: 1})
    assert {:ok, worker} = AutoLookupWorker.start_link(app, self())

    assert Solve.Lookup.events(nil) == nil

    send(worker, nil)
    assert Process.alive?(worker)
    assert GenServer.call(worker, {:solve, :counter}).count == 1
    refute_receive {:rendered, _}, 50
  end

  test "manual handle_info forwarding works when lookup auto wiring is disabled" do
    app = start_app(LookupSolve, %{initial: 1})
    assert {:ok, worker} = ManualLookupWorker.start_link(app, self())

    assert GenServer.call(worker, {:solve, :counter}).count == 1
    assert :ok = GenServer.cast(worker, {:send_event, :counter, :increment})
    assert await_lookup_count(worker) == 2
    assert_receive {:manual_rendered, %{count: 2, events_: events}}
    assert Map.has_key?(events, :increment)

    send(worker, {:custom, :message})
    Process.sleep(10)

    assert GenServer.call(worker, :unhandled) == [{:custom, :message}]
  end

  test "default use Solve.Lookup requires render/1 and on_update nil does not" do
    module = unique_name("MissingRender")

    assert_raise CompileError, ~r/must define render\/1/, fn ->
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use GenServer
        use Solve.Lookup

        def init(state), do: {:ok, state}
      end
      """)
    end

    module = unique_name("NilOnUpdate")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use GenServer
      use Solve.Lookup, on_update: nil

      def init(state), do: {:ok, state}
    end
    """)
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
