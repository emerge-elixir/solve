defmodule Solve.AuditRegressionTest do
  use ExUnit.Case, async: false

  alias Solve.Collection

  defmodule Value do
    use Solve.Controller, events: [:set]
    @impl true
    def init(params, _dependencies), do: Map.take(params, [:value])
    def set(value), do: %{value: value}
  end

  defmodule Projection do
    use Solve.Controller
    @impl true
    def init(_params, _deps), do: make_ref()
    @impl true
    def expose(identity, %{items: items}, _params) do
      %{identity: identity, values: Enum.map(items, fn {_, item} -> item.value end)}
    end
  end

  defmodule Chain do
    use Solve
    @impl true
    def controllers do
      [
        controller!(name: :driver, module: Value, params: %{value: 1}),
        controller!(
          name: :middle,
          module: Value,
          dependencies: [:driver],
          params: fn %{dependencies: %{driver: value}} -> value end
        ),
        controller!(
          name: :leaf,
          module: Value,
          dependencies: [:middle],
          params: fn %{dependencies: %{middle: value}} -> value end
        )
      ]
    end
  end

  defmodule Items do
    use Solve
    @impl true
    def controllers do
      [
        controller!(name: :catalog, module: Value, params: %{value: [{1, %{value: false}}]}),
        controller!(
          name: :items,
          module: Value,
          variant: :collection,
          dependencies: [:catalog],
          collect: fn %{dependencies: %{catalog: %{value: entries}}} -> entries end
        ),
        controller!(
          name: :projection,
          module: Projection,
          dependencies: [items: collection(:items, fn _, item -> item.value end)]
        )
      ]
    end
  end

  defmodule Probe do
    use Solve.Controller
    @impl true
    def init(params, _deps) do
      [supervisor | _] = Process.get(:"$ancestors")
      send(params.test_pid, {:probe_started, params.name, self(), supervisor})

      case params.mode do
        :fail ->
          raise "initialization failed"

        :hang ->
          receive do
            :finish -> %{value: true}
          end

        :ok ->
          %{value: true}
      end
    end
  end

  defmodule Startup do
    use Solve
    @impl true
    def controllers do
      [
        controller!(
          name: :first,
          module: Probe,
          params: fn %{app_params: params} -> Map.merge(params, %{name: :first, mode: :ok}) end
        ),
        controller!(
          name: :second,
          module: Probe,
          dependencies: [:first],
          params: fn %{app_params: params} -> Map.put(params, :name, :second) end
        )
      ]
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "queued updates from replaced controllers cannot regress the graph" do
    app = start_app(Chain)
    driver = Solve.controller_pid(app, :driver)
    middle = Solve.controller_pid(app, :middle)

    suspended(app, fn ->
      set_and_wait(driver, 2)
      set_and_wait(middle, 999)
    end)

    eventually(fn -> Solve.controller_pid(app, :middle) != middle end)
    assert Solve.subscribe(app, :middle) == %{value: 2}
    eventually(fn -> Solve.subscribe(app, :leaf) == %{value: 2} end)
  end

  test "rapid filter changes never expose an invalid collection or restart the dependent" do
    app = start_app(Items)
    projection = Solve.controller_pid(app, :projection)
    monitor = Process.monitor(projection)
    original = Solve.subscribe(app, :projection)
    child = Solve.controller_pid(app, {:items, 1})

    suspended(app, fn ->
      set_and_wait(child, true)
      set_and_wait(child, false)
    end)

    eventually(fn -> Solve.subscribe(app, :items).items[1].value === false end)
    assert Solve.subscribe(app, :projection) == original
    refute_receive {:DOWN, ^monitor, :process, ^projection, _}, 50
  end

  @tag :capture_log
  test "a subscribe queued before target exit does not kill the app" do
    app = start_app(Chain)
    child = Solve.controller_pid(app, :driver)
    parent = self()

    suspended(app, fn ->
      spawn(fn ->
        result =
          try do
            Solve.subscribe(app, :driver, parent)
          catch
            :exit, reason -> {:exit, reason}
          end

        send(parent, {:subscription_result, result})
      end)

      eventually(fn ->
        {:messages, messages} = Process.info(app, :messages)
        Enum.any?(messages, &match?({:"$gen_call", _, {:subscribe, :driver, ^parent}}, &1))
      end)

      monitor = Process.monitor(child)
      Process.exit(child, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^child, :killed}
    end)

    assert_receive {:subscription_result, result}, 2_000
    refute match?({:exit, _}, result)
    assert Process.alive?(app)
    eventually(fn -> Solve.controller_pid(app, :driver) not in [nil, child] end)
  end

  test "normal app shutdown owns and stops every controller" do
    app = start_app(Chain)
    children = Enum.map([:driver, :middle, :leaf], &Solve.controller_pid(app, &1))
    monitors = Enum.map(children, &{Process.monitor(&1), &1})
    on_exit(fn -> Enum.each(children, &Process.exit(&1, :kill)) end)
    GenServer.stop(app)

    for {ref, pid} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end
  end

  test "collection identity and membership use exact comparisons" do
    collection = Collection.empty() |> Collection.put(1, :integer) |> Collection.put(1.0, :float)
    assert Collection.delete(collection, 1.0) == %Collection{ids: [1], items: %{1 => :integer}}
    refute Enum.member?(Collection.empty(), {:absent, nil})
    refute Enum.member?(Collection.put(Collection.empty(), :key, 1), {:key, 1.0})
    assert Enum.member?(Collection.put(Collection.empty(), :key, nil), {:key, nil})
  end

  test "reorder rejects missing, duplicate and omitted ids at the boundary" do
    collection = Collection.put(Collection.empty(), :a, %{})

    for ids <- [[:missing], [:a, :a], []] do
      assert_raise ArgumentError, fn -> Collection.reorder(collection, ids) end
    end
  end

  test "collection subscriptions receive exact numeric value changes" do
    app = start_app(Items)
    catalog = Solve.controller_pid(app, :catalog)
    set_and_wait(catalog, [{1, %{value: 1}}])
    eventually(fn -> Solve.subscribe(app, :items).items[1].value === 1 end)
    flush_updates()
    set_and_wait(Solve.controller_pid(app, {:items, 1}), 1.0)

    assert_receive %Solve.Message{
                     payload: %Solve.Update{
                       controller_name: :items,
                       exposed_state: %Collection{items: %{1 => %{value: value}}}
                     }
                   },
                   1_000

    assert value === 1.0
  end

  test "pre-populated bindings cannot hide self or unknown graph edges" do
    for {source, reason} <- [
          a: {:self_dependency, :a},
          missing: {:unknown_dependency, :a, :missing}
        ] do
      spec =
        Solve.ControllerSpec.controller!(
          name: :a,
          module: Value,
          dependency_bindings: [%{key: :dep, source: source, kind: :single, filter: nil}]
        )

      assert Solve.DependencyGraph.compile([spec]) == {:error, reason}
    end
  end

  test "managed dependencies ignore older revisions, generations and unversioned messages" do
    {:ok, controller} =
      Value.start_link(
        solve_app: self(),
        params: %{value: 0},
        generation: 10,
        dependencies: %{source: %{value: 1}},
        dependency_versions: %{source: {4, 1}}
      )

    on_exit(fn -> Process.exit(controller, :kill) end)
    send(controller, Solve.DependencyUpdate.replace(self(), :source, %{value: 2}, {5, 0}))

    for version <- [{4, 99}, {5, 0}, nil] do
      send(controller, Solve.DependencyUpdate.replace(self(), :source, %{value: 999}, version))
    end

    assert :sys.get_state(controller).dependencies.source == %{value: 2}
    send(controller, Solve.DependencyUpdate.replace(self(), :source, %{value: 3}, {5, 1}))
    assert :sys.get_state(controller).dependencies.source == %{value: 3}
  end

  test "slow live subscriptions return a cached value and attach without a restart" do
    app = start_app(Chain)
    driver = Solve.controller_pid(app, :driver)

    suspended(driver, fn ->
      assert Solve.subscribe(app, :driver) == %{value: 1}
      assert Solve.controller_pid(app, :driver) == driver
      assert :sys.get_state(app).restart_history == %{}
    end)

    eventually(fn -> :sys.get_state(app).pending_attachments == %{} end)
    flush_updates()
    set_and_wait(driver, 2)

    assert_receive %Solve.Message{
      payload: %Solve.Update{controller_name: :driver, exposed_state: %{value: 2}}
    }
  end

  @tag :capture_log
  test "forced app death cleans up an unresponsive child through its supervisor" do
    app = start_app(Chain)
    supervisor = :sys.get_state(app).supervisor
    driver = Solve.controller_pid(app, :driver)
    child_ref = Process.monitor(driver)
    supervisor_ref = Process.monitor(supervisor)
    :sys.suspend(driver)
    Process.exit(app, :kill)
    assert_receive {:DOWN, ^child_ref, :process, ^driver, _}, 3_000
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, _}, 3_000
  end

  test "collection churn retains only live targets and requested subscriptions" do
    app = start_app(Items)
    catalog = Solve.controller_pid(app, :catalog)
    assert Solve.subscribe(app, {:items, :future}) == nil

    for id <- 1..1_000 do
      set_and_wait(catalog, [{id, %{value: false}}])
      eventually(fn -> Solve.subscribe(app, :items).ids == [id] end)
    end

    set_and_wait(catalog, [])
    eventually(fn -> Solve.subscribe(app, :items).ids == [] end)
    state = :sys.get_state(app)
    assert map_size(state.targets) == 2
    assert map_size(state.target_by_monitor) == 2
    assert state.restart_history == %{}
    assert state.pending_attachments == %{}
    assert Map.keys(state.subscribers) |> Enum.sort() == [:items, {:items, :future}]

    set_and_wait(catalog, [{:future, %{value: true}}])

    assert_receive %Solve.Message{
      payload: %Solve.Update{controller_name: {:items, :future}, exposed_state: %{value: true}}
    }
  end

  test "subscriber death removes empty target registration buckets" do
    app = start_app(Items)

    subscriber =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    Solve.subscribe(app, {:items, :missing}, subscriber)
    send(subscriber, :stop)
    eventually(fn -> :sys.get_state(app).subscribers == %{} end)
    assert :sys.get_state(app).subscriber_monitors == %{}
  end

  @tag :capture_log
  test "recent restart history survives target removal and expires while idle" do
    app = start_app(Items)
    child = Solve.controller_pid(app, {:items, 1})
    Process.exit(child, :kill)
    eventually(fn -> Solve.controller_pid(app, {:items, 1}) not in [nil, child] end)
    set_and_wait(Solve.controller_pid(app, :catalog), [])
    eventually(fn -> Solve.subscribe(app, :items).ids == [] end)
    state = :sys.get_state(app)
    assert length(state.restart_history[{:items, 1}]) == 1
    assert is_reference(state.restart_timer)

    # Age only timestamps, then exercise the same callback used by the idle timer.
    :sys.replace_state(app, fn state ->
      put_in(state.restart_history[{:items, 1}], [System.monotonic_time(:millisecond) - 5_001])
    end)

    send(app, :prune_restart_history)
    assert :sys.get_state(app).restart_history == %{}
  end

  @tag :capture_log
  test "removing and recreating a collection ID cannot evade its restart budget" do
    app = start_app(Items)
    ref = Process.monitor(app)
    catalog = Solve.controller_pid(app, :catalog)

    for _ <- 1..3 do
      child = Solve.controller_pid(app, {:items, 1})
      Process.exit(child, :kill)
      eventually(fn -> Solve.controller_pid(app, {:items, 1}) not in [nil, child] end)
      set_and_wait(catalog, [])
      eventually(fn -> Solve.subscribe(app, :items).ids == [] end)
      set_and_wait(catalog, [{1, %{value: false}}])
      eventually(fn -> is_pid(Solve.controller_pid(app, {:items, 1})) end)
    end

    Process.exit(Solve.controller_pid(app, {:items, 1}), :kill)

    assert_receive {:DOWN, ^ref, :process, ^app,
                    {:controller_restart_limit_exceeded, {:items, 1}, :killed}},
                   2_000
  end

  test "graph canonicalization is idempotent and rejects inconsistent or cyclic bindings" do
    import Solve.ControllerSpec
    a = controller!(name: :a, module: Value)
    b = controller!(name: :b, module: Value, dependencies: [:a])
    assert {:ok, normalized} = Solve.ControllerSpec.validate(b)
    assert Solve.ControllerSpec.validate(normalized) == {:ok, normalized}

    assert {:error, {:inconsistent_dependency_sources, :b}} =
             Solve.ControllerSpec.validate(%{normalized | dependencies: [:wrong]})

    circular = %{a | dependency_bindings: [%{key: :b, source: :b, kind: :single, filter: nil}]}
    assert {:error, {:cycle, _}} = Solve.DependencyGraph.compile([circular, normalized])
  end

  test "dispatch requires four arguments for an explicit app and preserves implicit atom payloads" do
    name = __MODULE__.DispatchApp
    app = start_app(Chain, name: name)
    assert_raise ArgumentError, ~r/dispatch\/4/, fn -> Solve.dispatch(app, :driver, :set) end

    for server <- [app, name, {name, node()}] do
      assert Solve.dispatch(server, :driver, :set, 2) == :ok
    end

    eventually(fn -> Solve.subscribe(app, :driver) == %{value: 2} end)
    Process.put(:solve_app, app)

    try do
      assert Solve.dispatch(:driver, :set, :atom_payload) == :ok
      eventually(fn -> Solve.subscribe(app, :driver) == %{value: :atom_payload} end)
      assert Solve.dispatch(:driver, :set) == :ok
      eventually(fn -> Solve.subscribe(app, :driver) == %{value: %{}} end)
    after
      Process.delete(:solve_app)
    end

    assert Solve.dispatch(app, :missing, :set, %{}) == :ok
  end

  test "bulk collections and operation sequences preserve exact ordered keys" do
    assert_raise ArgumentError, fn -> Collection.new(a: 1, a: 2) end
    entries = for id <- [1, 1.0, nil, false, :a, {:tuple, 1}], do: {id, %{id: id}}
    initial = Collection.new(entries)
    assert Collection.to_list(initial) === entries

    Enum.reduce(1..100, initial, fn step, collection ->
      id = Enum.at(initial.ids, rem(step, length(initial.ids)))
      next = collection |> Collection.delete(id) |> Collection.put(id, %{step: step})
      next = Collection.reorder(next, Enum.reverse(next.ids))
      assert MapSet.new(next.ids) == MapSet.new(Map.keys(next.items))
      assert length(next.ids) == map_size(next.items)
      assert Enum.to_list(next) == Enum.map(next.ids, &{&1, Map.fetch!(next.items, &1)})
      next
    end)
  end

  @tag :capture_log
  test "partial startup failure releases already started children" do
    assert {:error, {:controller_restart_limit_exceeded, :second, _}} =
             Startup.start_link(name: nil, params: %{test_pid: self(), mode: :fail})

    assert_receive {:probe_started, :first, first, supervisor}
    eventually(fn -> not Process.alive?(first) and not Process.alive?(supervisor) end)

    for _ <- 1..4 do
      assert_receive {:probe_started, :second, failed, ^supervisor}
      refute Process.alive?(failed)
    end
  end

  @tag :capture_log
  test "owner death during initialization is bounded by the startup timeout" do
    parent = self()
    name = __MODULE__.Starting

    spawn(fn ->
      Process.flag(:trap_exit, true)

      Startup.start_link(
        name: name,
        controller_start_timeout: 100,
        params: %{test_pid: parent, mode: :hang}
      )
    end)

    assert_receive {:probe_started, :first, first, supervisor}
    assert_receive {:probe_started, :second, second, ^supervisor}
    owner = Process.whereis(name)
    assert is_pid(owner)
    ref = Process.monitor(supervisor)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^supervisor, _}, 2_000
    refute Process.alive?(first)
    refute Process.alive?(second)
  end

  defp start_app(module, opts \\ []) do
    {:ok, app} = module.start_link(Keyword.put_new(opts, :name, nil))

    on_exit(fn ->
      try do
        GenServer.stop(app, :shutdown)
      catch
        :exit, _ -> :ok
      end
    end)

    app
  end

  defp set_and_wait(pid, value) do
    Solve.Controller.dispatch(pid, :set, value)
    Solve.Controller.subscribe(pid)
  end

  defp suspended(pid, fun) do
    :sys.suspend(pid)

    try do
      fun.()
    after
      if Process.alive?(pid), do: :sys.resume(pid)
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp flush_updates do
    receive do
      %Solve.Message{} -> flush_updates()
    after
      0 -> :ok
    end
  end
end
