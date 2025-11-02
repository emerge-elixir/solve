defmodule Bonseki.UITest do
  use ExUnit.Case, async: false

  defmodule CounterController do
    use Bonseki.Controller, events: [:increment, :reset]

    def init(_dependencies) do
      %{count: 0}
    end

    def increment(state, _params) do
      %{state | count: state.count + 1}
    end

    def reset(_state, _params) do
      %{count: 0}
    end

    @impl true
    def expose(state, _dependencies) do
      state
    end
  end

  defmodule ThresholdController do
    use Bonseki.Controller, events: []

    @impl true
    def init(_dependencies) do
      %{status: "waiting"}
    end

    @impl true
    def expose(_state, dependencies) do
      counter = Map.get(dependencies, :counter, %{count: 0})

      status =
        if counter.count >= 5 do
          "threshold_reached"
        else
          "below_threshold"
        end

      %{status: status}
    end
  end

  defmodule TestApp do
    use Bonseki.App

    scene do
      controller(:counter, Bonseki.UITest.CounterController)

      controller(:threshold, Bonseki.UITest.ThresholdController,
        dependencies: [:counter],
        on_when: fn deps ->
          rem(deps[:counter].count, 2) == 0
        end
      )
    end
  end

  defmodule DashboardLive do
    use Bonseki.UI, app: Bonseki.UITest.TestApp

    def init(_params) do
      %{
        counter: :counter,
        threshold: :threshold
      }
    end

    def render(assigns) do
      ~H"""
      <div>Count: {@counter.count}</div>
      """
    end
  end

  defmodule AdminLive do
    use Bonseki.UI, app: Bonseki.UITest.TestApp

    def init(_params) do
      %{
        counter: :counter,
        threshold: :threshold
      }
    end

    def render(assigns) do
      ~H"""
      <div>Count: {@counter.count}</div>
      """
    end
  end

  defmodule BrokenLive do
    use Bonseki.UI, app: Bonseki.UITest.TestApp

    def init(_params) do
      %{
        counter: :counter,
        nonexistent: :nonexistent
      }
    end

    def render(assigns) do
      ~H"""
      <div>Count: {@counter.count}</div>
      """
    end
  end

  describe "Multiple UI Instances with Isolated Apps" do
    test "same UI module can have multiple independent instances with incrementing IDs" do
      app_pids = for _i <- 1..5, do: Bonseki.UI.ensure_app_started(TestApp, DashboardLive)
      assert Enum.all?(app_pids, fn {:ok, pid} -> Process.alive?(pid) end)

      # Assert successful mounts for each instance
      for _i <- 1..5 do
        socket = %Phoenix.LiveView.Socket{}
        assert {:ok, mounted_socket} = DashboardLive.mount(%{}, %{}, socket)
        assert mounted_socket.assigns.counter.count == 0
        assert mounted_socket.assigns.threshold.status in ["below_threshold", "threshold_reached"]
      end
    end

    test "two UI instances have separate app instances with independent controllers" do
      # Assert successful mounts for both LiveView modules
      socket1 = %Phoenix.LiveView.Socket{}
      assert {:ok, mounted_socket1} = DashboardLive.mount(%{}, %{}, socket1)
      assert mounted_socket1.assigns.counter.count == 0

      socket2 = %Phoenix.LiveView.Socket{}
      assert {:ok, mounted_socket2} = AdminLive.mount(%{}, %{}, socket2)
      assert mounted_socket2.assigns.counter.count == 0

      {:ok, app1_pid} = Bonseki.UI.ensure_app_started(TestApp, DashboardLive)
      {:ok, app2_pid} = Bonseki.UI.ensure_app_started(TestApp, AdminLive)

      # Get controller PIDs from both apps
      counter1_pid = GenServer.call(app1_pid, {:fetch_controller_pid, :counter})
      threshold1_pid = GenServer.call(app1_pid, {:fetch_controller_pid, :threshold})

      counter2_pid = GenServer.call(app2_pid, {:fetch_controller_pid, :counter})
      threshold2_pid = GenServer.call(app2_pid, {:fetch_controller_pid, :threshold})

      # Controllers should be different between apps
      refute counter1_pid == counter2_pid
      refute threshold1_pid == threshold2_pid

      # Verify initial state in both apps
      assert GenServer.call(counter1_pid, :get_state) == %{count: 0}
      assert GenServer.call(counter2_pid, :get_state) == %{count: 0}

      # Verify threshold controller is running in both (count is 0, which is even)
      assert :sys.get_state(app1_pid).controllers[:threshold].status == :running
      assert :sys.get_state(app2_pid).controllers[:threshold].status == :running

      # Increment counter in first app
      :ok = GenServer.call(counter1_pid, {:event, :increment, %{}})

      # First app's threshold controller should now be stopped (count=1 is odd)
      assert :sys.get_state(app1_pid).controllers[:threshold].status == :stopped

      # Second app's threshold controller should still be running (count still 0)
      assert :sys.get_state(app2_pid).controllers[:threshold].status == :running

      # Verify counters are independent
      assert GenServer.call(counter1_pid, :get_state) == %{count: 1}
      assert GenServer.call(counter2_pid, :get_state) == %{count: 0}

      # Increment second app multiple times
      :ok = GenServer.call(counter2_pid, {:event, :increment, %{}})
      :ok = GenServer.call(counter2_pid, {:event, :increment, %{}})

      # Second app: count=2 (even), threshold should be running
      assert :sys.get_state(app2_pid).controllers[:threshold].status == :running
      assert GenServer.call(counter2_pid, :get_state) == %{count: 2}

      # First app should be unaffected
      assert GenServer.call(counter1_pid, :get_state) == %{count: 1}
      assert :sys.get_state(app1_pid).controllers[:threshold].status == :stopped
    end

    test "raises error when controller is not alive" do
      assert_raise RuntimeError, "Controller nonexistent is not alive", fn ->
        BrokenLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      end
    end
  end
end
