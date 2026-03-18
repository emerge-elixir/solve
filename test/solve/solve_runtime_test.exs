defmodule Solve.RuntimeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule LifecycleSourceController do
    use Solve.Controller, events: [:set]

    @impl true
    def init(%{value: value, test_pid: test_pid} = params, dependencies) do
      send(test_pid, {:source_init, value, dependencies, params})
      %{value: value}
    end

    def set(value, _state, _dependencies, _callbacks, _init_params), do: %{value: value}
  end

  defmodule LifecycleDerivedController do
    use Solve.Controller, events: []

    @impl true
    def init(%{label: label, test_pid: test_pid} = params, dependencies) do
      send(test_pid, {:derived_init, label, dependencies, params})
      {:derived_state, label}
    end

    @impl true
    def expose(state, dependencies, %{label: label}) do
      %{label: label, source: Map.get(dependencies, :source), state: state}
    end
  end

  defmodule StableDerivedController do
    use Solve.Controller, events: []

    @impl true
    def init(%{mode: mode, test_pid: test_pid} = params, dependencies) do
      send(test_pid, {:stable_init, mode, dependencies, params})
      :stable
    end

    @impl true
    def expose(state, dependencies, %{mode: mode}) do
      %{mode: mode, source: Map.get(dependencies, :source), state: state}
    end
  end

  defmodule CrashyController do
    use Solve.Controller, events: [:crash]

    @impl true
    def init(%{value: value, test_pid: test_pid}, _dependencies) do
      send(test_pid, {:crashy_init, value})
      %{value: value}
    end

    def crash(reason, _state, _dependencies, _callbacks, _init_params) do
      raise "crash: #{inspect(reason)}"
    end
  end

  defmodule BootRetryController do
    use Solve.Controller, events: []

    @impl true
    def init(%{counter: counter, fail_until: fail_until, test_pid: test_pid}, _dependencies) do
      attempt =
        Agent.get_and_update(counter, fn count ->
          next = count + 1
          {next, next}
        end)

      send(test_pid, {:boot_retry_attempt, attempt})

      if attempt <= fail_until do
        raise "boot failure #{attempt}"
      end

      %{attempt: attempt}
    end
  end

  defmodule LifecycleSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :source,
          module: Solve.RuntimeTest.LifecycleSourceController,
          params: fn %{app_params: app_params} ->
            %{value: app_params.source_initial, test_pid: app_params.test_pid}
          end
        ),
        controller!(
          name: :derived,
          module: Solve.RuntimeTest.LifecycleDerivedController,
          dependencies: [:source],
          params: fn %{dependencies: dependencies, app_params: app_params} ->
            case dependencies[:source] do
              nil -> false
              %{value: 0} -> false
              %{value: value} -> %{label: value, test_pid: app_params.test_pid}
            end
          end
        )
      ]
    end
  end

  defmodule StableParamsSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :source,
          module: Solve.RuntimeTest.LifecycleSourceController,
          params: fn %{app_params: app_params} ->
            %{value: app_params.source_initial, test_pid: app_params.test_pid}
          end
        ),
        controller!(
          name: :stable,
          module: Solve.RuntimeTest.StableDerivedController,
          dependencies: [:source],
          params: fn %{dependencies: dependencies, app_params: app_params} ->
            case dependencies[:source] do
              nil -> false
              %{value: 0} -> false
              _value -> %{mode: :positive, test_pid: app_params.test_pid}
            end
          end
        )
      ]
    end
  end

  defmodule CrashySolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :crashy,
          module: Solve.RuntimeTest.CrashyController,
          params: fn %{app_params: app_params} ->
            %{value: app_params.initial, test_pid: app_params.test_pid}
          end
        )
      ]
    end
  end

  defmodule BootRetrySolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :boot,
          module: Solve.RuntimeTest.BootRetryController,
          params: fn %{app_params: app_params} -> app_params end
        )
      ]
    end
  end

  test "starts controllers in topological order and caches exposed state" do
    app = start_app(LifecycleSolve, %{source_initial: 1, test_pid: self()})

    assert_receive {:source_init, 1, %{}, %{value: 1, test_pid: test_pid}}
    assert test_pid == self()

    assert_receive {:derived_init, 1, %{source: %{value: 1}}, %{label: 1, test_pid: test_pid}}
    assert test_pid == self()

    assert Solve.subscribe(app, :source) == %{value: 1}

    assert Solve.subscribe(app, :derived) == %{
             label: 1,
             source: %{value: 1},
             state: {:derived_state, 1}
           }

    state = :sys.get_state(app)

    assert state.controller_status_by_name == %{derived: :started, source: :started}
    assert is_pid(state.controller_pids_by_name.source)
    assert is_pid(state.controller_pids_by_name.derived)
  end

  test "controllers start, replace, stop, and restart from params changes" do
    app = start_app(LifecycleSolve, %{source_initial: 0, test_pid: self()})

    assert_receive {:source_init, 0, %{}, %{value: 0, test_pid: test_pid}}
    assert test_pid == self()
    refute_receive {:derived_init, _, _, _}

    assert Solve.subscribe(app, :derived) == nil
    assert Solve.controller_pid(app, :derived) == nil

    assert :ok = Solve.dispatch(app, :derived, :ignored, :payload)
    assert :ok = Solve.dispatch(app, :missing, :ignored, :payload)
    refute_receive {:solve_update, ^app, :derived, _}, 50

    assert :ok = Solve.dispatch(app, :source, :set, 1)

    assert_receive {:derived_init, 1, %{source: %{value: 1}}, %{label: 1, test_pid: test_pid}}
    assert test_pid == self()

    assert_receive {:solve_update, ^app, :derived,
                    %{label: 1, source: %{value: 1}, state: {:derived_state, 1}}}

    derived_pid = await_controller_pid(app, :derived)

    assert :ok = Solve.dispatch(app, :source, :set, 2)

    assert_receive {:derived_init, 2, %{source: %{value: 2}}, %{label: 2, test_pid: test_pid}}
    assert test_pid == self()

    assert_receive {:solve_update, ^app, :derived,
                    %{label: 2, source: %{value: 2}, state: {:derived_state, 2}}}

    refute_receive {:solve_update, ^app, :derived, nil}, 50
    refute await_pid_change(app, :derived, derived_pid) == derived_pid

    assert :ok = Solve.dispatch(app, :source, :set, 0)
    assert_receive {:solve_update, ^app, :derived, nil}
    assert await_controller_stop(app, :derived) == nil

    assert :ok = Solve.dispatch(app, :derived, :ignored, :payload)
    assert :ok = Solve.dispatch(app, :source, :set, 1)

    assert_receive {:derived_init, 1, %{source: %{value: 1}}, %{label: 1, test_pid: test_pid}}
    assert test_pid == self()

    assert_receive {:solve_update, ^app, :derived,
                    %{label: 1, source: %{value: 1}, state: {:derived_state, 1}}}
  end

  test "truthy params that stay equal keep the current controller instance" do
    app = start_app(StableParamsSolve, %{source_initial: 1, test_pid: self()})

    assert_receive {:source_init, 1, %{}, %{value: 1, test_pid: test_pid}}
    assert test_pid == self()

    assert_receive {:stable_init, :positive, %{source: %{value: 1}},
                    %{mode: :positive, test_pid: test_pid}}

    assert test_pid == self()

    assert Solve.subscribe(app, :stable) == %{
             mode: :positive,
             source: %{value: 1},
             state: :stable
           }

    stable_pid = Solve.controller_pid(app, :stable)

    assert :ok = Solve.dispatch(app, :source, :set, 2)

    assert_receive {:solve_update, ^app, :stable,
                    %{mode: :positive, source: %{value: 2}, state: :stable}}

    refute_receive {:stable_init, _, _, _}, 50
    assert Solve.controller_pid(app, :stable) == stable_pid
  end

  test "runtime crashes restart the controller within budget" do
    app = start_app(CrashySolve, %{initial: 1, test_pid: self()})

    assert_receive {:crashy_init, 1}
    assert Solve.subscribe(app, :crashy) == %{value: 1}

    pid = Solve.controller_pid(app, :crashy)

    capture_log(fn ->
      assert :ok = Solve.dispatch(app, :crashy, :crash, :boom)

      assert_receive {:solve_update, ^app, :crashy, nil}
      assert_receive {:crashy_init, 1}
      assert_receive {:solve_update, ^app, :crashy, %{value: 1}}
    end)

    refute await_pid_change(app, :crashy, pid) == pid
    assert Process.alive?(app)
  end

  test "exceeding restart budget stops the solve app" do
    original = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, original) end)

    app = start_app(CrashySolve, %{initial: 1, test_pid: self()})

    assert_receive {:crashy_init, 1}
    assert Solve.subscribe(app, :crashy) == %{value: 1}

    capture_log(fn ->
      Enum.each(1..3, fn attempt ->
        assert :ok = Solve.dispatch(app, :crashy, :crash, attempt)

        assert_receive {:solve_update, ^app, :crashy, nil}
        assert_receive {:crashy_init, 1}
        assert_receive {:solve_update, ^app, :crashy, %{value: 1}}
      end)

      assert :ok = Solve.dispatch(app, :crashy, :crash, :final)

      assert_receive {:solve_update, ^app, :crashy, nil}
      assert_receive {:EXIT, ^app, {:controller_restart_limit_exceeded, :crashy, _reason}}, 1_000
    end)
  end

  test "boot-time failures use the same retry budget and can recover" do
    counter = start_supervised!({Agent, fn -> 0 end})

    app =
      start_app(BootRetrySolve, %{counter: counter, fail_until: 2, test_pid: self()})

    assert_receive {:boot_retry_attempt, 1}
    assert_receive {:boot_retry_attempt, 2}
    assert_receive {:boot_retry_attempt, 3}

    assert Solve.subscribe(app, :boot) == %{attempt: 3}
  end

  test "boot-time restart budget exhaustion returns an error" do
    original = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, original) end)

    counter = start_supervised!({Agent, fn -> 0 end})

    assert {:error, {:controller_restart_limit_exceeded, :boot, _reason}} =
             BootRetrySolve.start_link(
               name: unique_name("boot_failure"),
               params: %{counter: counter, fail_until: 4, test_pid: self()}
             )

    assert_receive {:boot_retry_attempt, 1}
    assert_receive {:boot_retry_attempt, 2}
    assert_receive {:boot_retry_attempt, 3}
    assert_receive {:boot_retry_attempt, 4}
  end

  defp start_app(module, app_params) do
    name = unique_name(module)
    assert {:ok, pid} = module.start_link(name: name, params: app_params)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    pid
  end

  defp await_controller_pid(app, controller_name, attempts \\ 50)

  defp await_controller_pid(_app, controller_name, 0) do
    flunk("controller #{inspect(controller_name)} did not start in time")
  end

  defp await_controller_pid(app, controller_name, attempts) do
    case Solve.controller_pid(app, controller_name) do
      pid when is_pid(pid) ->
        pid

      _ ->
        Process.sleep(10)
        await_controller_pid(app, controller_name, attempts - 1)
    end
  end

  defp await_controller_stop(app, controller_name, attempts \\ 50)

  defp await_controller_stop(_app, controller_name, 0) do
    flunk("controller #{inspect(controller_name)} did not stop in time")
  end

  defp await_controller_stop(app, controller_name, attempts) do
    case Solve.controller_pid(app, controller_name) do
      nil ->
        nil

      _pid ->
        Process.sleep(10)
        await_controller_stop(app, controller_name, attempts - 1)
    end
  end

  defp await_pid_change(app, controller_name, old_pid, attempts \\ 50)

  defp await_pid_change(_app, controller_name, old_pid, 0) do
    flunk("controller #{inspect(controller_name)} pid did not change from #{inspect(old_pid)}")
  end

  defp await_pid_change(app, controller_name, old_pid, attempts) do
    case Solve.controller_pid(app, controller_name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _pid ->
        Process.sleep(10)
        await_pid_change(app, controller_name, old_pid, attempts - 1)
    end
  end

  defp unique_name(prefix) do
    Module.concat(__MODULE__, String.to_atom("#{prefix}_#{System.unique_integer([:positive])}"))
  end

  defp stop_process(pid) do
    GenServer.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
