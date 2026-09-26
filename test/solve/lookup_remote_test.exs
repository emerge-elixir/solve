Code.require_file("../support/lookup_recovery_helper.exs", __DIR__)

defmodule Solve.LookupRemoteTest do
  use ExUnit.Case, async: false

  alias Solve.Lookup
  alias Solve.Lookup.Recovery
  alias Solve.Lookup.Watcher
  alias Solve.LookupRecoveryFixture.App

  defmodule View do
    use GenServer
    use Solve.Lookup
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts), do: {:ok, Map.new(opts)}
    @impl true
    def handle_call({:run, fun}, _from, state) do
      result =
        try do
          fun.()
        catch
          kind, reason -> {kind, reason}
        end

      {:reply, result, state}
    end

    @impl Solve.Lookup
    def handle_solve_updated(updated, state) do
      values = Enum.map(state.targets, &Lookup.solve(state.app, &1))
      send(state.owner, {:render, self(), updated, values})
      {:ok, state}
    end

    @impl Solve.Lookup
    def handle_solve_connection_changed(app, status, state) do
      send(state.owner, {:connection, self(), app, status})
      {:ok, state}
    end
  end

  setup do
    old = Application.get_env(:solve, :lookup_recovery)
    Application.put_env(:solve, :lookup_recovery, initial_delay: 10, max_delay: 40, jitter: 0)
    on_exit(fn -> restore_env(:lookup_recovery, old) end)
    :ok
  end

  test "remote warm named/PID reads, nil values, collections, updates and cleanup issue no queries" do
    {peer, host} = peer()
    app = boot(peer)
    address = {:lookup_recovery_app, host}
    assert Lookup.solve(address, :source).value == 1
    assert Lookup.solve(app, :off) == nil
    assert Lookup.collection(address, :items).ids === [1, 1.0]
    old = Lookup.solve(address, :source)
    Lookup.dispatch(Lookup.event(old, :set, 7))
    assert_receive %Solve.Message{payload: %{controller_name: :source}} = update, 2_000

    no_queries(fn ->
      assert Lookup.handle_message(update) != %{}

      for _ <- 1..100 do
        assert Lookup.solve(address, :source).value == 7
        assert Lookup.solve(app, :source).value == 7
        assert Lookup.solve(app, :off) == nil
        assert Lookup.collection(address, :items).ids === [1, 1.0]
        assert Lookup.status(address) == {:connected, app}
        assert :ok = Lookup.cleanup()
      end
    end)

    assert Recovery.state().watcher == nil
    assert map_size(cache().apps) == 1
    assert map_size(cache().apps[app].refs) == 3
  end

  test "app-only restart automatically rerenders equal values with new event routes" do
    {peer, host} = peer()
    first = boot(peer)
    address = {:lookup_recovery_app, host}
    view = view(address, [:source, :other])
    [old, _] = run(view, fn -> Enum.map([:source, :other], &Lookup.solve(address, &1)) end)
    stop_remote(peer, first)
    assert_receive {:connection, ^view, ^address, {:reconnecting, _}}, 2_000
    assert run(view, fn -> cache().apps end) == %{}
    second = boot(peer)
    assert_receive {:connection, ^view, ^address, {:connected, ^second}}, 2_000
    assert_receive {:render, ^view, %{^second => changed}, [fresh, %{value: 2}]}, 2_000
    assert Enum.sort(changed.refs) == [:other, :source]
    assert fresh.value == old.value
    refute Lookup.event(fresh, :set) == Lookup.event(old, :set)
    assert run(view, fn -> Recovery.state().watcher end) == nil
    Lookup.dispatch(Lookup.event(fresh, :set, 12))
    assert_receive {:render, ^view, _, [%{value: 12}, _]}, 2_000
  end

  test "first failed acquisition retains intent and recovers without another read" do
    {peer, host} = peer()
    address = {:lookup_recovery_app, host}
    view = view(address)
    assert {:exit, {:noproc, _}} = run(view, fn -> Lookup.solve(address, :source) end)
    assert_receive {:connection, ^view, ^address, {:reconnecting, _}}, 2_000

    assert {:trace_calls, []} =
             run(view, fn ->
               no_queries(fn ->
                 for _ <- 1..100 do
                   assert {{:reconnecting, _}, _} = catch_exit(Lookup.solve(address, :source))
                 end
               end)
             end)

    app = boot(peer)
    assert_receive {:render, ^view, %{^app => _}, [%{value: 1}]}, 2_000
    assert run(view, fn -> Lookup.status(address) end) == {:connected, app}
  end

  @tag :capture_log
  test "partition restores subscriptions to the same surviving PID without replaying actions" do
    {peer, host} = peer()
    app = boot(peer)
    view = view(app)
    run(view, fn -> Lookup.solve(app, :source) end)
    old_monitor = run(view, fn -> cache().apps[app].monitor end)
    cookie = Node.get_cookie()
    :peer.call(peer, :logger, :set_primary_config, [:level, :emergency])
    Node.set_cookie(host, :wrong_lookup_cookie)
    assert Node.disconnect(host)
    assert_receive {:connection, ^view, ^app, {:reconnecting, :noconnection}}, 2_000
    assert :peer.call(peer, Process, :alive?, [app])
    assert run(view, fn -> cache().apps end) == %{}
    Node.set_cookie(host, cookie)
    assert_receive {:connection, ^view, ^app, {:connected, ^app}}, 3_000
    assert_receive {:render, ^view, %{^app => _}, [%{value: 1} = fresh]}, 2_000
    send(view, {:solve_lookup_down, old_monitor, :process, app, :noconnection})
    assert run(view, fn -> Lookup.status(app) end) == {:connected, app}
    Lookup.dispatch(Lookup.event(fresh, :set, 4))
    assert_receive {:render, ^view, _, [%{value: 4}]}, 2_000
  end

  test "live remote name remains pinned, named dispatch resolves current owner, missing target is cold" do
    {peer, host} = peer()
    first = boot(peer)
    address = {:lookup_recovery_app, host}
    Lookup.solve(address, :source)
    :peer.call(peer, Process, :unregister, [:lookup_recovery_app])
    second = boot(peer)
    assert Lookup.solve(address, :source).value == 1
    assert cache().aliases[address] == first
    Lookup.dispatch(address, :source, :set, 23)
    assert cache().aliases[address] == first
    assert Lookup.solve(address, :other).value == 2
    assert cache().aliases[address] == second
    assert Lookup.solve(address, :source).value == 23
    assert Lookup.solve(first, :source).value == 1
    assert :ok = Lookup.unsubscribe(address, :source)
    assert Map.has_key?(cache().apps[first].refs, :source)
  end

  test "global atom keys and same-node tuples are local resolvers, not remote names" do
    name = :lookup_recovery_global_atom
    app = App.boot({:global, name})
    on_exit(fn -> stop(app) end)
    assert Lookup.solve({:global, name}, :source).value == 1
    assert :ok = Lookup.unsubscribe({:global, name}, :source)
    local = App.boot(:lookup_recovery_local)
    on_exit(fn -> stop(local) end)
    assert Lookup.solve({:lookup_recovery_local, node()}, :source).value == 1
    no_queries(fn -> assert Lookup.solve(local, :source).value == 1 end)
  end

  test "unsubscribe with a queued candidate cannot restore removed interest" do
    {peer, host} = peer()
    first = boot(peer)
    address = {:lookup_recovery_app, host}
    Lookup.solve(address, :source)
    stop_remote(peer, first)
    assert_receive {:solve_lookup_down, _, :process, ^first, _} = down, 2_000
    Lookup.handle_message(down)
    second = boot(peer)
    assert_receive {:solve_lookup, :recover, {_watcher, ^address, _, ^second}} = candidate, 2_000
    assert :ok = Lookup.unsubscribe(address, :source)
    assert Lookup.handle_message(candidate) == %{}
    assert Lookup.status(address) == :unknown
    assert cache() == %{apps: %{}, aliases: %{}}
    assert :peer.call(peer, :sys, :get_state, [second]).subscribers == %{}
    assert Recovery.state().watcher == nil
  end

  test "watcher and bounded probe die with their owner" do
    {peer, host} = peer()
    address = {:lookup_recovery_app, host}
    view = view(address)
    run(view, fn -> catch_exit(Lookup.solve(address, :source)) end)
    {watcher, _} = run(view, fn -> Recovery.state().watcher end)
    monitor = Process.monitor(watcher)
    GenServer.stop(view)
    assert_receive {:DOWN, ^monitor, :process, ^watcher, :normal}, 2_000
    assert :peer.call(peer, Process, :whereis, [:lookup_recovery_app]) == nil
  end

  test "explicit dead PID is terminal and cannot follow a registered replacement" do
    {peer, _host} = peer()
    first = boot(peer)
    view = view(first)
    run(view, fn -> Lookup.solve(first, :source) end)
    stop_remote(peer, first)
    assert_receive {:connection, ^view, ^first, {:unavailable, _}}, 2_000
    _second = boot(peer)
    assert run(view, fn -> Recovery.state().watcher end) == nil
    assert {:exit, {{:unavailable, _}, _}} = run(view, fn -> Lookup.solve(first, :source) end)
    refute_receive {:render, ^view, _, _}, 50
  end

  test "backoff saturates, jitter remains bounded, and configuration is validated only on acquisition" do
    delays = Enum.scan(1..10, 250, fn _, base -> Watcher.next_delay(base, 30_000) end)
    assert delays == [500, 1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000, 30_000]

    for _ <- 1..100 do
      assert Watcher.delay(30_000, 0.2) in 24_000..30_000
      assert Watcher.delay(30_000, 0) == 30_000
    end

    app = App.boot(nil)
    on_exit(fn -> stop(app) end)
    assert Lookup.solve(app, :source).value == 1
    Application.put_env(:solve, :lookup_recovery, initial_delay: 0)
    assert Lookup.solve(app, :source).value == 1
    assert_raise ArgumentError, fn -> Lookup.solve(app, :other) end
  end

  test "cold snapshot has a finite budget, pending reads do not repeat it, cancellation orders later acquisition" do
    {peer, _host} = peer()
    app = boot(peer)
    old = Application.get_env(:solve, :lookup_timeout)
    Application.put_env(:solve, :lookup_timeout, 40)
    on_exit(fn -> restore_env(:lookup_timeout, old) end)
    :peer.call(peer, :sys, :suspend, [app])

    assert {:timeout, {GenServer, :call, [^app, {:snapshot, :source, _}, timeout]}} =
             catch_exit(Lookup.solve(app, :source))

    assert timeout <= 40
    assert {{:reconnecting, _}, _} = catch_exit(Lookup.solve(app, :source))
    # A timed-out raw registration remains possible. Local cancellation must not
    # send a late unsubscribe after the next deliberate acquisition.
    assert :ok = Lookup.unsubscribe(app, :source)
    :peer.call(peer, :sys, :resume, [app])
    assert Lookup.solve(app, :source).value == 1
    Lookup.dispatch(Lookup.event(Lookup.solve(app, :source), :set, 9))
    assert_receive %Solve.Message{payload: %{exposed_state: %{value: 9}}} = update, 2_000
    assert Lookup.handle_message(update) != %{}
    assert Lookup.solve(app, :source).value == 9
  end

  test "a client starting before the remote node recovers through ordinary distribution autoconnect" do
    distribution()
    short = :peer.random_name()
    host_part = node() |> Atom.to_string() |> String.split("@") |> List.last()
    host = String.to_atom("#{short}@#{host_part}")
    address = {:lookup_recovery_app, host}
    view = view(address)

    assert {:exit, {{:badrpc, :nodedown}, _}} =
             run(view, fn -> Lookup.solve(address, :source) end)

    {peer, ^host} = peer(short)
    app = boot(peer)
    assert_receive {:render, ^view, %{^app => _}, [%{value: 1}]}, 3_000
  end

  test "source/item subscriptions retain exact numeric identities through recovery and cancellation" do
    {peer, host} = peer()
    first = boot(peer)
    address = {:lookup_recovery_app, host}
    Lookup.collection(address, :items)
    assert Lookup.solve(address, {:items, 1}).value == :int
    assert Lookup.solve(address, {:items, 1.0}).value == :float
    stop_remote(peer, first)
    assert_receive {:solve_lookup_down, _, :process, ^first, _} = down, 2_000
    Lookup.handle_message(down)
    Lookup.unsubscribe(address, {:items, 1})
    second = boot(peer)
    token = Recovery.get_binding(address).token
    assert_receive {:solve_lookup, :recover, {_, ^address, ^token, ^second}} = recovery, 2_000

    assert %{^second => %{collections: [:items], refs: [{:items, id}]}} =
             Lookup.handle_message(recovery)

    assert id === 1.0
    refute Map.has_key?(cache().apps[second].refs, {:items, 1})
    assert Lookup.collection(address, :items).ids === [1, 1.0]
    Lookup.unsubscribe(address, :items)
    Lookup.unsubscribe(address, {:items, 1.0})
    assert Recovery.state().bindings == %{}
    assert :peer.call(peer, :sys, :get_state, [second]).subscribers == %{}
  end

  test "different aliases split safely after restart without rebinding a pinned PID" do
    {peer, host} = peer()
    first = boot(peer)
    address = {:lookup_recovery_app, host}
    global = {:global, {:lookup_alias, make_ref()}}
    assert :yes = :global.register_name(elem(global, 1), first)
    on_exit(fn -> :global.unregister_name(elem(global, 1)) end)
    Lookup.solve(address, :source)
    Lookup.solve(global, :source)
    Lookup.solve(first, :source)
    stop_remote(peer, first)
    assert_receive {:solve_lookup_down, _, :process, ^first, _} = down, 2_000
    Lookup.handle_message(down)
    second = boot(peer)
    third = :peer.call(peer, App, :boot, [:lookup_recovery_other])
    :global.unregister_name(elem(global, 1))
    assert :yes = :global.register_name(elem(global, 1), third)
    assert_receive {:solve_lookup, :recover, {_, ^address, _, ^second}} = named, 2_000
    assert %{^second => _} = Lookup.handle_message(named)
    assert_receive {:solve_lookup, :recover, {_, ^global, _, ^third}} = registered, 2_000
    assert %{^third => _} = Lookup.handle_message(registered)
    Lookup.unsubscribe(first, :source)
    assert Lookup.status(address) == {:connected, second}
    assert Lookup.status(global) == {:connected, third}
    Lookup.unsubscribe(address, :source)
    assert Map.has_key?(cache().apps, third)
    Lookup.unsubscribe(global, :source)
    assert Recovery.state().bindings == %{}
  end

  test "node reincarnation restores a named app but retires an explicit old-creation PID" do
    short = :peer.random_name()
    {first_peer, host} = peer(short)
    first = boot(first_peer)
    address = {:lookup_recovery_app, host}
    view = view(address)
    run(view, fn -> Lookup.solve(address, :source) end)
    Lookup.solve(first, :source)
    :peer.stop(first_peer)
    assert_receive {:solve_lookup_down, _, :process, ^first, :noconnection} = down, 2_000
    Lookup.handle_message(down)
    {second_peer, ^host} = peer(short)
    second = boot(second_peer)
    refute second == first
    assert_receive {:render, ^view, %{^second => _}, [%{value: 1}]}, 3_000
    await_unavailable(first, System.monotonic_time(:millisecond) + 2_000)
    assert Recovery.state().watcher == nil
  end

  defp await_unavailable(app, deadline) do
    unless match?({:unavailable, _}, Lookup.status(app)) do
      remaining = max(0, deadline - System.monotonic_time(:millisecond))

      receive do
        {:solve_lookup, _, _} = message ->
          Lookup.handle_message(message)
          await_unavailable(app, deadline)
      after
        remaining -> flunk("explicit old PID did not become unavailable")
      end
    end
  end

  defp peer(name \\ :peer.random_name()) do
    distribution()
    start_peer(name)
  end

  defp distribution do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      {:ok, _} = Node.start(:"lookup_recovery_#{System.pid()}", :shortnames)
      on_exit(fn -> Node.stop() end)
    end
  end

  defp start_peer(name) do
    {:ok, peer, host} =
      :peer.start_link(%{
        name: name,
        connection: :standard_io,
        args: [~c"+S", ~c"1:1"]
      })

    Process.unlink(peer)
    on_exit(fn -> stop(peer) end)
    :peer.call(peer, :code, :add_paths, [:code.get_path()])
    :peer.call(peer, :application, :ensure_all_started, [:elixir])

    :peer.call(peer, Code, :require_file, [
      Path.expand("../support/lookup_recovery_helper.exs", __DIR__)
    ])

    {peer, host}
  end

  defp boot(peer), do: :peer.call(peer, App, :boot, [])
  defp stop_remote(peer, app), do: :peer.call(peer, GenServer, :stop, [app])
  defp cache, do: Process.get({Lookup, :cache}, %{apps: %{}, aliases: %{}})

  defp view(app, targets \\ [:source]),
    do: start_supervised!({View, owner: self(), app: app, targets: targets})

  defp run(view, fun), do: GenServer.call(view, {:run, fun}, 10_000)

  defp restore_env(key, nil), do: Application.delete_env(:solve, key)
  defp restore_env(key, value), do: Application.put_env(:solve, key, value)

  defp stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp no_queries(fun) do
    patterns = [
      {:rpc, :call, :_},
      {:erpc, :call, :_},
      {GenServer, :whereis, 1},
      {Solve, :subscribe_snapshot, :_}
    ]

    tracer = spawn_link(fn -> trace_loop([]) end)
    Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local]))
    end

    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _, ^ref}
    send(tracer, {:get, self()})
    assert_receive {:trace_calls, []}
  end

  defp trace_loop(calls) do
    receive do
      {:trace, _, :call, call} -> trace_loop([call | calls])
      {:get, owner} -> send(owner, {:trace_calls, Enum.reverse(calls)})
    end
  end
end
