defmodule Solve.LookupUnsubscribeTest do
  use ExUnit.Case, async: false

  alias Solve.Controller
  alias Solve.Lookup
  alias Solve.Message
  alias Solve.Update

  defmodule Value do
    use Solve.Controller, events: [:set, :run]
    @impl true
    def init(params, _dependencies), do: %{value: params}
    def set(value), do: %{value: value}

    def run(fun, state) do
      fun.()
      state
    end
  end

  defmodule App do
    use Solve
    @impl true
    def controllers do
      [
        controller!(name: :source, module: Value, params: 1),
        controller!(name: :other, module: Value, params: 2),
        controller!(name: :off, module: Value, params: false),
        controller!(name: :catalog, module: Value, params: []),
        controller!(
          name: :items,
          module: Value,
          variant: :collection,
          dependencies: [:catalog],
          collect: fn %{dependencies: %{catalog: %{value: items}}} -> items end
        )
      ]
    end
  end

  defmodule Auto do
    use GenServer
    use Solve.Lookup
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    @impl true
    def init(owner), do: {:ok, %{owner: owner, callbacks: 0}}
    @impl true
    def handle_call({:run, fun}, _from, state), do: {:reply, fun.(), state}
    def handle_call(:callbacks, _from, state), do: {:reply, state.callbacks, state}
    @impl Solve.Lookup
    def handle_solve_updated(updated, state) do
      send(state.owner, {:lookup_updated, self(), updated})
      {:ok, %{state | callbacks: state.callbacks + 1}}
    end
  end

  defmodule Manual do
    use GenServer
    use Solve.Lookup, handle_info: :manual
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    @impl true
    defdelegate init(owner), to: Auto
    @impl true
    defdelegate handle_call(message, from, state), to: Auto
    @impl true
    def handle_info(message, state) do
      case handle_message(message) do
        updated when map_size(updated) == 0 ->
          {:noreply, state}

        updated ->
          {:ok, state} = Auto.handle_solve_updated(updated, state)
          {:noreply, state}
      end
    end
  end

  defmodule Helpers do
    use Solve.Lookup, :helpers
    def acquire(app, target), do: solve(app, target)
    def release(app, target), do: Solve.Lookup.unsubscribe(app, target)
    # Adding unsubscribe to the default imports would conflict with this local API.
    def unsubscribe(target), do: {:local, target}
    def local(target), do: unsubscribe(target)
  end

  defmodule NeverResolve do
    def whereis_name(_name), do: raise("unsubscribe must not resolve an unknown alias")
  end

  defmodule Faulty do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))
    def __events__, do: []
    @impl true
    def init(state), do: {:ok, state}
    @impl true
    def handle_call({:subscribe_snapshot, _subscriber}, _from, state) do
      {:reply,
       %Update{
         app: state.solve_app,
         controller_name: state.controller_name,
         pid: self(),
         version: {state.generation, 0},
         exposed_state: %{value: 1}
       }, state}
    end

    def handle_call({:unsubscribe_external, _subscriber}, _from, state),
      do: {:reply, :unexpected, state}
  end

  defmodule FaultyApp do
    use Solve
    @impl true
    def controllers, do: [controller!(name: :source, module: Faulty, params: true)]
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "unsubscribe removes the cache and raw stream but not controllers or other subscribers" do
    app = app()
    other = worker()
    value = Lookup.solve(app, :source)
    source = Solve.controller_pid(app, :source)
    run(other, fn -> Lookup.solve(app, :source) end)
    Lookup.solve(app, :source)

    assert :ok = Lookup.unsubscribe(app, :source)
    assert_empty_cache()
    assert :sys.get_state(app).subscribers.source == MapSet.new([other])
    refute Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, self())
    assert Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, app)

    # Returned event tuples are not revoked, nor are other consumers' interests.
    Lookup.dispatch(Lookup.event(value, :set, 3))
    barrier(source, other)
    assert_receive {:lookup_updated, ^other, %{^app => %Lookup.Updated{refs: [:source]}}}
    assert run(other, fn -> Lookup.solve(app, :source).value end) == 3
    assert Solve.controller_pid(app, :source) == source
    refute_receive %Message{}, 20
  end

  test "inactive refs and empty collections are real interests" do
    app = app()
    assert Lookup.solve(app, :off) == nil
    assert Lookup.collection(app, :items).ids == []
    assert Map.keys(cache().apps[app].refs) |> Enum.sort() == [:items, :off]
    assert :ok = Lookup.unsubscribe(app, :off)
    refute Map.has_key?(:sys.get_state(app).subscribers, :off)
    assert Map.has_key?(cache().apps[app].refs, :items)
    assert :ok = Lookup.unsubscribe(app, :items)
    assert_empty_cache()
    assert :sys.get_state(app).subscribers == %{}
  end

  test "last ref releases aliases and its monitor but keeps other apps and unrelated monitors" do
    name = __MODULE__.Shared
    app = app(name: name)
    other = app()
    global = {:global, {__MODULE__, make_ref()}}
    assert :yes = :global.register_name(elem(global, 1), app)
    on_exit(fn -> :global.unregister_name(elem(global, 1)) end)
    unrelated = Process.monitor(other)
    Lookup.solve(name, :source)
    Lookup.solve(global, :source)
    Lookup.solve(app, :other)
    Lookup.solve(other, :source)
    monitor = cache().apps[app].monitor
    other_cache = cache().apps[other]

    assert :ok = Lookup.unsubscribe(name, :source)
    assert cache().apps[app].monitor == monitor
    assert cache().aliases == %{name => app, global => app}
    assert :ok = Lookup.unsubscribe(global, :other)
    refute Map.has_key?(cache().apps, app)
    assert cache().aliases == %{}
    assert cache().apps[other] == other_cache
    refute Process.demonitor(monitor, [:info])
    assert Process.demonitor(unrelated, [:info])
    assert :ok = Lookup.unsubscribe(other, :source)
    assert_empty_cache()
  end

  test "unknown aliases, missing targets and repeated unsubscribe do no RPC or allocation" do
    name = __MODULE__.UnknownAlias
    app = app(name: name)
    Lookup.solve(app, :source)
    before = cache()

    no_calls(app, fn ->
      for address <- [self(), app, name, {:via, NeverResolve, :missing}],
          target <- [:unknown, {:items, :absent}] do
        assert :ok = Lookup.unsubscribe(address, target)
      end

      # The name was never acquired, even though its current PID has this ref.
      assert :ok = Lookup.unsubscribe(name, :source)
    end)

    assert cache() == before
    assert :ok = Lookup.unsubscribe(app, :source)
    no_calls(app, fn -> assert :ok = Lookup.unsubscribe(app, :source) end)
    assert_empty_cache()
  end

  test "implicit unsubscribe and helpers use the caller's cache and app context" do
    app = app()

    assert_raise ArgumentError, ~r/could not resolve a solve app/, fn ->
      Lookup.unsubscribe(:source)
    end

    Process.put(:solve_app, app)
    assert Helpers.acquire(nil, :source).value == 1
    assert Helpers.local(:source) == {:local, :source}
    assert :ok = Lookup.unsubscribe(:source)
    assert_empty_cache()
    assert Helpers.acquire(app, :source).value == 1
    assert :ok = Helpers.release(nil, :source)
    assert_empty_cache()
  end

  test "implicit registered names release their recorded lookup interest" do
    name = __MODULE__.Implicit
    app = app(name: name)
    Process.put(:solve_app, name)
    assert Lookup.solve(:source).value == 1
    assert cache().aliases[name] == app
    assert :ok = Lookup.unsubscribe(:source)
    assert_empty_cache()
    assert :sys.get_state(app).subscribers == %{}
  end

  test "source and child interests remain independent with exact numeric IDs" do
    app = app()
    set(app, :catalog, [{1, :integer}, {1.0, :float}])
    assert Lookup.collection(app, :items).ids === [1, 1.0]
    assert Map.keys(cache().apps[app].refs) == [:items]
    assert Lookup.solve(app, {:items, 1}).value == :integer
    assert Lookup.solve(app, {:items, 1.0}).value == :float
    assert :ok = Lookup.unsubscribe(app, {:items, 1})
    assert Map.has_key?(cache().apps[app].refs, {:items, 1.0})
    set(app, {:items, 1}, :changed)
    source_update = take_update(app, :items)

    assert %{^app => %Lookup.Updated{collections: [:items]}} =
             Lookup.handle_message(source_update)

    assert Lookup.collection(app, :items).items[1].value == :changed

    assert :ok = Lookup.unsubscribe(app, :items)
    set(app, {:items, 1.0}, :float_changed)
    child_update = take_update(app, {:items, 1.0})
    assert %{^app => %Lookup.Updated{refs: [{:items, id}]}} = Lookup.handle_message(child_update)
    assert id === 1.0
    assert Lookup.solve(app, {:items, 1.0}).value == :float_changed
    assert Lookup.handle_message(source_update) == %{}
    refute Map.has_key?(cache().apps[app].refs, :items)
    assert :ok = Lookup.unsubscribe(app, {:items, 1.0})
    assert_empty_cache()
  end

  test "queued messages stay in the mailbox but cannot recreate a removed ref" do
    app = app()
    Lookup.solve(app, :source)
    set(app, :source, 2)
    assert :ok = Lookup.unsubscribe(app, :source)
    message = take_update(app, :source)
    assert Lookup.handle_message(message) == %{}

    assert {:noreply, :unchanged} =
             Lookup.__handle_update__(message, :unchanged, fn _, _ ->
               flunk("unexpected callback")
             end)

    assert_empty_cache()
    assert :sys.get_state(app).subscribers == %{}
  end

  test "unsolicited, versionless and noncanonical updates cannot create refs or issue RPC" do
    name = __MODULE__.UpdateNames
    app = app(name: name)
    Lookup.solve(name, :source)
    source = Solve.controller_pid(app, :source)
    snapshot = Controller.subscribe_snapshot(source, app)
    {generation, revision} = snapshot.version
    fresh = %{snapshot | version: {generation, revision + 1}, exposed_state: %{value: 999}}
    before = cache()

    no_calls(app, fn ->
      for address <- [nil, name, {:via, NeverResolve, :missing}] do
        assert Lookup.handle_message(Update.message(%{fresh | app: address})) == %{}
      end

      for version <- [nil, {-1, 0}, {1, -1}, {1.0, 1}, {1, 1.0}, {1}, {1, 2, 3}, :invalid] do
        assert Lookup.handle_message(Update.message(%{fresh | version: version})) == %{}
      end

      assert Lookup.handle_message(Update.message(%{fresh | controller_name: :other})) == %{}
      assert Lookup.handle_message(Message.update(app, :other, %{value: 999})) == %{}
      assert Lookup.handle_message(Update.message(%{fresh | app: self()})) == %{}
      assert Lookup.handle_message(Update.message(%{fresh | kind: :collection})) == %{}
      assert Lookup.solve(name, :source).value == 1
    end)

    assert cache() == before
  end

  for mode <- [Auto, Manual] do
    test "#{inspect(mode)} ignores queued updates after cancellation and reacquires explicitly" do
      app = app()
      source = Solve.controller_pid(app, :source)
      worker = worker(unquote(mode))
      owner = self()

      task =
        Task.async(fn ->
          run(worker, fn ->
            Lookup.solve(app, :source)
            send(owner, {:acquired, self()})

            receive do
              :unsubscribe -> Lookup.unsubscribe(app, :source)
            end
          end)
        end)

      assert_receive {:acquired, ^worker}
      set(app, :source, 2)
      send(worker, :unsubscribe)
      assert :ok = Task.await(task)
      barrier(source, worker)
      barrier(app, worker)
      assert GenServer.call(worker, :callbacks) == 0
      assert run(worker, &cache/0) == %{apps: %{}, aliases: %{}}
      assert run(worker, fn -> Lookup.solve(app, :source).value end) == 2
      set(app, :source, 3)
      barrier(source, worker)
      barrier(app, worker)
      assert GenServer.call(worker, :callbacks) == 1
      assert run(worker, fn -> Lookup.solve(app, :source).value end) == 3
      GenServer.stop(app)
      barrier(worker, worker)
      eventually(fn -> run(worker, &cache/0) == %{apps: %{}, aliases: %{}} end)
    end
  end

  test "nested timeout clears the ref without pretending a later local no-op confirms detachment" do
    app = app()
    source = Solve.controller_pid(app, :source)
    Lookup.solve(app, :source)
    Lookup.solve(app, :other)
    monitor = cache().apps[app].monitor

    suspended(source, fn ->
      assert {:error, :timeout} = Lookup.unsubscribe(app, :source)
      refute Map.has_key?(cache().apps[app].refs, :source)
      assert cache().apps[app].monitor == monitor
      assert Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, self())
      refute Map.has_key?(:sys.get_state(app).subscribers, :source)
      no_calls(app, fn -> assert :ok = Lookup.unsubscribe(app, :source) end)
    end)

    assert :ok = Solve.unsubscribe(app, :source)
    refute Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, self())
  end

  test "resubscribe after a nested timeout survives the queued detach" do
    app = app()
    source = Solve.controller_pid(app, :source)
    Lookup.solve(app, :source)
    old_monitor = cache().apps[app].monitor

    suspended(source, fn ->
      assert {:error, :timeout} = Lookup.unsubscribe(app, :source)
      assert_empty_cache()
      assert Lookup.solve(app, :source).value == 1
      refute cache().apps[app].monitor == old_monitor
    end)

    # Acknowledge the app's attachment chain before publishing another value.
    Solve.subscribe_snapshot(app, :source)
    set(app, :source, 7)
    assert Lookup.handle_message(take_update(app, :source)) != %{}
    assert Lookup.solve(app, :source).value == 7
    assert Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, self())
  end

  test "outer timeout clears local interest, preserves the exit and orders later reacquisition" do
    app = app()
    source = Solve.controller_pid(app, :source)
    worker = worker()
    owner = self()
    run(worker, fn -> Lookup.solve(app, :source) end)

    task =
      suspended(app, fn ->
        assert {:timeout, {GenServer, :call, [^app, {:unsubscribe, :source, ^worker}, 5_000]}} =
                 run(worker, fn -> catch_exit(Lookup.unsubscribe(app, :source)) end)

        assert run(worker, &cache/0) == %{apps: %{}, aliases: %{}}
        assert MapSet.member?(:sys.get_state(app).subscribers.source, worker)

        task =
          Task.async(fn ->
            run(worker, fn ->
              send(owner, :reacquiring)
              Lookup.solve(app, :source)
            end)
          end)

        assert_receive :reacquiring

        eventually(fn ->
          {:messages, messages} = Process.info(app, :messages)

          Enum.any?(
            messages,
            &match?({:"$gen_call", _, {:snapshot, :source, ^worker}}, &1)
          )
        end)

        task
      end)

    assert %{value: 1} = Task.await(task)
    assert Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, worker)
    set(app, :source, 8)
    barrier(source, worker)
    assert run(worker, fn -> Lookup.solve(app, :source).value end) == 8
  end

  test "direct reentrancy preserves the exact cache and its owned monitor" do
    app = app()
    source = Solve.controller_pid(app, :source)
    owner = self()

    Controller.dispatch(source, :run, fn ->
      # The app returns its accepted snapshot after the self-subscription handshake times out.
      assert Lookup.solve(app, :source).value == 1
      before = cache()
      result = Lookup.unsubscribe(app, :source)
      send(owner, {:reentrant, result, before, cache()})
    end)

    assert_receive {:reentrant, {:error, :reentrant_unsubscribe}, before, after_reject}, 3_000
    assert before == after_reject
    assert MapSet.member?(:sys.get_state(app).subscribers.source, source)
  end

  test "unexpected handshake replies clear local interest and preserve the raw error" do
    app = app([], FaultyApp)
    Lookup.solve(app, :source)

    assert {:error, {:unsubscribe_failed, {:unexpected_reply, :unexpected}}} =
             Lookup.unsubscribe(app, :source)

    assert_empty_cache()
    assert :sys.get_state(app).subscribers == %{}
  end

  test "dead app cleanup forgets all refs without consuming unrelated monitor messages" do
    app = app()
    Lookup.solve(app, :source)
    Lookup.solve(app, :other)
    unrelated = Process.monitor(app)
    GenServer.stop(app)
    assert :ok = Lookup.unsubscribe(app, :source)
    assert_empty_cache()
    assert_receive {:DOWN, ^unrelated, :process, ^app, :normal}
  end

  @tag :capture_log
  test "app death during unsubscribe succeeds without affecting another app" do
    app = app()
    other = app()
    worker = worker()

    run(worker, fn ->
      Lookup.solve(app, :source)
      Lookup.solve(other, :source)
    end)

    :sys.suspend(app)
    task = Task.async(fn -> run(worker, fn -> Lookup.unsubscribe(app, :source) end) end)

    eventually(fn ->
      {:messages, messages} = Process.info(app, :messages)
      Enum.any?(messages, &match?({:"$gen_call", _, {:unsubscribe, :source, ^worker}}, &1))
    end)

    Process.exit(app, :kill)
    assert :ok = Task.await(task)
    assert Map.keys(run(worker, &cache/0).apps) == [other]
  end

  test "cached names release their old live app rather than the current registry owner" do
    name = __MODULE__.Rebound
    first = app(name: name)
    Lookup.solve(name, :source)
    Process.unregister(name)
    replacement = app(name: name)
    Lookup.solve(replacement, :source)
    assert :ok = Lookup.unsubscribe(name, :source)
    assert :sys.get_state(first).subscribers == %{}
    assert MapSet.member?(:sys.get_state(replacement).subscribers.source, self())
    assert Map.keys(cache().apps) == [replacement]
  end

  for forwarded_down <- [false, true] do
    test "a restarted name cannot cancel a replacement after DOWN forwarded=#{forwarded_down}" do
      name = __MODULE__.Restarted
      first = app(name: name)
      Lookup.solve(name, :source)
      GenServer.stop(first)
      assert_receive {:solve_lookup_down, _, :process, ^first, _} = down
      if unquote(forwarded_down), do: Lookup.handle_message(down)
      replacement = app(name: name)
      Lookup.solve(replacement, :source)
      assert :ok = Lookup.unsubscribe(name, :source)
      assert MapSet.member?(:sys.get_state(replacement).subscribers.source, self())
      assert Map.keys(cache().apps) == [replacement]
      assert Lookup.solve(name, :source).value == 1
      assert cache().aliases[name] == replacement
      assert :ok = Lookup.unsubscribe(name, :source)
      assert_empty_cache()
    end
  end

  test "live alias rebind retains old PID interests and dispatch never rewrites lookup ownership" do
    name = __MODULE__.LiveAlias
    first = app(name: name)
    Lookup.solve(name, :source)
    Lookup.solve(first, :other)
    original = cache().apps[first]
    Process.unregister(name)
    replacement = app(name: name)
    Lookup.solve(replacement, :source)

    Lookup.dispatch(name, :source, :set, 4)
    assert Lookup.handle_message(Message.dispatch(name, :source, :set, 5)) == %{}
    assert cache().aliases[name] == first
    assert cache().apps[first] == original
    set(replacement, :source, 6)
    consume_updates()
    assert Lookup.solve(name, :source).value == 6
    assert cache().aliases[name] == replacement
    assert cache().apps[first] == original
    assert :ok = Lookup.unsubscribe(name, :source)
    assert Map.keys(cache().apps) == [first]
    assert Lookup.solve(first, :source).value == 1
    Lookup.unsubscribe(first, :source)
    Lookup.unsubscribe(first, :other)
    assert_empty_cache()
  end

  test "global, via and remote-name forms use their recorded canonical PID" do
    registry = __MODULE__.Registry
    start_supervised!({Registry, keys: :unique, name: registry})

    for name <- [{:global, {__MODULE__, make_ref()}}, {:via, Registry, {registry, :app}}] do
      app = app(name: name)
      assert Lookup.solve(name, :source).value == 1
      assert cache().aliases[name] == app
      assert :ok = Lookup.unsubscribe(name, :source)
      assert_empty_cache()
    end

    name = __MODULE__.RemoteName
    app = app(name: name)
    address = {name, node()}
    assert Lookup.solve(address, :source).value == 1
    assert :ok = Lookup.unsubscribe(address, :source)
    assert :sys.get_state(app).subscribers == %{}
    assert_empty_cache()
  end

  test "stale DOWN cannot remove a reacquired monitor or any unrelated ref" do
    app = app()
    Lookup.solve(app, :source)
    old_monitor = cache().apps[app].monitor
    Lookup.unsubscribe(app, :source)
    Lookup.solve(app, :source)
    new_monitor = cache().apps[app].monitor
    refute old_monitor == new_monitor
    assert Lookup.handle_message({:solve_lookup_down, old_monitor, :process, app, :normal}) == %{}
    assert cache().apps[app].monitor == new_monitor
    set(app, :source, 9)
    assert Lookup.handle_message(take_update(app, :source)) != %{}
    assert Lookup.solve(app, :source).value == 9
  end

  test "dispatch and failed acquisitions do not leave orphan aliases" do
    name = __MODULE__.NoRef
    app = app(name: name)
    Lookup.dispatch(name, :source, :set, 2)
    assert_empty_cache()
    assert Lookup.solve(name, :missing) == nil
    assert_empty_cache()
    assert_raise ArgumentError, fn -> Lookup.collection(name, :missing) end
    assert_empty_cache()
    Process.put({Lookup, :cache}, %{apps: %{}, aliases: %{name => app}})
    assert Lookup.cleanup() == :ok
    assert_empty_cache()
    # Dispatch still worked even though it recorded no lookup interest.
    assert Lookup.solve(app, :source).value == 2
  end

  test "valid update handling and warm reads do not call the coordinator" do
    name = __MODULE__.Warm
    app = app(name: name)
    Lookup.solve(name, :source)
    set(app, :source, 2)
    message = take_update(app, :source)

    no_calls(app, fn ->
      assert Lookup.handle_message(message) != %{}
      for _ <- 1..25, do: assert(Lookup.solve(name, :source).value == 2)
    end)
  end

  @tag :capture_log
  test "remote disconnection propagates an exit but confirmed remote absence cleans the app" do
    {peer, remote_node, app} = remote_app()
    assert Lookup.solve(app, :source).value == 1
    monitor = cache().apps[app].monitor
    cookie = Node.get_cookie()
    :peer.call(peer, :logger, :set_primary_config, [:level, :emergency])
    assert Node.set_cookie(remote_node, :solve_lookup_wrong_cookie)
    assert Node.disconnect(remote_node)
    assert_receive {:solve_lookup_down, ^monitor, :process, ^app, :noconnection}, 1_000
    assert :peer.call(peer, Process, :alive?, [app])

    assert {{:nodedown, ^remote_node}, {GenServer, :call, [^app, _, 5_000]}} =
             catch_exit(Lookup.unsubscribe(app, :source))

    assert_empty_cache()
    assert Node.set_cookie(remote_node, cookie)
    assert Lookup.solve(app, :source).value == 1
    assert Lookup.solve(app, :other).value == 1
    assert :ok = :peer.call(peer, GenServer, :stop, [app])
    assert :ok = Lookup.unsubscribe(app, :source)
    assert_empty_cache()
  end

  test "item and app churn retains no historical refs, aliases or monitors" do
    baseline = Process.info(self(), :monitors)
    app = app()

    for id <- 1..40 do
      set(app, :catalog, [{id, true}])
      Lookup.solve(app, {:items, id})
      assert :ok = Lookup.unsubscribe(app, {:items, id})
      assert_empty_cache()
    end

    for _ <- 1..10 do
      name = {:global, {__MODULE__, make_ref()}}
      transient = app(name: name)
      Lookup.solve(name, :source)
      assert :ok = Lookup.unsubscribe(name, :source)
      GenServer.stop(transient)
      consume_updates()
      assert_empty_cache()
    end

    assert Process.info(self(), :monitors) == baseline
    assert :sys.get_state(app).subscribers == %{}
    assert :sys.get_state(app).subscriber_monitors == %{}
  end

  defp remote_app do
    unless Node.alive?() do
      {_, 0} = System.cmd("epmd", ["-daemon"])

      {:ok, _} =
        Node.start(
          :"solve_lookup_#{System.pid()}_#{System.unique_integer([:positive])}",
          :shortnames
        )

      on_exit(fn -> Node.stop() end)
    end

    {:ok, peer, remote_node} =
      :peer.start_link(%{
        name: :peer.random_name(),
        connection: :standard_io,
        args: [~c"+S", ~c"1:1"]
      })

    on_exit(fn -> stop(peer) end)
    :peer.call(peer, :code, :add_paths, [:code.get_path()])
    :peer.call(peer, :application, :ensure_all_started, [:elixir])

    {app, _bindings} =
      :peer.call(peer, Code, :eval_string, [
        """
        defmodule LookupRemoteValue do
          use Solve.Controller
          @impl true
          def init(_, _), do: %{value: 1}
        end
        defmodule LookupRemoteApp do
          use Solve
          @impl true
          def controllers do
            for name <- [:source, :other],
              do: controller!(name: name, module: LookupRemoteValue, params: true)
          end
        end
        {:ok, app} = LookupRemoteApp.start_link(name: nil)
        Process.unlink(app)
        app
        """
      ])

    {peer, remote_node, app}
  end

  defp app(opts \\ [], module \\ App) do
    {:ok, app} = module.start_link(Keyword.put_new(opts, :name, nil))
    on_exit(fn -> stop(app) end)
    app
  end

  defp stop(pid) do
    GenServer.stop(pid, :shutdown)
  catch
    :exit, _ -> :ok
  end

  defp worker(module \\ Auto) do
    start_supervised!(Supervisor.child_spec({module, self()}, id: make_ref()))
  end

  defp run(worker, fun), do: GenServer.call(worker, {:run, fun}, 10_000)
  defp cache, do: Process.get({Lookup, :cache}, %{apps: %{}, aliases: %{}})
  defp assert_empty_cache, do: assert(cache() == %{apps: %{}, aliases: %{}})

  defp barrier(publisher, worker) when publisher == worker, do: run(worker, fn -> :ok end)

  defp barrier(publisher, worker) do
    :sys.replace_state(publisher, fn state ->
      run(worker, fn -> :ok end)
      state
    end)
  end

  defp set(app, target, value) do
    source = Solve.controller_pid(app, target)
    Controller.dispatch(source, :set, value)
    assert %Update{exposed_state: %{value: ^value}} = Controller.subscribe_snapshot(source, app)

    eventually(fn ->
      :sys.get_state(app).targets[target].snapshot.exposed_state == %{value: value}
    end)
  end

  defp take_update(app, target) do
    assert_receive %Message{type: :update, payload: %Update{app: ^app, controller_name: ^target}} =
                     message,
                   1_000

    message
  end

  defp consume_updates do
    receive do
      %Message{} = message ->
        Lookup.handle_message(message)
        consume_updates()

      {:solve_lookup_down, _, :process, _, _} = message ->
        Lookup.handle_message(message)
        consume_updates()
    after
      0 -> :ok
    end
  end

  defp suspended(pid, fun) do
    :sys.suspend(pid)

    try do
      fun.()
    after
      if Process.alive?(pid), do: :sys.resume(pid)
    end
  end

  defp no_calls(app, fun) do
    :sys.statistics(app, true)
    fun.()
    {:ok, statistics} = :sys.statistics(app, :get)
    assert statistics[:messages_in] == 0
    assert statistics[:messages_out] == 0
    :sys.statistics(app, false)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if not fun.() do
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
