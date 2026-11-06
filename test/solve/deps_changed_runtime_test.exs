defmodule Solve.DepsChangedRuntimeTest do
  use ExUnit.Case, async: false

  alias Solve.{Collection, Controller}

  defmodule Source do
    use Solve.Controller, events: [:set]
    @impl true
    def init(params, _dependencies), do: %{value: params.value}
    def set(value, state), do: %{state | value: value}
  end

  defmodule Derived do
    use Solve.Controller, events: [:mark]
    @impl true
    def init(params, _dependencies) do
      send(params.test_pid, {:derived_init, self()})
      %{calls: 0, local: nil, dependencies: %{}}
    end

    @impl true
    def deps_changed(state, dependencies, params) do
      send(params.test_pid, {:derived_change, self(), dependencies})
      %{state | calls: state.calls + 1, dependencies: dependencies}
    end

    def mark(value, state), do: %{state | local: value}
  end

  defmodule Chain do
    use Solve
    @impl true
    def controllers do
      [
        controller!(
          name: :settings,
          module: Source,
          params: %{value: %{enabled: true, seed: 1, token: 0}}
        ),
        controller!(
          name: :source,
          module: Source,
          dependencies: [:settings],
          params: fn %{dependencies: %{settings: %{value: settings}}} ->
            if settings.enabled, do: %{value: settings.seed, token: settings.token}
          end
        ),
        controller!(
          name: :derived,
          module: Derived,
          dependencies: [input: :source],
          params: fn %{app_params: params} -> params end
        )
      ]
    end
  end

  defmodule ChangingParams do
    use Solve
    @impl true
    def controllers do
      [
        controller!(name: :source, module: Source, params: %{value: 1}),
        controller!(
          name: :derived,
          module: Derived,
          dependencies: [:source],
          params: fn %{app_params: params, dependencies: %{source: %{value: value}}} ->
            Map.put(params, :bucket, div(value, 10))
          end
        )
      ]
    end
  end

  defmodule Items do
    use Solve
    @impl true
    def controllers do
      [
        controller!(
          name: :catalog,
          module: Source,
          params: fn %{app_params: params} -> %{value: params.items} end
        ),
        controller!(
          name: :items,
          module: Source,
          variant: :collection,
          dependencies: [:catalog],
          collect: fn %{dependencies: %{catalog: %{value: items}}} -> items end
        ),
        controller!(
          name: :all,
          module: Derived,
          dependencies: [columns: collection(:items)],
          params: fn %{app_params: params} -> params end
        ),
        controller!(
          name: :visible,
          module: Derived,
          dependencies: [columns: collection(:items, fn _id, item -> item.value.visible? end)],
          params: fn %{app_params: params} -> params end
        )
      ]
    end
  end

  defmodule Failure do
    use Solve.Controller
    @impl true
    def init(_params, _dependencies), do: %{calls: 0, dependencies: %{}}
    @impl true
    def deps_changed(state, dependencies, params) do
      attempt = Agent.get_and_update(params.counter, &{&1 + 1, &1 + 1})
      send(params.test_pid, {:attempt, self(), attempt})
      if params.fail_on == :always or attempt in params.fail_on, do: raise("hook failure")
      %{state | calls: state.calls + 1, dependencies: dependencies}
    end
  end

  defmodule FailingGraph do
    use Solve
    @impl true
    def controllers do
      [
        controller!(name: :source, module: Source, params: %{value: 1}),
        controller!(
          name: :derived,
          module: Failure,
          dependencies: [:source],
          params: fn %{app_params: params} -> params end
        )
      ]
    end
  end

  test "initial handshake does not double count; aliases and local state survive updates" do
    app = start_app(Chain)
    derived = Solve.controller_pid(app, :derived)
    source = Solve.controller_pid(app, :source)
    await_binding(app, :derived, :input, :source)

    assert Solve.subscribe(app, :derived) == %{
             calls: 1,
             local: nil,
             dependencies: %{input: %{value: 1}}
           }

    assert_receive {:derived_init, ^derived}
    assert_receive {:derived_change, ^derived, %{input: %{value: 1}}}
    refute_received {:derived_change, ^derived, _}

    Controller.dispatch(derived, :mark, :kept)
    Controller.subscribe(derived)
    set(source, 2)
    eventually(fn -> Solve.subscribe(app, :derived).dependencies == %{input: %{value: 2}} end)
    assert Solve.subscribe(app, :derived).calls == 2
    assert Solve.subscribe(app, :derived).local == :kept
    assert Solve.controller_pid(app, :derived) == derived
    refute_received {:derived_init, ^derived}
  end

  test "same-valued source replacement skips the hook, but stopped values and recovery change it" do
    app = start_app(Chain)
    derived = Solve.controller_pid(app, :derived)
    old_source = Solve.controller_pid(app, :source)
    set(Solve.controller_pid(app, :settings), %{enabled: true, seed: 1, token: 1})
    eventually(fn -> Solve.controller_pid(app, :source) not in [nil, old_source] end)
    await_binding(app, :derived, :input, :source)
    assert Solve.subscribe(app, :derived).calls == 1

    set(Solve.controller_pid(app, :settings), %{enabled: false, seed: 1, token: 1})
    eventually(fn -> Solve.subscribe(app, :derived).dependencies == %{input: nil} end)
    assert Solve.subscribe(app, :derived).calls == 2
    set(Solve.controller_pid(app, :settings), %{enabled: true, seed: 8, token: 1})
    eventually(fn -> Solve.subscribe(app, :derived).dependencies == %{input: %{value: 8}} end)
    assert Solve.subscribe(app, :derived).calls == 3
    assert Solve.controller_pid(app, :derived) == derived
  end

  test "changed params replace the controller and initialize derived state from the current snapshot" do
    app = start_app(ChangingParams)
    before = Solve.controller_pid(app, :derived)
    set(Solve.controller_pid(app, :source), 2)
    eventually(fn -> Solve.subscribe(app, :derived).dependencies == %{source: %{value: 2}} end)
    assert Solve.subscribe(app, :derived).calls == 2
    assert Solve.controller_pid(app, :derived) == before
    Controller.dispatch(before, :mark, :old_state)
    Controller.subscribe(before)
    set(Solve.controller_pid(app, :source), 21)
    eventually(fn -> Solve.controller_pid(app, :derived) not in [nil, before] end)
    await_binding(app, :derived, :source, :source)

    assert Solve.subscribe(app, :derived) == %{
             calls: 1,
             local: nil,
             dependencies: %{source: %{value: 21}}
           }
  end

  @tag :capture_log
  test "a restarted dependent rebuilds rather than carrying its old accumulator" do
    app = start_app(Chain)
    before = Solve.controller_pid(app, :derived)
    set(Solve.controller_pid(app, :source), 9)
    eventually(fn -> Solve.subscribe(app, :derived).calls == 2 end)
    Process.exit(before, :kill)
    eventually(fn -> Solve.controller_pid(app, :derived) not in [nil, before] end)
    await_binding(app, :derived, :input, :source)

    assert Solve.subscribe(app, :derived) == %{
             calls: 1,
             local: nil,
             dependencies: %{input: %{value: 9}}
           }
  end

  test "collection hooks receive whole ordered snapshots, including filtered membership" do
    first = {1, %{value: %{number: 10, visible?: true}}}
    second = {2, %{value: %{number: 20, visible?: false}}}
    app = start_app(Items, %{items: [first, second]})
    assert columns(app, :all).ids == [1, 2]
    assert columns(app, :visible).ids == [1]
    set(Solve.controller_pid(app, {:items, 2}), %{number: 21, visible?: true})
    eventually(fn -> columns(app, :visible).ids == [1, 2] end)

    assert %Collection{
             ids: [1, 2],
             items: %{1 => %{value: %{number: 10}}, 2 => %{value: %{number: 21}}}
           } = columns(app, :all)

    set(Solve.controller_pid(app, :catalog), [second, first])

    eventually(fn ->
      columns(app, :all).ids == [2, 1] and columns(app, :visible).ids == [2, 1]
    end)

    set(Solve.controller_pid(app, :catalog), [first])
    eventually(fn -> columns(app, :all).ids == [1] and columns(app, :visible).ids == [1] end)
    assert Map.keys(columns(app, :all).items) == [1]
  end

  test "collection route-only changes advance the fence without rerunning the hook" do
    value = %{number: 10, visible?: true}
    app = start_app(Items, %{items: [{1, %{value: value, token: 0}}]})
    old = Solve.controller_pid(app, {:items, 1})
    set(Solve.controller_pid(app, :catalog), [{1, %{value: value, token: 1}}])
    eventually(fn -> Solve.controller_pid(app, {:items, 1}) not in [nil, old] end)

    for target <- [:all, :visible] do
      await_binding(app, target, :columns, :items)
      assert Solve.subscribe(app, target).calls == 1
    end
  end

  @tag :capture_log
  test "initial and later hook failures use existing restart handling without partial exposure" do
    counter = start_supervised!({Agent, fn -> 0 end})
    app = start_app(FailingGraph, %{counter: counter, fail_on: [1, 3]})
    before = Solve.controller_pid(app, :derived)
    assert Agent.get(counter, & &1) == 2
    assert Solve.subscribe(app, :derived) == %{calls: 1, dependencies: %{source: %{value: 1}}}
    set(Solve.controller_pid(app, :source), 2)

    assert_receive %Solve.Message{
      payload: %Solve.Update{controller_name: :derived, exposed_state: nil}
    }

    eventually(fn -> Solve.controller_pid(app, :derived) not in [nil, before] end)

    eventually(fn ->
      Solve.subscribe(app, :derived) == %{calls: 1, dependencies: %{source: %{value: 2}}}
    end)

    assert Agent.get(counter, & &1) == 4
    assert Process.alive?(app)
  end

  @tag :capture_log
  test "a persistently failing initial hook exhausts the existing restart budget" do
    Process.flag(:trap_exit, true)
    counter = start_supervised!({Agent, fn -> 0 end})

    assert {:error, {:controller_restart_limit_exceeded, :derived, _}} =
             FailingGraph.start_link(
               name: nil,
               params: %{test_pid: self(), counter: counter, fail_on: :always}
             )

    assert Agent.get(counter, & &1) == 4
  end

  defp columns(app, target), do: Solve.subscribe(app, target).dependencies.columns

  defp start_app(module, params \\ %{}),
    do: start_supervised!({module, name: nil, params: Map.put(params, :test_pid, self())})

  defp set(pid, value) do
    Controller.dispatch(pid, :set, value)
    Controller.subscribe(pid)
  end

  defp await_binding(app, target, key, source) do
    version = Solve.subscribe_snapshot(app, source).version
    pid = Solve.controller_pid(app, target)
    eventually(fn -> :sys.get_state(pid).dependency_versions[key] == version end)
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
end
