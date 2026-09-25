Code.require_file("../support/lookup_recovery_helper.exs", __DIR__)

defmodule Solve.LookupRemoteTest do
  use ExUnit.Case, async: false

  alias Solve.Lookup
  alias Solve.LookupRecoveryFixture.App

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
        assert :ok = Lookup.cleanup()
      end
    end)

    assert map_size(cache().apps) == 1
    assert map_size(cache().apps[app].refs) == 3
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
  defp cache, do: Process.get({Lookup, :cache}, %{apps: %{}, aliases: %{}})

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
