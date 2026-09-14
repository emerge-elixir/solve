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

  defmodule NeverResolve do
    def whereis_name(_name), do: raise("unsubscribe must not resolve an unknown alias")
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
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

  defp cache, do: Process.get({Lookup, :cache}, %{apps: %{}, aliases: %{}})

  defp assert_empty_cache, do: assert(cache() == %{apps: %{}, aliases: %{}})

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
