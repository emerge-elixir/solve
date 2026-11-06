defmodule Solve.OptimizationTest do
  use ExUnit.Case, async: false

  alias Solve.{Collection, Controller, DependencyUpdate}

  defmodule Item do
    use Solve.Controller, events: [:set]
    @impl true
    def init(_params, _dependencies), do: %{value: 0}
    def set(value, state), do: %{state | value: value}
  end

  defmodule Sum do
    use Solve.Controller
    @impl true
    def init(_params, _dependencies), do: %{}
    @impl true
    def expose(_state, %{items: items}, _params),
      do: %{sum: Enum.reduce(items, 0, fn {_, item}, sum -> sum + item.value end)}
  end

  defmodule Graph do
    use Solve
    @impl true
    def controllers do
      [
        controller!(
          name: :items,
          module: Item,
          variant: :collection,
          collect: fn _ -> Enum.map(1..10, &{&1, true}) end
        ),
        controller!(
          name: :sum,
          module: Sum,
          dependencies: [items: collection(:items, &__MODULE__.keep/2)]
        ),
        controller!(
          name: :inactive,
          module: Sum,
          params: false,
          dependencies: [items: collection(:items, &__MODULE__.inactive_filter/2)]
        )
      ]
    end

    def keep(_id, _value), do: true
    def inactive_filter(_id, _value), do: true
  end

  defmodule Refuses do
    use Solve.Controller
    @impl true
    def init(_params, _dependencies), do: %{attempts: 0, accept?: false}
    defoverridable handle_call: 3
    @impl true
    def handle_call({:subscribe_dependency, _, _} = message, from, state) do
      state = update_in(state.state.attempts, &(&1 + 1))
      if state.state.accept?, do: super(message, from, state), else: {:reply, :failed, state}
    end

    def handle_call(message, from, state), do: super(message, from, state)
  end

  defmodule RetryGraph do
    use Solve
    @impl true
    def controllers do
      Enum.map([:a, :b, :c], &controller!(name: &1, module: Refuses)) ++
        [controller!(name: :sink, module: Item, dependencies: [:a, :b, :c])]
    end
  end

  defmodule HookMacro do
    defmacro __using__(_opts) do
      quote do
        @impl true
        def deps_changed(state, _dependencies, _params), do: %{state | value: state.value + 1}
      end
    end
  end

  defmodule MacroHook do
    use Solve.Controller
    use HookMacro
    @impl true
    def init(_params, _dependencies), do: %{value: 0}
  end

  defmodule LateHookMacro do
    defmacro __before_compile__(_env) do
      quote do
        defoverridable deps_changed: 3
        @impl true
        def deps_changed(state, _dependencies, _params), do: %{state | value: state.value + 1}
      end
    end
  end

  defmodule LateHook do
    use Solve.Controller
    @before_compile LateHookMacro
    @impl true
    def init(_params, _dependencies), do: %{value: 0}
  end

  defmodule SuperHook do
    use Solve.Controller
    @impl true
    def init(_params, _dependencies), do: %{value: 0}
    @impl true
    def deps_changed(state, %{special: true}, _params), do: %{state | value: 42}
    def deps_changed(state, dependencies, params), do: super(state, dependencies, params)
  end

  test "absent hooks do no callback/context work, while macro and super overrides remain enabled" do
    patterns = [{Item, :deps_changed, 3}, {Controller, :run_deps_changed, 5}]

    assert {_, [0, 0]} =
             counts(patterns, fn ->
               pid = start_supervised!({Item, params: true})
               for value <- 1..3, do: send(pid, DependencyUpdate.replace(nil, :source, value))
               assert :sys.get_state(pid).dependencies.source == 3
             end)

    macro = start_supervised!({MacroHook, params: true})
    assert Controller.subscribe(macro).value == 1
    send(macro, DependencyUpdate.replace(nil, :source, 1))
    assert Controller.subscribe(macro).value == 2
    super = start_supervised!({SuperHook, params: true})
    assert Controller.subscribe(super).value == 0
    send(super, DependencyUpdate.replace(nil, :special, true))
    assert Controller.subscribe(super).value == 42

    late = start_supervised!({LateHook, params: true})
    assert Controller.subscribe(late).value == 1
    send(late, DependencyUpdate.replace(nil, :source, 1))
    assert Controller.subscribe(late).value == 2
  end

  test "projection is reused during startup and updates; literal inactive targets never filter" do
    patterns = [{Graph, :keep, 2}, {Graph, :inactive_filter, 2}]
    assert {app, [10, 0]} = counts(patterns, fn -> start_supervised!({Graph, name: nil}) end)
    child = Solve.controller_pid(app, {:items, 1})

    assert {_, [10, 0]} =
             counts(patterns, fn ->
               Controller.dispatch(child, :set, 7)
               :sys.get_state(child)
               :sys.get_state(app)
               assert Solve.subscribe(app, :sum).sum == 7
             end)
  end

  test "collection reduction can halt before fetching later IDs and supports suspended continuations" do
    # The deliberately incomplete tail detects eager fetching without timing assertions.
    collection = %Collection{ids: [:first, :unread], items: %{first: 1}}
    assert Enum.take(collection, 1) == [first: 1]

    assert Enumerable.reduce(collection, {:halt, :done}, fn _, _ -> flunk() end) ==
             {:halted, :done}

    valid = Collection.new([{1, nil}, {1.0, :float}, {:last, 3}])
    reducer = fn item, acc -> {:suspend, [item | acc]} end
    assert {:suspended, [], resume} = Enumerable.reduce(valid, {:suspend, []}, reducer)
    assert {:suspended, [{1, nil}], resume} = resume.({:cont, []})
    assert {:suspended, [{1.0, :float}, {1, nil}], resume} = resume.({:cont, [{1, nil}]})
    assert {:halted, :done} = resume.({:halt, :done})
    assert Enum.to_list(valid) === [{1, nil}, {1.0, :float}, {:last, 3}]
    assert Enum.count(valid) == 3
    assert Collection.delete(valid, :missing) === valid
  end

  test "external fanout constructs one common snapshot, without merging encoded or aliased subscriptions" do
    pid = start_supervised!({Item, params: true, solve_app: self(), generation: 1})

    subscribers =
      for _ <- 1..10,
          do:
            spawn(fn ->
              receive do
                :stop -> :ok
              end
            end)

    on_exit(fn -> Enum.each(subscribers, &send(&1, :stop)) end)
    Enum.each(subscribers, &Controller.subscribe(pid, &1))
    Controller.subscribe_dependency(pid, self(), :left)
    Controller.subscribe_dependency(pid, self(), :right)
    Controller.subscribe_with(pid, self(), fn value -> {:encoded, value} end)
    Controller.subscribe_with(pid, self(), fn _ -> nil end)

    assert {_, [1]} =
             counts([{Controller, :__snapshot__, 1}], fn ->
               Controller.dispatch(pid, :set, 1)
               :sys.get_state(pid)
             end)

    assert_receive %DependencyUpdate{key: :left, value: %{value: 1}, version: {1, 1}}
    assert_receive %DependencyUpdate{key: :right, value: %{value: 1}, version: {1, 1}}
    assert_receive {:encoded, %{value: 1}}
  end

  test "three failed bindings have one bounded retry chain even during repeated reconciliations" do
    app = start_supervised!({RetryGraph, name: nil})
    await(fn -> attempts(app) == [4, 4, 4] end)
    state = :sys.get_state(app)
    assert state.targets.sink.binding_retry.timer == nil

    for revision <- 1..10 do
      source = :sys.get_state(app).targets.a.snapshot
      send(app, Solve.Update.message(%{source | version: {elem(source.version, 0), revision}}))
      :sys.get_state(app)
    end

    assert attempts(app) == [4, 4, 4]
  end

  test "successful bindings survive other retries; canceled and obsolete retry messages do no work" do
    app = start_supervised!({RetryGraph, name: nil})
    state = :sys.get_state(app)
    retry = state.targets.sink.binding_retry
    generation = elem(state.targets.sink.snapshot.version, 0)
    a = state.targets.a.pid
    :sys.replace_state(a, &put_in(&1.state.accept?, true))
    await(fn -> attempts(app) == [2, 4, 4] end)
    send(app, {:retry_bindings, :sink, generation, retry.token, retry.attempt})
    send(app, {:retry_bindings, :sink, generation, make_ref(), 1})
    :sys.get_state(app)
    assert attempts(app) == [2, 4, 4]
    assert :sys.get_state(app).targets.sink.bindings.a.pid == a
  end

  test "pending reconciliations retain the retry token and do not add attachment attempts" do
    app = start_supervised!({RetryGraph, name: nil})

    :sys.replace_state(app, fn state ->
      retry = state.targets.sink.binding_retry
      Process.cancel_timer(retry.timer)
      before = Enum.map([:a, :b, :c], &:sys.get_state(state.targets[&1].pid).state.attempts)

      state =
        Enum.reduce(1..20, state, fn _, acc ->
          source = acc.targets.a.snapshot
          {generation, revision} = source.version
          message = Solve.Update.message(%{source | version: {generation, revision + 1}})
          {:noreply, next} = Solve.Runtime.handle_info(message, acc)
          next
        end)

      assert state.targets.sink.binding_retry === retry

      assert Enum.map([:a, :b, :c], &:sys.get_state(state.targets[&1].pid).state.attempts) ==
               before

      state
    end)
  end

  @tag :capture_log
  test "source replacement renews exhausted attachment work and fences the old chain" do
    app = start_supervised!({RetryGraph, name: nil})
    await(fn -> attempts(app) == [4, 4, 4] end)
    old = :sys.get_state(app)
    Process.exit(old.targets.a.pid, :kill)
    await(fn -> :sys.get_state(app).targets.a.pid != old.targets.a.pid end)
    current = :sys.get_state(app)
    refute current.targets.sink.binding_retry.token == old.targets.sink.binding_retry.token
    assert current.targets.sink.pid == old.targets.sink.pid
    retry = old.targets.sink.binding_retry

    send(
      app,
      {:retry_bindings, :sink, elem(old.targets.sink.snapshot.version, 0), retry.token, 1}
    )

    await(fn -> attempts(app) == [4, 7, 7] end)
  end

  test "ordinary child revisions update one item without rematerializing the collection" do
    app = start_supervised!({Graph, name: nil})
    before = Solve.subscribe_snapshot(app, :items, self())
    child = Solve.controller_pid(app, {:items, 1})

    assert {_, [0]} =
             counts([{Solve.Runtime, :materialize_collection, 3}], fn ->
               Controller.dispatch(child, :set, 1.0)
               :sys.get_state(child)
               :sys.get_state(app)
             end)

    after_update = Solve.subscribe_snapshot(app, :items, self())
    assert after_update.routes === before.routes
    assert after_update.exposed_state.ids === before.exposed_state.ids
    assert after_update.exposed_state.items[1].value === 1.0

    assert Map.delete(after_update.exposed_state.items, 1) ===
             Map.delete(before.exposed_state.items, 1)
  end

  defp attempts(app) do
    state = :sys.get_state(app)
    Enum.map([:a, :b, :c], &:sys.get_state(state.targets[&1].pid).state.attempts)
  end

  defp counts(patterns, fun) do
    Enum.each(patterns, fn {module, _, _} = pattern ->
      Code.ensure_loaded!(module)
      assert :erlang.trace_pattern(pattern, true, [:local, :call_count]) == 1
    end)

    try do
      result = fun.()

      counts =
        Enum.map(patterns, fn pattern ->
          {:call_count, count} = :erlang.trace_info(pattern, :call_count)
          count
        end)

      {result, counts}
    after
      Enum.each(patterns, &:erlang.trace_pattern(&1, false, [:local, :call_count]))
    end
  end

  defp await(fun, left \\ 200)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, left) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await(fun, left - 1)
        )
  end
end
