defmodule Solve.LiveComponentTest do
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

  defmodule TestSolve do
    use Solve

    @impl true
    def scene(_params) do
      %{counter: Solve.LiveComponentTest.CounterController}
    end
  end

  defmodule CounterComponent do
    use Solve.LiveComponent

    def init(_params) do
      # params includes :id and any other assigns
      %{counter: :counter}
    end

    def render(assigns) do
      ~H"""
      <div id={@id}>
        Count: {@counter.count}
        <button phx-click={@counter.increment} phx-target={@myself}>+</button>
      </div>
      """
    end
  end

  defmodule ControllersListComponent do
    use Solve.LiveComponent

    @controllers [:counter]

    def render(assigns) do
      ~H"""
      <div id={@id}>
        Count: {@counter.count}
      </div>
      """
    end
  end

  defmodule ControllersKeywordComponent do
    use Solve.LiveComponent

    @controllers [my_counter: :counter]

    def render(assigns) do
      ~H"""
      <div id={@id}>
        Count: {@my_counter.count}
      </div>
      """
    end
  end

  defmodule MixedComponent do
    use Solve.LiveComponent

    @controllers [:counter]

    # init takes precedence when non-empty
    def init(assigns) do
      if assigns[:use_custom] do
        %{custom_counter: :counter}
      else
        %{}
      end
    end

    def render(assigns) do
      ~H"""
      <div id={@id}>
        <%= if assigns[:counter] do %>
          Count: {@counter.count}
        <% end %>
        <%= if assigns[:custom_counter] do %>
          Custom Count: {@custom_counter.count}
        <% end %>
      </div>
      """
    end
  end

  defmodule ParentLive do
    use Solve.LiveView, scene: Solve.LiveComponentTest.TestSolve

    def init(_params) do
      %{}
    end

    def render(assigns) do
      ~H"""
      <div>
        <.live_component module={Solve.LiveComponentTest.CounterComponent} id="counter-1" />
        <.live_component module={Solve.LiveComponentTest.CounterComponent} id="counter-2" />
      </div>
      """
    end
  end

  describe "Solve.LiveComponent" do
    test "component can subscribe to controllers from parent Solve" do
      # Mount parent LiveView
      socket = %Phoenix.LiveView.Socket{}
      {:ok, parent_socket} = ParentLive.mount(%{}, %{}, socket)

      # Verify Solve PID is stored in socket
      assert parent_socket.assigns.__solve_pid__ != nil
      solve_pid = parent_socket.assigns.__solve_pid__

      # Get counter controller PID
      counter_pid = GenServer.call(solve_pid, {:fetch_controller_pid, :counter})
      assert counter_pid != nil

      # Simulate component mount with proper socket initialization
      component_socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}}
      }

      # Component update (first time, subscribes)
      assigns = %{id: "counter-1", __solve_pid__: solve_pid}
      {:ok, component_socket} = CounterComponent.update(assigns, component_socket)

      # Verify component subscribed to counter
      assert component_socket.assigns.counter != nil
      assert component_socket.assigns.counter.exposed.count == 0
      assert component_socket.assigns.__solve_subscribed__ == true
    end

    test "multiple component instances share the same controller state" do
      # Mount parent LiveView
      socket = %Phoenix.LiveView.Socket{}
      {:ok, parent_socket} = ParentLive.mount(%{}, %{}, socket)
      solve_pid = parent_socket.assigns.__solve_pid__

      # Mount first component
      component1_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assigns1 = %{id: "counter-1", __solve_pid__: solve_pid}
      {:ok, component1_socket} = CounterComponent.update(assigns1, component1_socket)

      # Mount second component
      component2_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assigns2 = %{id: "counter-2", __solve_pid__: solve_pid}
      {:ok, component2_socket} = CounterComponent.update(assigns2, component2_socket)

      # Both should have same controller PID
      assert component1_socket.assigns.counter.pid == component2_socket.assigns.counter.pid

      # Both should see same initial state
      assert component1_socket.assigns.counter.exposed.count == 0
      assert component2_socket.assigns.counter.exposed.count == 0

      # Increment via first component
      controller_pid = component1_socket.assigns.counter.pid
      GenServer.call(controller_pid, {:event, :increment, %{}})

      # Simulate state update to both components
      new_state = GenServer.call(controller_pid, :get_exposed_state)

      {:noreply, updated_component1} =
        CounterComponent.handle_info(
          {:solve_update, :counter, :counter, new_state},
          component1_socket
        )

      {:noreply, updated_component2} =
        CounterComponent.handle_info(
          {:solve_update, :counter, :counter, new_state},
          component2_socket
        )

      # Both should now see count = 1
      assert updated_component1.assigns.counter.exposed.count == 1
      assert updated_component2.assigns.counter.exposed.count == 1
    end

    test "component handles events correctly" do
      # Mount parent LiveView
      socket = %Phoenix.LiveView.Socket{}
      {:ok, parent_socket} = ParentLive.mount(%{}, %{}, socket)
      solve_pid = parent_socket.assigns.__solve_pid__

      # Mount component
      component_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assigns = %{id: "counter-1", __solve_pid__: solve_pid}
      {:ok, component_socket} = CounterComponent.update(assigns, component_socket)

      # Handle increment event
      {:noreply, component_socket} =
        CounterComponent.handle_event("solve:counter:increment", %{}, component_socket)

      # Verify the event was sent to controller
      controller_pid = component_socket.assigns.counter.pid
      :timer.sleep(10)  # Give time for cast to process

      # Get updated state
      state = GenServer.call(controller_pid, :get_state)
      assert state.count == 1
    end

    test "component raises error if parent is not Solve.LiveView" do
      # Try to mount component without __solve_pid__ in assigns
      component_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assigns = %{id: "counter-1"}

      assert_raise RuntimeError,
                   "Solve.LiveComponent requires parent LiveView to use Solve.LiveView",
                   fn ->
                     CounterComponent.update(assigns, component_socket)
                   end
    end

    test "init receives all params including id" do
      defmodule ParamsTestComponent do
        use Solve.LiveComponent

        def init(params) do
          # Store params in socket for testing
          send(self(), {:init_params, params})
          %{}
        end

        def render(assigns) do
          ~H"""
          <div>{@id}</div>
          """
        end
      end

      # Mount parent LiveView
      socket = %Phoenix.LiveView.Socket{}
      {:ok, parent_socket} = ParentLive.mount(%{}, %{}, socket)
      solve_pid = parent_socket.assigns.__solve_pid__

      # Mount component with extra params
      component_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assigns = %{id: "test-1", custom_param: "value", __solve_pid__: solve_pid}
      {:ok, _component_socket} = ParamsTestComponent.update(assigns, component_socket)

      # Verify init received all params
      assert_receive {:init_params, params}
      assert params.id == "test-1"
      assert params.custom_param == "value"
      assert params.__solve_pid__ == solve_pid
    end
  end

  describe "@controllers attribute in LiveComponent" do
    test "simple list format subscribes to controllers with same assign names" do
      # Mount parent LiveView
      socket = %Phoenix.LiveView.Socket{}
      {:ok, parent_socket} = ParentLive.mount(%{}, %{}, socket)
      solve_pid = parent_socket.assigns.__solve_pid__

      # Mount component with @controllers list
      component_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assigns = %{id: "counter-1", __solve_pid__: solve_pid}
      {:ok, component_socket} = ControllersListComponent.update(assigns, component_socket)

      # Verify component subscribed to counter
      assert component_socket.assigns.counter.exposed.count == 0
      assert component_socket.assigns.__solve_subscribed__ == true
    end

    test "keyword list format maps assign names to controller names" do
      # Mount parent LiveView
      socket = %Phoenix.LiveView.Socket{}
      {:ok, parent_socket} = ParentLive.mount(%{}, %{}, socket)
      solve_pid = parent_socket.assigns.__solve_pid__

      # Mount component with @controllers keyword list
      component_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assigns = %{id: "counter-1", __solve_pid__: solve_pid}
      {:ok, component_socket} = ControllersKeywordComponent.update(assigns, component_socket)

      # Verify component subscribed via custom assign name
      assert component_socket.assigns.my_counter.exposed.count == 0

      # Original name should not exist
      refute Map.has_key?(component_socket.assigns, :counter)
    end

    test "init/1 takes precedence over @controllers when it returns non-empty map" do
      # Mount parent LiveView
      socket = %Phoenix.LiveView.Socket{}
      {:ok, parent_socket} = ParentLive.mount(%{}, %{}, socket)
      solve_pid = parent_socket.assigns.__solve_pid__

      # When init returns empty map (default), @controllers is used
      component1_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assigns1 = %{id: "counter-1", __solve_pid__: solve_pid}
      {:ok, component1_socket} = MixedComponent.update(assigns1, component1_socket)

      assert component1_socket.assigns.counter.exposed.count == 0
      refute Map.has_key?(component1_socket.assigns, :custom_counter)

      # When init returns non-empty map, it takes precedence
      component2_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assigns2 = %{id: "counter-2", use_custom: true, __solve_pid__: solve_pid}
      {:ok, component2_socket} = MixedComponent.update(assigns2, component2_socket)

      assert component2_socket.assigns.custom_counter.exposed.count == 0
      refute Map.has_key?(component2_socket.assigns, :counter)
    end

    test "LiveComponent ignores events for controllers it's not subscribed to" do
      # Need a scene with multiple controllers for this test
      defmodule MultiControllerSolve do
        use Solve

        @impl true
        def scene(_params) do
          %{
            counter: Solve.LiveComponentTest.CounterController,
            counter2: Solve.LiveComponentTest.CounterController
          }
        end
      end

      defmodule MultiParentLive do
        use Solve.LiveView, scene: MultiControllerSolve

        @controllers []

        def render(assigns) do
          ~H"""
          <div>Test</div>
          """
        end
      end

      defmodule PartialComponent do
        use Solve.LiveComponent

        # Only subscribe to counter, not counter2
        @controllers [:counter]

        def render(assigns) do
          ~H"""
          <div>{@counter.count}</div>
          """
        end
      end

      # Mount parent LiveView
      socket = %Phoenix.LiveView.Socket{}
      {:ok, parent_socket} = MultiParentLive.mount(%{}, %{}, socket)
      solve_pid = parent_socket.assigns.__solve_pid__

      # Mount component that subscribes to counter but not counter2
      component_socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assigns = %{id: "partial-1", __solve_pid__: solve_pid}
      {:ok, component_socket} = PartialComponent.update(assigns, component_socket)

      # Verify subscribed to counter but not counter2
      assert component_socket.assigns.counter != nil
      assert component_socket.assigns[:counter2] == nil

      # Simulate receiving an event for counter2 (which component isn't subscribed to)
      {:noreply, result_socket} =
        PartialComponent.handle_event("solve:counter2:increment", %{}, component_socket)

      # Should not crash, just ignore the event
      assert result_socket == component_socket
    end
  end
end
