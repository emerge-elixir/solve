defmodule Solve.UnsubscribeTest do
  use ExUnit.Case, async: false

  alias Solve.Collection
  alias Solve.Controller
  alias Solve.DependencyUpdate
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

    # Used to create an indirect synchronous call cycle without changing runtime code.
    def handle_call(:barrier, _from, state), do: {:reply, :ok, state}
  end

  defmodule Projection do
    use Solve.Controller
    @impl true
    def init(_params, _dependencies), do: make_ref()
    @impl true
    def expose(identity, dependencies, _params),
      do: %{identity: identity, dependencies: dependencies}
  end

  defmodule App do
    use Solve
    @impl true
    def controllers do
      [
        controller!(name: :source, module: Value, params: 1),
        controller!(name: :other, module: Value, params: 2),
        controller!(name: :off, module: Value, params: false),
        controller!(
          name: :derived,
          module: Value,
          dependencies: [:source],
          params: fn %{dependencies: %{source: source}} -> source && source.value end
        ),
        controller!(name: :observer, module: Projection, dependencies: [:source]),
        controller!(name: :catalog, module: Value, params: []),
        controller!(
          name: :items,
          module: Value,
          variant: :collection,
          dependencies: [:catalog],
          collect: fn %{dependencies: %{catalog: %{value: items}}} -> items end
        ),
        controller!(
          name: :item_observer,
          module: Projection,
          dependencies: [items: collection(:items)]
        )
      ]
    end
  end

  defmodule Mailbox do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(_opts), do: {:ok, []}
    @impl true
    def handle_info({:barrier, caller, tag}, messages) do
      send(caller, {tag, Enum.reverse(messages)})
      {:noreply, []}
    end

    def handle_info(message, messages), do: {:noreply, [message | messages]}
  end

  defmodule Faulty do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def __events__, do: []
    @impl true
    def init(opts), do: {:ok, Map.new(opts)}
    @impl true
    def handle_call({:subscribe_snapshot, _subscriber}, _from, state) do
      snapshot = %Update{
        app: state.solve_app,
        controller_name: state.controller_name,
        pid: self(),
        version: {state.generation, 0},
        exposed_state: %{value: 1}
      }

      {:reply, snapshot, state}
    end

    def handle_call({:unsubscribe_external, _subscriber}, _from, %{params: :die} = state),
      do: {:stop, :normal, state}

    def handle_call({:unsubscribe_external, _subscriber}, _from, state),
      do: {:reply, :unexpected, state}
  end

  defmodule FaultyApp do
    use Solve
    @impl true
    def controllers do
      [controller!(name: :source, module: Faulty, params: fn %{app_params: params} -> params end)]
    end
  end

  defmodule SelfCallingApp do
    use Solve
    @impl true
    def controllers do
      [
        controller!(
          name: :source,
          module: Value,
          params: fn %{app_params: caller} ->
            result =
              try do
                Solve.unsubscribe(self(), :source)
              catch
                :exit, reason -> reason
              end

            send(caller, {:self_call, result})
            1
          end
        )
      ]
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "controller detachment removes only the external stream and retains shared monitors" do
    pid = start_supervised!({Value, params: 1, solve_app: :raw})
    worker = worker()
    other = worker()
    Controller.subscribe(pid, worker)
    Controller.subscribe(pid, worker)
    Controller.subscribe(pid, other)
    {:ok, _, dependency} = Controller.subscribe_dependency(pid, worker, :source)
    {:ok, _, encoder} = Controller.subscribe_with(pid, worker, &{:encoded, &1})
    before = :sys.get_state(pid)
    monitor = before.subscriber_monitor_refs_by_pid[worker]

    assert :ok = Controller.unsubscribe_external(pid, worker)
    assert :ok = Controller.unsubscribe_external(pid, worker)
    after_remove = :sys.get_state(pid)
    refute Map.has_key?(after_remove.external_subscription_refs_by_pid, worker)
    assert after_remove.subscriber_monitor_refs_by_pid[worker] == monitor
    assert map_size(after_remove.subscribers) == 3

    Controller.dispatch(pid, :set, 2)
    messages = barrier(pid, worker)
    assert Enum.any?(messages, &match?(%DependencyUpdate{key: :source, value: %{value: 2}}, &1))
    assert {:encoded, %{value: 2}} in messages
    refute Enum.any?(messages, &match?(%Message{}, &1))
    assert [%Message{payload: %Update{exposed_state: %{value: 2}}}] = barrier(pid, other)

    Controller.unsubscribe(pid, dependency)
    assert :sys.get_state(pid).subscriber_monitor_refs_by_pid[worker] == monitor
    Controller.unsubscribe(pid, encoder)
    refute Map.has_key?(:sys.get_state(pid).subscriber_monitor_refs_by_pid, worker)
    Controller.unsubscribe_external(pid, other)
    assert :sys.get_state(pid).subscribers == %{}
    assert :sys.get_state(pid).external_subscription_refs_by_pid == %{}
    assert Process.info(pid, :monitors) == {:monitors, []}

    Controller.subscribe(pid, worker)
    assert :sys.get_state(pid).subscriber_monitor_refs_by_pid[worker] != monitor
    send(pid, {:DOWN, monitor, :process, worker, :normal})
    Controller.dispatch(pid, :set, 3)
    assert [%Message{payload: %Update{exposed_state: %{value: 3}}}] = barrier(pid, worker)
  end

  test "unsubscribe stops raw updates but not controllers or other subscribers" do
    app = app()
    source = Solve.controller_pid(app, :source)
    worker = worker()
    assert %{value: 1} = Solve.subscribe(app, :source)
    Solve.subscribe(app, :source)
    Solve.subscribe(app, :source, worker)
    assert :ok = Solve.unsubscribe(app, :source)
    assert :ok = Solve.unsubscribe(app, :source)
    assert :sys.get_state(app).subscribers.source == MapSet.new([worker])
    refute Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, self())
    set(app, :source, 3)
    assert [%Message{payload: %Update{exposed_state: %{value: 3}}}] = barrier(source, worker)
    refute_receive %Message{}, 20
    assert Solve.controller_pid(app, :source) == source
    assert :ok = Solve.unsubscribe(app, :source, worker)
    assert :sys.get_state(app).subscribers == %{}
    assert :sys.get_state(app).subscriber_monitors == %{}
  end

  test "app unsubscribe also removes the shared direct stream without an interest record" do
    app = app()
    source = Solve.controller_pid(app, :source)
    worker = worker()
    Controller.subscribe(source, worker)
    assert :sys.get_state(app).subscribers == %{}
    assert :ok = Solve.unsubscribe(app, :source, worker)
    refute Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, worker)
    assert Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, app)
  end

  test "third-party removal retains other targets and rejects stale subscriber DOWN" do
    app = app()
    worker = worker()
    Solve.subscribe(app, :source)
    Solve.subscribe(app, :source, worker)
    Solve.subscribe(app, :other, worker)
    monitor = :sys.get_state(app).subscriber_monitors[worker]
    assert :ok = Solve.unsubscribe(app, :source, worker)
    assert :sys.get_state(app).subscriber_monitors[worker] == monitor
    assert MapSet.member?(:sys.get_state(app).subscribers.source, self())
    assert :ok = Solve.unsubscribe(app, :other, worker)
    refute Map.has_key?(:sys.get_state(app).subscriber_monitors, worker)
    Solve.subscribe(app, :other, worker)
    new_monitor = :sys.get_state(app).subscriber_monitors[worker]
    assert new_monitor != monitor
    send(app, {:DOWN, monitor, :process, worker, :normal})
    assert :sys.get_state(app).subscriber_monitors[worker] == new_monitor
    set(app, :other, 4)

    assert [%Message{payload: %Update{exposed_state: %{value: 4}}}] =
             barrier(Solve.controller_pid(app, :other), worker)
  end

  test "unknown and stopped targets are no-ops and invalid subscribers raise" do
    app = app()

    for target <- [:missing, {:missing, 1}, :off, {:items, :absent}, {:source, 1}, 123] do
      Solve.subscribe(app, target)
      assert :ok = Solve.unsubscribe(app, target)
    end

    assert :sys.get_state(app).subscribers == %{}
    assert :sys.get_state(app).subscriber_monitors == %{}

    assert_raise ArgumentError, ~r/expects a pid subscriber/, fn ->
      Solve.unsubscribe(app, :source, :not_a_pid)
    end

    assert_raise ArgumentError, ~r/expects a pid subscriber/, fn ->
      Controller.unsubscribe_external(Solve.controller_pid(app, :source), :not_a_pid)
    end
  end

  test "app-PID interest is removable without detaching the mandatory observer" do
    app = app()
    source = Solve.controller_pid(app, :source)
    observer = Solve.controller_pid(app, :observer)
    Solve.subscribe(app, :source, app)

    suspended(source, fn ->
      assert :ok = Solve.unsubscribe(app, :source, app)
    end)

    refute Map.has_key?(:sys.get_state(app).subscribers, :source)
    assert Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, app)
    set(app, :source, 5)

    eventually(fn ->
      :sys.get_state(observer).exposed_state.dependencies.source == %{value: 5}
    end)

    assert Solve.controller_pid(app, :observer) == observer
  end

  test "removed subscriptions do not return after params replacement, stop, or restart" do
    app = app()
    worker = worker()
    original = Solve.controller_pid(app, :derived)
    Solve.subscribe(app, :derived, worker)
    Solve.unsubscribe(app, :derived, worker)
    set(app, :source, 3)
    replacement = Solve.controller_pid(app, :derived)
    assert replacement != original
    set(app, :source, false)
    assert Solve.controller_pid(app, :derived) == nil
    set(app, :source, 4)
    current = Solve.controller_pid(app, :derived)
    refute Map.has_key?(:sys.get_state(current).external_subscription_refs_by_pid, worker)
    assert barrier(app, worker) ++ barrier(current, worker) == []
  end

  @tag :capture_log
  test "controller crash cannot reattach a removed subscriber" do
    app = app()
    worker = worker()
    source = Solve.controller_pid(app, :source)
    Solve.subscribe(app, :source, worker)
    Solve.unsubscribe(app, :source, worker)
    Process.exit(source, :kill)
    eventually(fn -> Solve.controller_pid(app, :source) not in [nil, source] end)
    current = Solve.controller_pid(app, :source)
    refute Map.has_key?(:sys.get_state(current).external_subscription_refs_by_pid, worker)
    assert barrier(app, worker) ++ barrier(current, worker) == []
  end

  test "source and item interests are independent and numeric IDs remain exact" do
    app = app()
    worker = worker()
    set(app, :catalog, [{1, :integer}, {1.0, :float}])
    for target <- [:items, {:items, 1}, {:items, 1.0}], do: Solve.subscribe(app, target, worker)
    Solve.unsubscribe(app, {:items, 1}, worker)
    assert Map.has_key?(:sys.get_state(app).subscribers, {:items, 1.0})
    set(app, {:items, 1}, :changed)

    assert [%Message{payload: %Update{controller_name: :items, exposed_state: collection}}] =
             barrier(app, worker)

    assert Collection.fetch(collection, 1) == {:ok, %{value: :changed}}
    Solve.unsubscribe(app, :items, worker)
    set(app, {:items, 1.0}, :float_changed)

    assert [%Message{payload: %Update{controller_name: {:items, id}}}] =
             barrier(Solve.controller_pid(app, {:items, 1.0}), worker)

    assert id === 1.0
    assert barrier(app, worker) == []
    Solve.unsubscribe(app, {:items, 1.0}, worker)
    set(app, :catalog, [])
    set(app, :catalog, [{1, :reborn}, {1.0, :reborn}])
    assert barrier(app, worker) == []

    for id <- [1, 1.0] do
      pid = Solve.controller_pid(app, {:items, id})
      refute Map.has_key?(:sys.get_state(pid).external_subscription_refs_by_pid, worker)
    end

    projection = Solve.controller_pid(app, :item_observer)

    eventually(fn ->
      :sys.get_state(projection).exposed_state.dependencies.items.ids === [1, 1.0]
    end)
  end

  test "controller timeout removes interest and an idempotent retry confirms queued detach" do
    app = app()
    source = Solve.controller_pid(app, :source)
    worker = worker()
    Solve.subscribe(app, :source, worker)

    suspended(source, fn ->
      assert {:error, :timeout} = Solve.unsubscribe(app, :source, worker)
      refute Map.has_key?(:sys.get_state(app).subscribers, :source)
      assert Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, worker)
      assert {:error, :timeout} = Solve.unsubscribe(app, :source, worker)
    end)

    assert :ok = Solve.unsubscribe(app, :source, worker)
    assert Solve.controller_pid(app, :source) == source
    refute Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, worker)
    assert :sys.get_state(app).pending_attachments == %{}
  end

  test "queued detach cannot overtake resubscribe to the same controller" do
    app = app()
    source = Solve.controller_pid(app, :source)
    worker = worker()
    Solve.subscribe(app, :source, worker)

    suspended(source, fn ->
      assert {:error, :timeout} = Solve.unsubscribe(app, :source, worker)
      assert %{value: 1} = Solve.subscribe(app, :source, worker)
    end)

    # Repeat subscribe to acknowledge the queued requests and consume the retry chain.
    Solve.subscribe(app, :source, worker)
    barrier(source, worker)
    set(app, :source, 9)
    assert [%Message{payload: %Update{exposed_state: %{value: 9}}}] = barrier(source, worker)
    assert :sys.get_state(app).pending_attachments == %{}
  end

  test "retry tokens prevent old work from acting on a new pending chain" do
    app = app()
    source = Solve.controller_pid(app, :source)
    worker = worker()
    key = {:source, worker}

    suspended(source, fn ->
      Solve.subscribe(app, :source, worker)
      {generation, old_token} = :sys.get_state(app).pending_attachments[key]
      assert {:error, :timeout} = Solve.unsubscribe(app, :source, worker)
      refute Map.has_key?(:sys.get_state(app).pending_attachments, key)
      send(app, {:retry_attachment, :source, worker, generation, old_token, 1})
      assert :sys.get_state(app).pending_attachments == %{}
      Solve.subscribe(app, :source, worker)
      {^generation, new_token} = :sys.get_state(app).pending_attachments[key]
      assert new_token != old_token
      send(app, {:retry_attachment, :source, worker, generation, old_token, 3})
      assert :sys.get_state(app).pending_attachments[key] == {generation, new_token}
    end)

    Solve.subscribe(app, :source, worker)
    assert :sys.get_state(app).pending_attachments == %{}
  end

  test "subscriber death clears pending work and stale retries cannot reattach it" do
    app = app()
    source = Solve.controller_pid(app, :source)
    worker = worker()

    suspended(source, fn ->
      Solve.subscribe(app, :source, worker)
      {generation, token} = :sys.get_state(app).pending_attachments[{:source, worker}]
      GenServer.stop(worker)
      eventually(fn -> :sys.get_state(app).pending_attachments == %{} end)
      send(app, {:retry_attachment, :source, worker, generation, token, 1})
      assert :sys.get_state(app).subscribers == %{}
      assert :sys.get_state(app).subscriber_monitors == %{}
    end)

    eventually(fn ->
      not Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, worker)
    end)
  end

  test "reentrant calls reject before mutation but explicit app interest can be removed" do
    app = app()
    source = Solve.controller_pid(app, :source)
    worker = worker()
    Solve.subscribe(app, :source, worker)
    Solve.subscribe(app, :source, app)
    before = :sys.get_state(app)
    caller = self()

    Controller.dispatch(source, :run, fn ->
      send(caller, {:reentrant, Solve.unsubscribe(app, :source, worker)})
    end)

    assert_receive {:reentrant, {:error, :reentrant_unsubscribe}}, 1_000
    after_reject = :sys.get_state(app)

    assert Map.take(after_reject, [:subscribers, :subscriber_monitors, :pending_attachments]) ==
             Map.take(before, [:subscribers, :subscriber_monitors, :pending_attachments])

    assert Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, worker)

    Controller.dispatch(source, :run, fn ->
      send(caller, {:observer_removed, Solve.unsubscribe(app, :source, app)})
    end)

    assert_receive {:observer_removed, :ok}, 1_000
    assert :sys.get_state(app).subscribers.source == MapSet.new([worker])
    assert Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, app)
  end

  test "outer app timeout does not confirm logical removal or cancel the request" do
    app = app()
    worker = worker()
    source = Solve.controller_pid(app, :source)
    Solve.subscribe(app, :source, worker)

    suspended(app, fn ->
      assert {:timeout, _} = catch_exit(Solve.unsubscribe(app, :source, worker))
      assert MapSet.member?(:sys.get_state(app).subscribers.source, worker)
      assert Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, worker)
    end)

    Solve.controller_pid(app, :source)
    refute Map.has_key?(:sys.get_state(app).subscribers, :source)
    refute Map.has_key?(:sys.get_state(source).external_subscription_refs_by_pid, worker)
  end

  test "indirect callback cycles time out and unwind without restarting controllers" do
    app = app()
    a = Solve.controller_pid(app, :source)
    b = Solve.controller_pid(app, :other)
    worker = worker()
    Solve.subscribe(app, :other, worker)
    caller = self()

    Controller.dispatch(a, :run, fn ->
      send(caller, {:a_waiting, self()})

      receive do
        :begin_unsubscribe ->
          send(caller, {:cycle_unsubscribe, Solve.unsubscribe(app, :other, worker)})
      end
    end)

    assert_receive {:a_waiting, ^a}

    Controller.dispatch(b, :run, fn ->
      send(caller, {:b_waiting, self()})
      GenServer.call(a, :barrier)
      send(caller, :cycle_finished)
    end)

    assert_receive {:b_waiting, ^b}
    send(a, :begin_unsubscribe)
    assert_receive {:cycle_unsubscribe, {:error, :timeout}}, 2_000
    assert_receive :cycle_finished, 1_000
    assert :ok = Solve.unsubscribe(app, :other, worker)
    assert Solve.controller_pid(app, :source) == a
    assert Solve.controller_pid(app, :other) == b
  end

  test "app callbacks retain normal GenServer self-call exit behavior" do
    app = app(SelfCallingApp, params: self())
    assert_receive {:self_call, {:calling_self, _}}
    assert Process.alive?(app)
  end

  test "a target dying during the handshake counts as successful detachment" do
    app = app(FaultyApp, params: :die)
    source = Solve.controller_pid(app, :source)
    Solve.subscribe(app, :source)
    assert :ok = Solve.unsubscribe(app, :source)
    eventually(fn -> Solve.controller_pid(app, :source) not in [nil, source] end)
    assert :sys.get_state(app).subscribers == %{}
  end

  @tag :capture_log
  test "a target already dead when unsubscribe is handled counts as detached" do
    app = app()
    source = Solve.controller_pid(app, :source)
    worker = worker()
    Solve.subscribe(app, :source, worker)

    task =
      suspended(app, fn ->
        task = Task.async(fn -> Solve.unsubscribe(app, :source, worker) end)

        eventually(fn ->
          {:messages, messages} = Process.info(app, :messages)
          Enum.any?(messages, &match?({:"$gen_call", _, {:unsubscribe, :source, ^worker}}, &1))
        end)

        ref = Process.monitor(source)
        Process.exit(source, :kill)
        assert_receive {:DOWN, ^ref, :process, ^source, :killed}
        task
      end)

    assert :ok = Task.await(task)
    eventually(fn -> Solve.controller_pid(app, :source) not in [nil, source] end)
    assert :sys.get_state(app).subscribers == %{}
    assert barrier(app, worker) == []
  end

  test "unexpected controller replies do not claim successful physical detachment" do
    app = app(FaultyApp, params: :bad_reply)
    source = Solve.controller_pid(app, :source)
    Solve.subscribe(app, :source)

    assert {:error, {:unsubscribe_failed, {:unexpected_reply, :unexpected}}} =
             Solve.unsubscribe(app, :source)

    assert :sys.get_state(app).subscribers == %{}
    assert Solve.controller_pid(app, :source) == source
  end

  test "new unsubscribe calls remove newer interests and names address the replacement app" do
    name = __MODULE__.Named
    first = app(App, name: name)
    worker = worker()
    Solve.subscribe(name, :source, worker)
    Solve.unsubscribe(name, :source, worker)
    Solve.subscribe(name, :source, worker)
    Solve.unsubscribe(name, :source, worker)
    assert :sys.get_state(first).subscribers == %{}
    GenServer.stop(first)
    replacement = app(App, name: name)
    Solve.subscribe(name, :source, worker)
    assert {:noproc, _} = catch_exit(Solve.unsubscribe(first, :source, worker))
    assert MapSet.member?(:sys.get_state(replacement).subscribers.source, worker)
    assert :ok = Solve.unsubscribe(name, :source, worker)
    assert :sys.get_state(replacement).subscribers == %{}
  end

  test "global and via app names support unsubscribe" do
    registry = start_supervised!({Registry, keys: :unique, name: __MODULE__.Registry})
    assert is_pid(registry)

    for name <- [
          {:global, {__MODULE__, make_ref()}},
          {:via, Registry, {__MODULE__.Registry, :app}}
        ] do
      app = app(App, name: name)
      Solve.subscribe(name, :source)
      assert :ok = Solve.unsubscribe(name, :source)
      assert :sys.get_state(app).subscribers == %{}
    end
  end

  test "subscription churn leaves no retained targets, monitors, or retry entries" do
    app = app()
    worker = worker()
    baseline = :sys.get_state(app)

    for id <- 1..50 do
      set(app, :catalog, [{id, true}])
      Solve.subscribe(app, {:items, id}, worker)
      assert :ok = Solve.unsubscribe(app, {:items, id}, worker)
    end

    set(app, :catalog, [])
    state = :sys.get_state(app)
    assert state.subscribers == baseline.subscribers
    assert state.subscriber_monitors == baseline.subscriber_monitors
    assert state.pending_attachments == baseline.pending_attachments
    assert Map.keys(state.targets) |> Enum.sort() == Map.keys(baseline.targets) |> Enum.sort()
    assert Process.info(app, :monitors) |> elem(1) |> length() == map_size(baseline.targets)
  end

  defp app(module \\ App, opts \\ []) do
    {:ok, app} = module.start_link(opts)

    on_exit(fn ->
      try do
        GenServer.stop(app, :shutdown)
      catch
        :exit, _ -> :ok
      end
    end)

    app
  end

  defp worker do
    start_supervised!(Supervisor.child_spec({Mailbox, []}, id: make_ref()))
  end

  # The marker and all preceding updates originate from the same publisher.
  defp barrier(publisher, worker) do
    caller = self()
    tag = make_ref()

    :sys.replace_state(publisher, fn state ->
      send(worker, {:barrier, caller, tag})
      state
    end)

    assert_receive {^tag, messages}, 1_000
    messages
  end

  defp set(app, target, value) do
    pid = Solve.controller_pid(app, target)
    Controller.dispatch(pid, :set, value)
    assert %Update{exposed_state: %{value: ^value}} = Controller.subscribe_snapshot(pid, app)

    eventually(fn ->
      :sys.get_state(app).targets[target].snapshot.exposed_state == %{value: value}
    end)
  end

  defp suspended(pid, fun) do
    :sys.suspend(pid)

    try do
      fun.()
    after
      :sys.resume(pid)
    end
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
