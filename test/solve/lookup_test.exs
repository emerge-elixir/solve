defmodule Solve.LookupTest do
  use ExUnit.Case, async: false

  alias Solve.Collection

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

  defmodule RefreshDriverController do
    use Solve.Controller, events: [:set_initial]

    @impl true
    def init(%{initial: initial}, _dependencies), do: %{initial: initial}

    def set_initial(initial, _state, _dependencies, _callbacks, _init_params) do
      %{initial: initial}
    end

    @impl true
    def expose(state, _dependencies, _init_params), do: %{initial: state.initial}
  end

  defmodule RefreshCounterController do
    use Solve.Controller, events: [:increment]

    @impl true
    def init(%{initial: initial, test_pid: test_pid}, _dependencies) do
      send(test_pid, {:refresh_counter_init, self(), initial})
      %{count: initial}
    end

    def increment(_payload, state, _dependencies, _callbacks, _init_params) do
      %{state | count: state.count + 1}
    end

    @impl true
    def expose(state, _dependencies, _init_params), do: %{count: state.count}
  end

  defmodule RefreshLookupSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :driver,
          module: Solve.LookupTest.RefreshDriverController,
          params: fn %{app_params: app_params} -> %{initial: app_params.initial} end
        ),
        controller!(
          name: :counter,
          module: Solve.LookupTest.RefreshCounterController,
          dependencies: [:driver],
          params: fn %{dependencies: %{driver: %{initial: initial}}, app_params: app_params} ->
            %{initial: initial, test_pid: app_params.test_pid}
          end
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

  defmodule CatalogController do
    use Solve.Controller, events: [:set_columns]

    @impl true
    def init(%{columns: columns}, _dependencies), do: %{columns: columns}

    def set_columns(columns, _state, _dependencies, _callbacks, _init_params) do
      %{columns: columns}
    end

    @impl true
    def expose(state, _dependencies, _init_params), do: %{columns: state.columns}
  end

  defmodule ColumnController do
    use Solve.Controller, events: [:rename]

    @impl true
    def init(%{id: id, title: title}, _dependencies), do: %{id: id, title: title}

    def rename(title, state, _dependencies, _callbacks, _init_params) do
      %{state | title: title}
    end

    @impl true
    def expose(state, _dependencies, _init_params), do: %{id: state.id, title: state.title}
  end

  defmodule CollectionLookupSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :catalog,
          module: Solve.LookupTest.CatalogController,
          params: fn %{app_params: app_params} -> %{columns: app_params.columns} end
        ),
        controller!(
          name: :column,
          module: Solve.LookupTest.ColumnController,
          variant: :collection,
          dependencies: [:catalog],
          collect: fn %{dependencies: %{catalog: %{columns: columns}}} ->
            Enum.map(columns, fn %{id: id, title: title} ->
              {id, [params: %{id: id, title: title}]}
            end)
          end
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

      case events(controller)[event_name] do
        {pid, message} -> send(pid, message)
        nil -> :ok
      end

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

      case events(controller)[event_name] do
        {pid, message} -> send(pid, message)
        nil -> :ok
      end

      {:noreply, state}
    end

    @impl true
    def handle_info(nil, state) do
      {:noreply, state}
    end

    def handle_info(%Solve.Message{} = message, %{app: app} = state) do
      case handle_message(message) do
        %{^app => %Solve.Lookup.Updated{refs: refs}} ->
          if :counter in refs,
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

    assert {pid, {:solve_event, :increment}} = Solve.Lookup.events(counter).increment
    assert pid == Solve.controller_pid(app, :counter)

    assert Solve.controller_events(app, :counter) == [:increment]

    assert :ok = GenServer.cast(worker, {:send_event, :counter, :increment})

    assert await_lookup_count(worker) == 2

    assert_receive {:solve_updated,
                    %{^app => %Solve.Lookup.Updated{refs: [:counter], collections: []}},
                    %{count: 2, events_: events}}

    assert Map.has_key?(events, :increment)
  end

  test "event/3 returns a direct controller tuple for singleton lookups" do
    app = start_app(LookupSolve, %{initial: 1})

    counter = Solve.Lookup.solve(app, :counter)

    assert {pid, {:solve_event, :increment, 1}} = Solve.Lookup.event(counter, :increment, 1)
    assert pid == Solve.controller_pid(app, :counter)

    send(pid, {:solve_event, :increment, 1})

    assert_receive %Solve.Message{
                     type: :update,
                     payload: %Solve.Update{
                       app: ^app,
                       controller_name: :counter,
                       exposed_state: %{count: 2}
                     }
                   } = message

    assert %{^app => %Solve.Lookup.Updated{refs: [:counter], collections: []}} =
             Solve.Lookup.handle_message(message)

    assert Solve.Lookup.solve(app, :counter).count == 2
  end

  test "events/1 refreshes direct pid refs after controller replacement" do
    app = start_app(RefreshLookupSolve, %{initial: 1, test_pid: self()})

    assert_receive {:refresh_counter_init, initial_pid, 1}

    counter = Solve.Lookup.solve(app, :counter)
    assert {^initial_pid, {:solve_event, :increment}} = Solve.Lookup.events(counter).increment

    assert :ok = Solve.dispatch(app, :driver, :set_initial, 5)

    assert_receive {:refresh_counter_init, replacement_pid, 5}
    refute replacement_pid == initial_pid

    assert_receive %Solve.Message{
                     type: :update,
                     payload: %Solve.Update{
                       app: ^app,
                       controller_name: :counter,
                       exposed_state: %{count: 5}
                     }
                   } = message

    assert %{^app => %Solve.Lookup.Updated{refs: [:counter], collections: []}} =
             Solve.Lookup.handle_message(message)

    refreshed = Solve.Lookup.solve(app, :counter)

    assert {^replacement_pid, {:solve_event, :increment}} =
             Solve.Lookup.events(refreshed).increment
  end

  test "lookup cache stays fresh when app is addressed by registered name" do
    name = unique_name("NamedLookup")
    assert {:ok, app} = LookupSolve.start_link(name: name, params: %{initial: 1})

    on_exit(fn ->
      if Process.alive?(app) do
        stop_process(app)
      end
    end)

    assert {:ok, worker} = AutoLookupWorker.start_link(name, self())

    counter = GenServer.call(worker, {:solve, :counter})
    assert counter.count == 1

    assert {pid, message} = Solve.Lookup.events(counter).increment
    send(pid, message)

    assert await_lookup_count(worker) == 2

    assert_receive {:solve_updated,
                    %{^app => %Solve.Lookup.Updated{refs: [:counter], collections: []}},
                    %{count: 2, events_: events}}

    assert Map.has_key?(events, :increment)
  end

  test "events(nil) returns nil and injected nil handle_info is a no-op" do
    app = start_app(LookupSolve, %{initial: 1})
    assert {:ok, worker} = AutoLookupWorker.start_link(app, self())

    assert Solve.Lookup.events(nil) == nil
    assert Solve.Lookup.event(nil, :increment) == nil

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

    assert %{^app => %Solve.Lookup.Updated{refs: [:counter], collections: []}} =
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

  test "collection/2 returns a Solve.Collection with events_ added to each item" do
    app =
      start_app(CollectionLookupSolve, %{
        columns: [%{id: 1, title: "Todo"}, %{id: 2, title: "Doing"}]
      })

    columns = Solve.Lookup.collection(app, :column)

    assert columns == %Collection{
             ids: [1, 2],
             items: %{
               1 => %{id: 1, title: "Todo", events_: %{rename: columns.items[1].events_.rename}},
               2 => %{id: 2, title: "Doing", events_: %{rename: columns.items[2].events_.rename}}
             }
           }

    assert {pid, {:solve_event, :rename}} = columns.items[1].events_.rename
    assert pid == Solve.controller_pid(app, {:column, 1})
  end

  test "events/1 returns nil for Solve.Collection" do
    app = start_app(CollectionLookupSolve, %{columns: [%{id: 1, title: "Todo"}]})

    assert Solve.Lookup.events(Solve.Lookup.collection(app, :column)) == nil
  end

  test "event/2 returns nil for Solve.Collection and missing events" do
    app = start_app(CollectionLookupSolve, %{columns: [%{id: 1, title: "Todo"}]})

    columns = Solve.Lookup.collection(app, :column)
    column = Solve.Lookup.solve(app, {:column, 1})

    assert Solve.Lookup.event(columns, :rename) == nil
    assert Solve.Lookup.event(column, :missing) == nil
  end

  test "solve/2 on a collection source raises and points callers to collection/2" do
    app = start_app(CollectionLookupSolve, %{columns: [%{id: 1, title: "Todo"}]})

    assert_raise ArgumentError, ~r/use collection\/2/, fn ->
      Solve.Lookup.solve(app, :column)
    end
  end

  test "solve/2 on a collected child ref returns one item with events_" do
    app = start_app(CollectionLookupSolve, %{columns: [%{id: 1, title: "Todo"}]})

    column = Solve.Lookup.solve(app, {:column, 1})

    assert column.id == 1
    assert column.title == "Todo"

    assert {pid, {:solve_event, :rename}} = column.events_.rename
    assert pid == Solve.controller_pid(app, {:column, 1})
  end

  test "event/2 and event/3 return direct controller tuples for collected children" do
    app = start_app(CollectionLookupSolve, %{columns: [%{id: 1, title: "Todo"}]})

    column = Solve.Lookup.solve(app, {:column, 1})

    assert {pid, {:solve_event, :rename}} = Solve.Lookup.event(column, :rename)
    assert pid == Solve.controller_pid(app, {:column, 1})

    assert {^pid, {:solve_event, :rename, "Backlog"}} =
             Solve.Lookup.event(column, :rename, "Backlog")

    send(pid, {:solve_event, :rename, "Backlog"})

    assert_receive %Solve.Message{
                     type: :update,
                     payload: %Solve.Update{
                       app: ^app,
                       controller_name: {:column, 1},
                       exposed_state: %{id: 1, title: "Backlog"}
                     }
                   } = message

    assert %{^app => %Solve.Lookup.Updated{refs: [{:column, 1}], collections: []}} =
             Solve.Lookup.handle_message(message)

    assert Solve.Lookup.solve(app, {:column, 1}).title == "Backlog"
  end

  test "handle_message/1 reports collection source updates in Updated.collections" do
    app = start_app(CollectionLookupSolve, %{columns: [%{id: 1, title: "Todo"}]})

    updated =
      Solve.Lookup.handle_message(
        Solve.Message.update(app, :column, %Collection{
          ids: [1],
          items: %{1 => %{id: 1, title: "Todo"}}
        })
      )

    assert %{^app => %Solve.Lookup.Updated{refs: [], collections: [:column]}} = updated
  end

  test "handle_message/1 reports collected child updates in Updated.refs" do
    app = start_app(CollectionLookupSolve, %{columns: [%{id: 1, title: "Todo"}]})

    updated =
      Solve.Lookup.handle_message(
        Solve.Message.update(app, {:column, 1}, %{id: 1, title: "Backlog"})
      )

    assert %{^app => %Solve.Lookup.Updated{refs: [{:column, 1}], collections: []}} = updated
    assert Solve.Lookup.solve(app, {:column, 1}).title == "Backlog"
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
