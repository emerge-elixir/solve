Code.require_file("../support/lookup_recovery_helper.exs", __DIR__)

defmodule Solve.LookupRecoveryTest do
  use ExUnit.Case, async: false

  alias Solve.Lookup
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
    assert cache() == %{apps: %{}, aliases: %{}}
    assert Lookup.solve(app, :source).value == 1

    for invalid <- [0, -1, :infinity, nil] do
      Application.put_env(:solve, :lookup_timeout, invalid)
      assert Lookup.solve(app, :source).value == 1
      assert_raise ArgumentError, fn -> Lookup.solve(app, :other) end
    end
  end

  defp cache, do: Process.get({Lookup, :cache}, %{apps: %{}, aliases: %{}})

  defp stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end
end
