defmodule Solve.LiveViewTest do
  use ExUnit.Case, async: false

  defmodule CounterController do
    use Solve.Controller, events: [:increment, :reset]

    @impl true
    def init(_params, _dependencies) do
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
    use Solve.Controller, events: [:check]

    @impl true
    def init(_params, _dependencies) do
      %{status: "waiting"}
    end

    def check(state, _params) do
      state
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

  defmodule TestSolve do
    use Solve

    @impl true
    def scene(_params) do
      %{
        counter: Solve.LiveViewTest.CounterController,
        threshold:
          {Solve.LiveViewTest.ThresholdController,
           dependencies: [:counter],
           params: fn deps ->
             if rem(deps[:counter].count, 2) == 0 do
               true
             else
               nil
             end
           end}
      }
    end
  end

  defmodule DashboardLive do
    use Solve.LiveView, scene: Solve.LiveViewTest.TestSolve

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
    use Solve.LiveView, scene: Solve.LiveViewTest.TestSolve

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
    use Solve.LiveView, scene: Solve.LiveViewTest.TestSolve

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

  defmodule ControllersListLive do
    use Solve.LiveView, scene: Solve.LiveViewTest.TestSolve

    @controllers [:counter, :threshold]

    def render(assigns) do
      ~H"""
      <div>Count: {@counter.count}</div>
      """
    end
  end

  defmodule ControllersKeywordLive do
    use Solve.LiveView, scene: Solve.LiveViewTest.TestSolve

    @controllers [my_counter: :counter, my_threshold: :threshold]

    def render(assigns) do
      ~H"""
      <div>Count: {@my_counter.count}</div>
      """
    end
  end

  defmodule MixedControllersLive do
    use Solve.LiveView, scene: Solve.LiveViewTest.TestSolve

    @controllers [:counter]

    # init takes precedence when non-empty
    def init(params) do
      if params[:use_init] do
        %{counter: :counter, threshold: :threshold}
      else
        %{}
      end
    end

    def render(assigns) do
      ~H"""
      <div>Count: {@counter.count}</div>
      """
    end
  end

  defmodule PartialSubscriptionLive do
    use Solve.LiveView, scene: Solve.LiveViewTest.TestSolve

    # Only subscribe to counter, not threshold
    @controllers [:counter]

    def render(assigns) do
      ~H"""
      <div>Count: {@counter.count}</div>
      """
    end
  end

  describe "Multiple LiveView Instances with Isolated Solves" do
    test "same LiveView module can have multiple independent instances with incrementing IDs" do
      solve_pids =
        for _i <- 1..5,
            do: Solve.LiveView.ensure_solve_started(TestSolve, DashboardLive, %{})

      assert Enum.all?(solve_pids, fn {:ok, pid} -> Process.alive?(pid) end)

      # Assert successful mounts for each instance
      for _i <- 1..5 do
        socket = %Phoenix.LiveView.Socket{}
        assert {:ok, mounted_socket} = DashboardLive.mount(%{}, %{}, socket)
        assert mounted_socket.assigns.counter.exposed.count == 0
        # threshold could be nil if not started (params condition)
        if mounted_socket.assigns.threshold do
          assert mounted_socket.assigns.threshold.exposed.status in [
                   "below_threshold",
                   "threshold_reached"
                 ]
        end
      end
    end

    test "two LiveView instances have separate Solve instances with independent controllers" do
      # Assert successful mounts for both LiveView modules
      socket1 = %Phoenix.LiveView.Socket{}
      assert {:ok, mounted_socket1} = DashboardLive.mount(%{}, %{}, socket1)
      assert mounted_socket1.assigns.counter.exposed.count == 0

      socket2 = %Phoenix.LiveView.Socket{}
      assert {:ok, mounted_socket2} = AdminLive.mount(%{}, %{}, socket2)
      assert mounted_socket2.assigns.counter.exposed.count == 0

      {:ok, solve1_pid} = Solve.LiveView.ensure_solve_started(TestSolve, DashboardLive, %{})
      {:ok, solve2_pid} = Solve.LiveView.ensure_solve_started(TestSolve, AdminLive, %{})

      # Get controller PIDs from both Solves
      counter1_pid = GenServer.call(solve1_pid, {:fetch_controller_pid, :counter})
      threshold1_pid = GenServer.call(solve1_pid, {:fetch_controller_pid, :threshold})

      counter2_pid = GenServer.call(solve2_pid, {:fetch_controller_pid, :counter})
      threshold2_pid = GenServer.call(solve2_pid, {:fetch_controller_pid, :threshold})

      # Controllers should be different between Solves
      refute counter1_pid == counter2_pid
      refute threshold1_pid == threshold2_pid

      # Verify initial state in both Solves
      assert GenServer.call(counter1_pid, :get_state) == %{count: 0}
      assert GenServer.call(counter2_pid, :get_state) == %{count: 0}

      # Verify threshold controller is running in both (count is 0, which is even)
      assert :sys.get_state(solve1_pid).controllers[:threshold].status == :running
      assert :sys.get_state(solve2_pid).controllers[:threshold].status == :running

      # Increment counter in first Solve
      %{count: 1} = GenServer.call(counter1_pid, {:event, :increment, %{}})

      # First Solve's threshold controller should now be stopped (count=1 is odd)
      assert :sys.get_state(solve1_pid).controllers[:threshold].status == :stopped

      # Second Solve's threshold controller should still be running (count still 0)
      assert :sys.get_state(solve2_pid).controllers[:threshold].status == :running

      # Verify counters are independent
      assert GenServer.call(counter1_pid, :get_state) == %{count: 1}
      assert GenServer.call(counter2_pid, :get_state) == %{count: 0}

      # Increment second Solve multiple times
      GenServer.call(counter2_pid, {:event, :increment, %{}})
      GenServer.call(counter2_pid, {:event, :increment, %{}})

      # Second Solve: count=2 (even), threshold should be running
      assert :sys.get_state(solve2_pid).controllers[:threshold].status == :running
      assert GenServer.call(counter2_pid, :get_state) == %{count: 2}

      # First Solve should be unaffected
      assert GenServer.call(counter1_pid, :get_state) == %{count: 1}
      assert :sys.get_state(solve1_pid).controllers[:threshold].status == :stopped
    end

    test "assigns nil when controller is not alive" do
      socket = %Phoenix.LiveView.Socket{}
      {:ok, mounted_socket} = BrokenLive.mount(%{}, %{}, socket)

      # counter controller exists and should be accessible
      assert mounted_socket.assigns.counter.exposed.count == 0

      # nonexistent controller should be nil
      assert mounted_socket.assigns.nonexistent == nil
    end
  end

  describe "@controllers attribute" do
    test "simple list format subscribes to controllers with same assign names" do
      socket = %Phoenix.LiveView.Socket{}
      {:ok, mounted_socket} = ControllersListLive.mount(%{}, %{}, socket)

      # counter controller should be accessible
      assert mounted_socket.assigns.counter.exposed.count == 0

      # threshold controller may or may not be alive based on params
      if mounted_socket.assigns.threshold do
        assert mounted_socket.assigns.threshold.exposed.status in [
                 "below_threshold",
                 "threshold_reached"
               ]
      end
    end

    test "keyword list format maps assign names to controller names" do
      socket = %Phoenix.LiveView.Socket{}
      {:ok, mounted_socket} = ControllersKeywordLive.mount(%{}, %{}, socket)

      # controller should be accessible via custom assign name
      assert mounted_socket.assigns.my_counter.exposed.count == 0

      # threshold controller may or may not be alive
      if mounted_socket.assigns.my_threshold do
        assert mounted_socket.assigns.my_threshold.exposed.status in [
                 "below_threshold",
                 "threshold_reached"
               ]
      end

      # Original names should not exist
      refute Map.has_key?(mounted_socket.assigns, :counter)
      refute Map.has_key?(mounted_socket.assigns, :threshold)
    end

    test "init/1 takes precedence over @controllers when it returns non-empty map" do
      # When init returns empty map (default), @controllers is used
      socket1 = %Phoenix.LiveView.Socket{}
      {:ok, mounted_socket1} = MixedControllersLive.mount(%{}, %{}, socket1)
      assert mounted_socket1.assigns.counter.exposed.count == 0

      # When init returns non-empty map, it takes precedence
      socket2 = %Phoenix.LiveView.Socket{}
      {:ok, mounted_socket2} = MixedControllersLive.mount(%{use_init: true}, %{}, socket2)
      assert mounted_socket2.assigns.counter.exposed.count == 0

      # threshold is added via init
      if mounted_socket2.assigns.threshold do
        assert mounted_socket2.assigns.threshold.exposed.status in [
                 "below_threshold",
                 "threshold_reached"
               ]
      end
    end

    test "LiveView ignores events for controllers it's not subscribed to" do
      # Mount a LiveView that only subscribes to counter, not threshold
      socket = %Phoenix.LiveView.Socket{}
      {:ok, mounted_socket} = PartialSubscriptionLive.mount(%{}, %{}, socket)

      # Verify it's subscribed to counter but not threshold
      assert mounted_socket.assigns.counter != nil
      assert mounted_socket.assigns[:threshold] == nil

      # Simulate receiving an event for threshold controller
      # This could happen when a LiveComponent is subscribed to threshold but the parent isn't
      {:noreply, result_socket} =
        PartialSubscriptionLive.handle_event("solve:threshold:check", %{}, mounted_socket)

      # Should not crash, just ignore the event
      assert result_socket == mounted_socket
    end
  end
end
