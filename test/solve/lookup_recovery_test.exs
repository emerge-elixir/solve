Code.require_file("../support/lookup_recovery_helper.exs", __DIR__)

defmodule Solve.LookupRecoveryTest do
  use ExUnit.Case, async: false

  alias Solve.Lookup
  alias Solve.Lookup.Recovery
  alias Solve.Lookup.Watcher
  alias Solve.LookupRecoveryFixture.App

  defmodule Gate do
    def whereis_name({owner, key}) do
      send(owner, {:probe, key, self()})

      receive do
        {:resolve, pid} -> pid
      end
    end
  end

  defmodule SlowRegistry do
    def whereis_name(pid) do
      Process.sleep(30)
      pid
    end
  end

  defmodule PartialApp do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])
    @impl true
    def init(opts), do: {:ok, %{owner: opts[:owner], waiting: [], open?: false}}
    @impl true
    def handle_call({:snapshot, target, subscriber}, from, state) do
      send(state.owner, {:snapshot, target, subscriber})

      if target == :source and not state.open? do
        {:noreply, %{state | waiting: [from | state.waiting]}}
      else
        {:reply, snapshot(target), state}
      end
    end

    def handle_call({:unsubscribe, _target, _subscriber}, _from, state), do: {:reply, :ok, state}
    @impl true
    def handle_cast(:open, state) do
      Enum.each(state.waiting, &GenServer.reply(&1, snapshot(:source)))
      {:noreply, %{state | waiting: [], open?: true}}
    end

    defp snapshot(target) do
      %Solve.Update{
        app: self(),
        controller_name: target,
        kind: :item,
        version: {0, 0},
        exposed_state: %{value: if(target == :source, do: 1, else: 2)}
      }
    end
  end

  defmodule Auto do
    use GenServer
    use Solve.Lookup
    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call({:run, fun}, _, state), do: {:reply, fun.(), state}
    @impl Solve.Lookup
    def handle_solve_updated(updated, state) do
      values = Enum.map(state.targets, &Lookup.solve(state.app, &1).value)
      send(state.owner, {:rendered, self(), updated, values})
      {:ok, state}
    end
  end

  defmodule Manual do
    use GenServer
    use Solve.Lookup, handle_info: :manual
    @impl true
    defdelegate init(state), to: Auto
    @impl true
    defdelegate handle_call(message, from, state), to: Auto
    @impl true
    def handle_info(message, state) do
      case Lookup.handle_message(message) do
        changed when map_size(changed) == 0 ->
          {:noreply, state}

        changed ->
          {:ok, state} = Auto.handle_solve_updated(changed, state)
          {:noreply, state}
      end
    end
  end

  setup do
    previous =
      Map.new([:lookup_timeout, :lookup_recovery], &{&1, Application.get_env(:solve, &1)})

    Application.put_env(:solve, :lookup_timeout, 60)
    Application.put_env(:solve, :lookup_recovery, initial_delay: 10, max_delay: 40, jitter: 0)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:solve, key)
        {key, value} -> Application.put_env(:solve, key, value)
      end)
    end)

    :ok
  end

  test "partial snapshots and pushes are staged until the whole wanted set is restored" do
    name = :lookup_partial_round
    first = App.boot(name)
    view = view(Auto, name, [:source, :other])

    run(view, fn ->
      Lookup.solve(name, :source)
      Lookup.solve(name, :other)
    end)

    GenServer.stop(first)
    replacement = start_supervised!({PartialApp, owner: self(), name: name})
    assert_receive {:snapshot, :other, ^view}, 1_000
    assert_receive {:snapshot, :source, ^view}, 1_000
    eventually(fn -> match?({:reconnecting, _}, run(view, fn -> Lookup.status(name) end)) end)
    assert run(view, fn -> Map.keys(cache().apps[replacement].refs) end) == [:other]

    send(
      view,
      Solve.Update.message(%Solve.Update{
        app: replacement,
        controller_name: :other,
        kind: :item,
        version: {0, 1},
        exposed_state: %{value: 3}
      })
    )

    run(view, fn -> :ok end)
    refute_receive {:rendered, ^view, _, _}, 20
    GenServer.cast(replacement, :open)
    assert_receive {:rendered, ^view, %{^replacement => _}, [1, 3]}, 1_000
    assert run(view, fn -> Lookup.status(name) end) == {:connected, replacement}
  end

  test "canceling a pending target completes the rest without resurrecting it" do
    name = :lookup_partial_cancel
    first = App.boot(name)
    view = view(Auto, name, [:other])

    run(view, fn ->
      Lookup.solve(name, :source)
      Lookup.solve(name, :other)
    end)

    GenServer.stop(first)
    replacement = start_supervised!({PartialApp, owner: self(), name: name})
    assert_receive {:snapshot, :other, ^view}, 1_000
    assert_receive {:snapshot, :source, ^view}, 1_000
    assert :ok = run(view, fn -> Lookup.unsubscribe(name, :source) end)
    assert_receive {:rendered, ^view, %{^replacement => %{refs: [:other]}}, [2]}, 1_000
    GenServer.cast(replacement, :open)
    assert run(view, fn -> Map.keys(cache().apps[replacement].refs) end) == [:other]
    assert :ok = run(view, fn -> Lookup.unsubscribe(name, :other) end)
    assert run(view, fn -> Recovery.state().bindings end) == %{}
  end

  test "manual forwarding recovers a named app with no external watcher" do
    name = :lookup_manual_recovery
    app = App.boot(name)
    view = view(Manual, name, [:source])
    run(view, fn -> Lookup.solve(name, :source) end)
    GenServer.stop(app)
    second = App.boot(name)
    on_exit(fn -> stop(second) end)
    assert_receive {:rendered, ^view, %{^second => _}, [1]}, 1_000
  end

  test "node/app absence keeps retrying at the cap and reads do not restart the chain" do
    app = :lookup_missing_backoff
    assert catch_exit(Lookup.solve(app, :source))
    binding = Recovery.get_binding(app)
    watcher = elem(Recovery.state().watcher, 0)

    for expected <- [20, 40, 40, 40] do
      assert_receive {:solve_lookup, :failed, {^watcher, ^app, token, _, ^expected}} = failure,
                     1_000

      assert token == binding.token
      assert Lookup.handle_message(failure) == %{}
      before = :sys.get_state(watcher).entries[app]
      for _ <- 1..10, do: assert(catch_exit(Lookup.solve(app, :source)))
      after_reads = :sys.get_state(watcher).entries[app]
      assert before.token == after_reads.token
      assert Recovery.get_binding(app).delay == expected
    end

    assert :ok = Lookup.unsubscribe(app, :source)
    monitor = Process.monitor(watcher)
    assert_receive {:DOWN, ^monitor, :process, ^watcher, _}, 1_000
  end

  test "new offline targets are remembered without starting synchronous acquisition" do
    name = :lookup_offline_targets
    assert catch_exit(Lookup.solve(name, :source))
    assert catch_exit(Lookup.solve(name, :other))
    assert Map.keys(Recovery.get_binding(name).targets) == [:other, :source]
    app = App.boot(name)
    on_exit(fn -> stop(app) end)
    assert_receive {:solve_lookup, :recover, {_, ^name, _, ^app}} = recover, 1_000
    assert %{^app => %{refs: refs}} = Lookup.handle_message(recover)
    assert Enum.sort(refs) == [:other, :source]
  end

  test "a killed watcher restarts with new tokens and ignores its stale results" do
    name = :lookup_watcher_crash
    assert catch_exit(Lookup.solve(name, :source))
    old = Recovery.get_binding(name)
    {watcher, monitor} = Recovery.state().watcher
    Process.exit(watcher, :kill)
    assert_receive {:solve_lookup_watcher_down, ^monitor, :process, ^watcher, :killed} = down
    assert Lookup.handle_message(down) == %{}
    refute Recovery.get_binding(name).token == old.token
    app = App.boot(name)
    on_exit(fn -> stop(app) end)

    assert Lookup.handle_message({:solve_lookup, :recover, {watcher, name, old.token, app}}) ==
             %{}

    assert cache().apps == %{}
    assert_receive {:solve_lookup, :restart, _} = restart, 1_000
    Lookup.handle_message(restart)
    assert_receive {:solve_lookup, :recover, {_, ^name, _, ^app}} = recover, 1_000
    assert %{^app => _} = Lookup.handle_message(recover)
  end

  test "cancellation terminates stuck discovery, and stale timer/probe messages cannot restart it" do
    key = make_ref()
    app = {:via, Gate, {self(), key}}
    {:ok, watcher} = Watcher.start(self())
    on_exit(fn -> stop(watcher) end)
    config = Watcher.config!()
    token = make_ref()

    Watcher.sync(watcher, %{app => %{token: token, config: config, delay: 10, probe_address: app}})

    assert_receive {:probe, ^key, probe}, 1_000
    state = :sys.get_state(watcher)
    probe_token = state.probe.token
    monitor = Process.monitor(probe)
    Watcher.sync(watcher, %{})
    assert_receive {:DOWN, ^monitor, :process, ^probe, :killed}, 1_000
    send(watcher, {:probe_result, probe_token, {:ok, self()}})
    send(watcher, {:retry, app, token, make_ref()})
    assert :sys.get_state(watcher).entries == %{}
    refute_receive {:solve_lookup, :recover, _}, 20
  end

  test "consumer death kills both watcher and a blocked custom resolver" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, watcher} = Watcher.start(owner)
    app = {:via, Gate, {self(), :death}}

    Watcher.sync(watcher, %{
      app => %{token: make_ref(), config: Watcher.config!(), delay: 10, probe_address: app}
    })

    assert_receive {:probe, :death, probe}, 1_000
    wm = Process.monitor(watcher)
    pm = Process.monitor(probe)
    send(owner, :stop)
    assert_receive {:DOWN, ^wm, :process, ^watcher, :normal}, 1_000
    assert_receive {:DOWN, ^pm, :process, ^probe, :killed}, 1_000
  end

  test "cold name resolution and snapshot share a deadline" do
    app = App.boot(nil)
    on_exit(fn -> stop(app) end)
    :sys.suspend(app)

    assert {:timeout, {GenServer, :call, [^app, _, remaining]}} =
             catch_exit(Lookup.solve({:via, SlowRegistry, app}, :source))

    assert remaining <= 30
    :sys.resume(app)
    assert :ok = Lookup.unsubscribe({:via, SlowRegistry, app}, :source)
  end

  test "unknown targets allocate no intent and malformed budgets leave warm reads intact" do
    app = App.boot(nil)
    on_exit(fn -> stop(app) end)
    assert Lookup.solve(app, :unknown) == nil
    assert Recovery.state().bindings == %{}
    assert Lookup.solve(app, :source).value == 1

    for invalid <- [0, -1, :infinity, nil] do
      Application.put_env(:solve, :lookup_timeout, invalid)
      assert Lookup.solve(app, :source).value == 1
      assert_raise ArgumentError, fn -> Lookup.solve(app, :other) end
    end
  end

  test "nodeup expedites discovery but old queued timers cannot bypass the next backoff" do
    {:ok, watcher} = Watcher.start(self())
    on_exit(fn -> stop(watcher) end)
    app = {:lookup_timer_missing, node()}
    config = %{Watcher.config!() | initial: 1_000, max: 8_000}
    token = make_ref()

    Watcher.sync(watcher, %{
      app => %{token: token, config: config, delay: 4_000, probe_address: app}
    })

    old = :sys.get_state(watcher).entries[app]
    send(watcher, {:nodeup, node()})
    assert_receive {:solve_lookup, :failed, {^watcher, ^app, ^token, _, 8_000}}, 1_000
    current = :sys.get_state(watcher).entries[app]
    refute old.timer_token == current.timer_token
    send(watcher, {:retry, app, token, old.timer_token})
    assert :sys.get_state(watcher).entries[app].timer_token == current.timer_token
    for _ <- 1..20, do: send(watcher, {:nodeup, node()})
    assert :sys.get_state(watcher).probe == nil
    assert :sys.get_state(watcher).entries[app].delay == 8_000
  end

  test "repeated app recovery and cancellation release all intent, monitors and registrations" do
    baseline = Process.info(self(), :monitors)
    name = :lookup_recovery_churn

    for _ <- 1..10 do
      first = App.boot(name)
      Lookup.solve(name, :source)
      GenServer.stop(first)
      assert_receive {:solve_lookup_down, _, :process, ^first, _} = down
      Lookup.handle_message(down)
      second = App.boot(name)
      assert_receive {:solve_lookup, :recover, {_, ^name, _, ^second}} = recover, 1_000
      assert %{^second => _} = Lookup.handle_message(recover)
      assert :ok = Lookup.unsubscribe(name, :source)
      assert Recovery.state().bindings == %{}
      assert Recovery.state().watcher == nil
      assert cache() == %{apps: %{}, aliases: %{}}
      assert :sys.get_state(second).subscribers == %{}
      GenServer.stop(second)
    end

    assert Process.info(self(), :monitors) == baseline
  end

  test "a pending named binding does not block an independently acquired healthy PID binding" do
    name = :lookup_independent_bindings
    app = start_supervised!({PartialApp, owner: self(), name: name})
    assert Lookup.solve(app, :other).value == 2
    assert catch_exit(Lookup.solve(name, :source))
    assert {:reconnecting, _} = Lookup.status(name)
    assert Lookup.status(app) == {:connected, app}
    assert Lookup.solve(app, :other).value == 2

    update =
      Solve.Update.message(%Solve.Update{
        app: app,
        controller_name: :other,
        kind: :item,
        version: {0, 1},
        exposed_state: %{value: 3}
      })

    assert %{^app => %{refs: [:other]}} = Lookup.handle_message(update)
    assert Lookup.solve(app, :other).value == 3
    Lookup.unsubscribe(name, :source)
    Lookup.unsubscribe(app, :other)
  end

  defp view(module, app, targets) do
    {:ok, pid} = GenServer.start_link(module, %{owner: self(), app: app, targets: targets})
    on_exit(fn -> stop(pid) end)
    pid
  end

  defp run(pid, fun), do: GenServer.call(pid, {:run, fun})
  defp cache, do: Process.get({Lookup, :cache}, %{apps: %{}, aliases: %{}})

  defp stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end
