defmodule Solve.ControllerDepsChangeTest do
  use ExUnit.Case, async: true

  alias Solve.{Collection, Controller, DependencyUpdate, Message}

  defmodule Probe do
    use Solve.Controller, events: [:report]

    @impl true
    def init(params, dependencies) do
      if params[:mark_context], do: Process.put(:solve_app, :outside_hook)
      send(params.test_pid, {:init, self(), dependencies, params})
      %{calls: 0, test_pid: params.test_pid}
    end

    @impl true
    def deps_changed(state, dependencies, params) do
      send(
        state.test_pid,
        {:deps_changed, self(), state.calls, dependencies, params, Process.get(:solve_app)}
      )

      if dependencies[:source] == :crash, do: raise("dependency failure")
      %{state | calls: state.calls + 1}
    end

    @impl true
    def expose(state, dependencies, params) do
      send(state.test_pid, {:expose, self(), state.calls, dependencies, Process.get(:solve_app)})

      if params[:stable],
        do: %{visible: :constant},
        else: %{calls: state.calls, dependencies: dependencies}
    end

    def report(_payload, state) do
      send(state.test_pid, {:reported_state, state.calls})
      state
    end

    def handle_info(:external, state), do: report(nil, state)
  end

  defmodule Default do
    use Solve.Controller
    @impl true
    def init(_params, _dependencies), do: %{value: 1}
  end

  defmodule TupleState do
    use Solve.Controller
    @impl true
    def init(_params, _dependencies), do: {:calls, 0}
    @impl true
    def deps_changed({:calls, n}, _dependencies, _params), do: {:calls, n + 1}
    @impl true
    def expose({:calls, n}, _dependencies, _params), do: %{calls: n}
  end

  test "initialization runs init, deps_changed, expose in order, even with no dependencies" do
    for dependencies <- [%{}, %{source: %{value: 2}}] do
      params = %{test_pid: self()}
      pid = start_controller(Probe, params: params, dependencies: dependencies)
      assert_receive {:init, ^pid, ^dependencies, ^params}
      assert_receive {:deps_changed, ^pid, 0, ^dependencies, ^params, :app}
      assert_receive {:expose, ^pid, 1, ^dependencies, nil}
      assert Controller.subscribe(pid) == %{calls: 1, dependencies: dependencies}
      assert :sys.get_state(pid).revision == 0
    end
  end

  test "changed dependencies update stored user state before exposing and handling later events" do
    pid = probe(%{source: nil, other: %{value: 7}})
    send(pid, DependencyUpdate.replace(:app, :source, %{value: 2}))
    expected = %{source: %{value: 2}, other: %{value: 7}}
    assert Controller.subscribe(pid) == %{calls: 2, dependencies: expected}
    assert_receive {:deps_changed, ^pid, 1, ^expected, _, :app}
    assert_receive {:expose, ^pid, 2, ^expected, nil}
    Controller.dispatch(pid, :report)
    assert_receive {:reported_state, 2}
    send(pid, DependencyUpdate.replace(:app, :source, %{value: 3}))
    assert Controller.subscribe(pid).calls == 3
    assert_receive {:deps_changed, ^pid, 2, _, _, :app}
    refute_received {:init, ^pid, _, _}
  end

  test "private state changes persist without changing exposed revision or notifying subscribers" do
    pid = probe(%{source: nil}, %{stable: true})
    assert Controller.subscribe(pid) == %{visible: :constant}
    send(pid, DependencyUpdate.replace(:app, :source, %{value: 1}))
    assert Controller.subscribe(pid) == %{visible: :constant}
    assert :sys.get_state(pid).revision == 0
    Controller.dispatch(pid, :report)
    assert_receive {:reported_state, 2}
    refute_received %Message{type: :update}
  end

  test "the optional identity default preserves existing controllers and user state may be a tuple" do
    plain = start_controller(Default)
    assert Controller.subscribe(plain) == %{value: 1}
    send(plain, DependencyUpdate.replace(:app, :source, %{value: 2}))
    assert Controller.subscribe(plain) == %{value: 1}
    tuple = start_controller(TupleState)
    assert Controller.subscribe(tuple) == %{calls: 1}
    send(tuple, DependencyUpdate.replace(:app, :source, %{value: 2}))
    assert Controller.subscribe(tuple) == %{calls: 2}
  end

  test "events, external messages, callback updates and subscriptions do not rerun the hook" do
    pid = probe(%{source: nil})
    Controller.subscribe(pid)
    Controller.dispatch(pid, :report)
    send(pid, :external)
    Controller.update_callbacks(pid, %{other: :callback})
    Controller.subscribe_snapshot(pid, self())
    Controller.subscribe_dependency(pid, self(), :aliased)
    assert Controller.subscribe(pid).calls == 1
    assert_receive {:reported_state, 1}
    assert_receive {:reported_state, 1}
    refute_received {:deps_changed, ^pid, _, _, _, _}
  end

  test "equal values skip the hook but preserve the existing expose schedule and version fence" do
    pid =
      probe(%{source: %{value: 1}}, %{}, generation: 10, dependency_versions: %{source: {4, 1}})

    send(pid, DependencyUpdate.replace(:app, :source, %{value: 1}, {5, 0}))
    assert Controller.subscribe(pid).calls == 1
    assert :sys.get_state(pid).dependency_versions.source == {5, 0}
    assert_receive {:expose, ^pid, 1, _, nil}
    refute_received {:deps_changed, ^pid, _, _, _, _}

    for version <- [{4, 99}, {5, 0}, nil, {-1, 0}] do
      send(pid, DependencyUpdate.replace(:app, :source, %{value: 999}, version))
    end

    send(pid, DependencyUpdate.replace(:other_app, :source, %{value: 999}, {6, 0}))
    send(pid, Message.update(:app, :source, %{value: 999}))
    assert Controller.subscribe(pid) == %{calls: 1, dependencies: %{source: %{value: 1}}}
    refute_received {:deps_changed, ^pid, _, _, _, _}
    refute_received {:expose, ^pid, _, _, _}

    send(pid, DependencyUpdate.replace(:app, :source, %{value: 2}, {5, 1}))
    assert Controller.subscribe(pid).calls == 2
    assert_receive {:deps_changed, ^pid, 1, %{source: %{value: 2}}, _, :app}
  end

  test "exact equality distinguishes numbers and absent keys from nil, including stopped values" do
    pid = probe(%{})

    for {value, calls} <- [{nil, 2}, {%{value: 1}, 3}, {%{value: 1.0}, 4}, {nil, 5}] do
      send(pid, DependencyUpdate.replace(:app, :source, value))
      assert Controller.subscribe(pid) === %{calls: calls, dependencies: %{source: value}}
      assert_receive {:deps_changed, ^pid, _, %{source: ^value}, _, :app}
    end

    send(pid, DependencyUpdate.replace(:app, :source, nil))
    assert Controller.subscribe(pid).calls == 5
    refute_received {:deps_changed, ^pid, _, _, _, _}
  end

  test "legacy standalone updates use the same hook and ignore equal values" do
    pid = probe(%{source: nil})
    send(pid, Message.update(:app, :source, %{value: 42}))
    assert Controller.subscribe(pid).calls == 2
    assert_receive {:deps_changed, ^pid, 1, %{source: %{value: 42}}, _, :app}
    send(pid, Message.update(:app, :source, %{value: 42}))
    assert Controller.subscribe(pid).calls == 2
    refute_received {:deps_changed, ^pid, _, _, _, _}
  end

  test "collection replacements and patches expose complete snapshots and skip no-ops" do
    pid = probe(%{columns: Collection.empty()})
    one = Collection.new([{1, %{value: :a}}])
    two = Collection.new([{1, %{value: :a}}, {2, %{value: :b}}])
    reversed = Collection.new([{2, %{value: :b}}, {1, %{value: :a}}])

    for {update, expected, calls} <- [
          {DependencyUpdate.replace(:app, :columns, one), one, 2},
          {DependencyUpdate.collection_put(:app, :columns, 2, %{value: :b}), two, 3},
          {DependencyUpdate.collection_reorder(:app, :columns, [2, 1]), reversed, 4},
          {DependencyUpdate.collection_delete(:app, :columns, 2), one, 5}
        ] do
      send(pid, update)
      assert Controller.subscribe(pid) == %{calls: calls, dependencies: %{columns: expected}}
      assert_receive {:deps_changed, ^pid, _, %{columns: ^expected}, _, :app}
    end

    for update <- [
          DependencyUpdate.collection_put(:app, :columns, 1, %{value: :a}),
          DependencyUpdate.collection_delete(:app, :columns, :absent),
          DependencyUpdate.collection_reorder(:app, :columns, [1]),
          DependencyUpdate.replace(:app, :columns, one)
        ],
        do: send(pid, update)

    assert Controller.subscribe(pid).calls == 5
    refute_received {:deps_changed, ^pid, _, _, _, _}
  end

  test "Solve app context is scoped to the hook, including initialization" do
    params = %{test_pid: self(), mark_context: true}
    pid = start_controller(Probe, params: params)
    assert_receive {:init, ^pid, %{}, ^params}
    assert_receive {:deps_changed, ^pid, 0, %{}, ^params, :app}
    assert_receive {:expose, ^pid, 1, %{}, :outside_hook}
    send(pid, DependencyUpdate.replace(:app, :source, %{value: 1}))
    assert Controller.subscribe(pid).calls == 2
    assert_receive {:deps_changed, ^pid, 1, _, ^params, :app}
    assert_receive {:expose, ^pid, 2, _, :outside_hook}
  end

  test "a failing initial hook restores context and never reaches expose" do
    Process.put(:solve_app, :outer)
    on_exit(fn -> Process.delete(:solve_app) end)

    assert_raise RuntimeError, "dependency failure", fn ->
      Controller.__init__(Probe,
        solve_app: :inner,
        params: %{test_pid: self()},
        dependencies: %{source: :crash}
      )
    end

    assert Process.get(:solve_app) == :outer
    assert_received {:deps_changed, _, 0, %{source: :crash}, _, :inner}
    refute_received {:expose, _, _, _, _}
  end

  @tag :capture_log
  test "a failing update hook stops a standalone controller without exposing a partial result" do
    pid = probe(%{source: nil})
    Controller.subscribe(pid)
    ref = Process.monitor(pid)
    send(pid, DependencyUpdate.replace(:app, :source, :crash))
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    refute_received {:expose, ^pid, _, _, _}
    refute_received %Message{type: :update}
  end

  test "deps_changed is a lifecycle callback, not a declared event" do
    assert_raise CompileError, ~r/deps_changed.*reserved.*lifecycle/, fn ->
      Code.compile_string("""
      defmodule #{inspect(__MODULE__)}.InvalidEvent do
        use Solve.Controller, events: [:deps_changed]
        def init(_params, _dependencies), do: %{}
        def deps_changed(state, _dependencies, _params), do: state
      end
      """)
    end
  end

  defp probe(dependencies, extra_params \\ %{}, opts \\ []) do
    params = Map.merge(%{test_pid: self()}, extra_params)
    pid = start_controller(Probe, Keyword.merge(opts, params: params, dependencies: dependencies))
    assert_receive {:init, ^pid, ^dependencies, ^params}
    assert_receive {:deps_changed, ^pid, 0, ^dependencies, ^params, :app}
    assert_receive {:expose, ^pid, 1, ^dependencies, nil}
    pid
  end

  defp start_controller(module, opts \\ []) do
    opts = Keyword.merge([params: true, dependencies: %{}, solve_app: :app], opts)

    start_supervised!(%{
      id: make_ref(),
      start: {module, :start_link, [opts]},
      restart: :temporary
    })
  end
end
