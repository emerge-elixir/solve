defmodule Solve.AfterActionTest do
  use ExUnit.Case, async: false

  # Controller that exposes different statuses
  defmodule StatusController do
    use Solve.Controller, events: [:set_success, :set_error, :set_pending]

    @impl true
    def init(_params, _dependencies) do
      %{
        status: :pending,
        message: nil,
        path: nil
      }
    end

    def set_success(state, params) do
      %{
        state
        | status: :success,
          message: "Operation successful",
          path: params["path"] || "/dashboard"
      }
    end

    def set_error(state, params) do
      %{state | status: :error, message: params["message"] || "An error occurred"}
    end

    def set_pending(state, _params) do
      %{state | status: :pending, message: nil, path: nil}
    end

    @impl true
    def expose(state, _dependencies) do
      state
    end
  end

  # Scene with after_action
  defmodule TestSolve do
    use Solve

    @impl true
    def scene(%{after_action: after_action}) do
      %{
        status: {Solve.AfterActionTest.StatusController, after_action: after_action}
      }
    end

    def scene(_params) do
      %{
        status: Solve.AfterActionTest.StatusController
      }
    end
  end

  # LiveView for testing
  defmodule TestLive do
    use Solve.LiveView, scene: Solve.AfterActionTest.TestSolve

    def mount_to_solve(_params, _session, _socket) do
      %{
        after_action: fn socket, state ->
          case state.status do
            :success ->
              socket
              |> Phoenix.Component.assign(:redirected, true)
              |> Phoenix.Component.assign(:redirect_path, state.path)

            :error ->
              Phoenix.Component.assign(socket, :flash_error, state.message)

            _ ->
              socket
          end
        end
      }
    end

    def init(_params) do
      %{status: :status}
    end

    def render(assigns) do
      ~H"""
      <div>Status: {@status.status}</div>
      """
    end
  end

  test "after_action is called on controller state updates" do
    socket = %Phoenix.LiveView.Socket{}
    {:ok, mounted_socket} = TestLive.mount(%{}, %{}, socket)

    # Initial state should be pending
    assert mounted_socket.assigns.status.exposed.status == :pending
    refute Map.has_key?(mounted_socket.assigns, :redirected)
    refute Map.has_key?(mounted_socket.assigns, :flash_error)

    # Get controller PID
    controller_pid = mounted_socket.assigns.status.pid

    # Trigger success event
    GenServer.cast(controller_pid, {:event, :set_success, %{"path" => "/home"}})

    # Simulate receiving the update
    {:noreply, updated_socket} =
      TestLive.handle_info(
        {:solve_update, :status, :status,
         %{status: :success, message: "Operation successful", path: "/home"}},
        mounted_socket
      )

    # Verify after_action was applied
    assert updated_socket.assigns.redirected == true
    assert updated_socket.assigns.redirect_path == "/home"
    assert updated_socket.assigns.status.exposed.status == :success
  end

  test "after_action handles error state" do
    socket = %Phoenix.LiveView.Socket{}
    {:ok, mounted_socket} = TestLive.mount(%{}, %{}, socket)

    # Get controller PID
    controller_pid = mounted_socket.assigns.status.pid

    # Trigger error event
    GenServer.cast(controller_pid, {:event, :set_error, %{"message" => "Something went wrong"}})

    # Simulate receiving the update
    {:noreply, updated_socket} =
      TestLive.handle_info(
        {:solve_update, :status, :status,
         %{status: :error, message: "Something went wrong", path: nil}},
        mounted_socket
      )

    # Verify after_action was applied
    assert updated_socket.assigns.flash_error == "Something went wrong"
    assert updated_socket.assigns.status.exposed.status == :error
  end

  test "after_action does nothing for pending state" do
    socket = %Phoenix.LiveView.Socket{}
    {:ok, mounted_socket} = TestLive.mount(%{}, %{}, socket)

    # Get controller PID
    controller_pid = mounted_socket.assigns.status.pid

    # Change to success first
    GenServer.cast(controller_pid, {:event, :set_success, %{"path" => "/home"}})

    {:noreply, success_socket} =
      TestLive.handle_info(
        {:solve_update, :status, :status,
         %{status: :success, message: "Operation successful", path: "/home"}},
        mounted_socket
      )

    assert success_socket.assigns.redirected == true

    # Now change back to pending
    GenServer.cast(controller_pid, {:event, :set_pending, %{}})

    {:noreply, pending_socket} =
      TestLive.handle_info(
        {:solve_update, :status, :status, %{status: :pending, message: nil, path: nil}},
        success_socket
      )

    # Previous assigns should remain (after_action returns socket unchanged)
    assert pending_socket.assigns.redirected == true
    assert pending_socket.assigns.status.exposed.status == :pending
  end

  test "default after_action returns socket unchanged" do
    # Scene without custom after_action
    defmodule DefaultSolve do
      use Solve

      @impl true
      def scene(_params) do
        %{
          status: Solve.AfterActionTest.StatusController
        }
      end
    end

    defmodule DefaultLive do
      use Solve.LiveView, scene: Solve.AfterActionTest.DefaultSolve

      def init(_params) do
        %{status: :status}
      end

      def render(assigns) do
        ~H"""
        <div>Status: {@status.status}</div>
        """
      end
    end

    socket = %Phoenix.LiveView.Socket{}
    {:ok, mounted_socket} = DefaultLive.mount(%{}, %{}, socket)

    # Get controller PID
    controller_pid = mounted_socket.assigns.status.pid

    # Trigger success event
    GenServer.cast(controller_pid, {:event, :set_success, %{"path" => "/home"}})

    # Simulate receiving the update
    {:noreply, updated_socket} =
      DefaultLive.handle_info(
        {:solve_update, :status, :status,
         %{status: :success, message: "Operation successful", path: "/home"}},
        mounted_socket
      )

    # Verify state is updated but no custom actions were applied
    assert updated_socket.assigns.status.exposed.status == :success
    refute Map.has_key?(updated_socket.assigns, :redirected)
    refute Map.has_key?(updated_socket.assigns, :flash_error)
  end

  test "after_action is stored in Solve state, not socket assigns" do
    socket = %Phoenix.LiveView.Socket{}
    {:ok, mounted_socket} = TestLive.mount(%{}, %{}, socket)

    # Verify after_action is NOT stored in socket assigns
    refute Map.has_key?(mounted_socket.assigns, :__after_action_status__)

    # Verify after_action is stored in Solve's state
    solve_pid = mounted_socket.assigns.__solve_pid__
    solve_state = :sys.get_state(solve_pid)
    status_controller_info = solve_state.controllers[:status]

    assert status_controller_info.after_action != nil
    assert is_function(status_controller_info.after_action, 2)
  end

  test "after_action works with LiveComponent" do
    defmodule TestComponent do
      use Solve.LiveComponent

      def init(_params) do
        %{status: :status}
      end

      def render(assigns) do
        ~H"""
        <div>Status: {@status.status}</div>
        """
      end
    end

    # Start Solve manually
    {:ok, solve_pid} =
      TestSolve.start_link(
        params: %{
          after_action: fn socket, state ->
            case state.status do
              :success ->
                Phoenix.Component.assign(socket, :component_redirected, true)

              _ ->
                socket
            end
          end
        }
      )

    # Create a socket and mount the component
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:__solve_pid__, solve_pid)

    {:ok, mounted_socket} =
      TestComponent.update(%{id: "test-1", __solve_pid__: solve_pid}, socket)

    # Get controller PID
    controller_pid = mounted_socket.assigns.status.pid

    # Trigger success event
    GenServer.cast(controller_pid, {:event, :set_success, %{"path" => "/home"}})

    # Simulate receiving the update
    {:noreply, updated_socket} =
      TestComponent.handle_info(
        {:solve_update, :status, :status,
         %{status: :success, message: "Operation successful", path: "/home"}},
        mounted_socket
      )

    # Verify after_action was applied in component
    assert updated_socket.assigns.component_redirected == true
  end
end
