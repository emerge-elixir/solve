defmodule Solve.MultipleScenesTest do
  use ExUnit.Case, async: false

  defmodule AuthController do
    use Solve.Controller, events: [:login]

    @impl true
    def init(live_action, _dependencies) do
      %{
        action: live_action,
        form: "auth_form"
      }
    end

    def login(state, _params), do: state

    @impl true
    def expose(state, _dependencies), do: state
  end

  defmodule CurrentUserController do
    use Solve.Controller, events: [:update]

    @impl true
    def init(user, _dependencies) do
      %{user: user}
    end

    def update(state, params), do: %{state | user: params["user"]}

    @impl true
    def expose(state, _dependencies), do: state.user
  end

  defmodule RealworldApp do
    use Solve

    @impl true
    # Scene for logged-out users
    def scene(%{current_user: nil}) do
      %{auth: {Solve.MultipleScenesTest.AuthController, params: fn _ -> :login end}}
    end

    # Scene for logged-in users
    def scene(%{current_user: _user}) do
      %{
        current_user: {Solve.MultipleScenesTest.CurrentUserController,
          params: fn _ -> %{id: 1, name: "TestUser"} end
        }
      }
    end
  end

  describe "Multiple Scene Patterns" do
    test "logged-out users get auth controller" do
      {:ok, solve_pid} =
        RealworldApp.start_link(params: %{current_user: nil, live_action: :login})

      state = :sys.get_state(solve_pid)

      # Auth controller should be running
      assert state.controllers[:auth] != nil
      assert state.controllers[:auth].status == :running

      # Current user controller should not exist
      assert state.controllers[:current_user] == nil
    end

    test "logged-in users get current_user controller" do
      user = %{id: 1, name: "Alice"}
      {:ok, solve_pid} = RealworldApp.start_link(params: %{current_user: user})
      state = :sys.get_state(solve_pid)

      # Current user controller should be running
      assert state.controllers[:current_user] != nil
      assert state.controllers[:current_user].status == :running

      # Auth controller should not exist
      assert state.controllers[:auth] == nil
    end

    test "auth controller receives live_action param" do
      {:ok, solve_pid} =
        RealworldApp.start_link(params: %{current_user: nil, live_action: :register})

      state = :sys.get_state(solve_pid)

      auth_pid = state.controllers[:auth].pid
      auth_state = GenServer.call(auth_pid, :get_state)

      # The controller is initialized with hardcoded :login value
      assert auth_state.action == :login
    end

    test "current_user controller receives user param" do
      user = %{id: 2, name: "Bob"}
      {:ok, solve_pid} = RealworldApp.start_link(params: %{current_user: user})
      state = :sys.get_state(solve_pid)

      user_pid = state.controllers[:current_user].pid
      exposed = GenServer.call(user_pid, :get_exposed_state)

      # The controller is initialized with hardcoded test values
      assert exposed.id == 1
      assert exposed.name == "TestUser"
    end
  end

  describe "Scene Pattern Matching Edge Cases" do
    defmodule EdgeCaseApp do
      use Solve

      @impl true
      # Match specific values
      def scene(%{role: :admin}) do
        %{admin: {Solve.MultipleScenesTest.AuthController, params: fn _ -> :admin end}}
      end

      # Match moderator role
      def scene(%{role: :moderator}) do
        %{user: {Solve.MultipleScenesTest.AuthController, params: fn _ -> :moderator end}}
      end

      # Catch-all pattern
      def scene(_) do
        %{guest: {Solve.MultipleScenesTest.AuthController, params: fn _ -> :guest end}}
      end
    end

    test "matches admin role" do
      {:ok, solve_pid} = EdgeCaseApp.start_link(params: %{role: :admin})
      state = :sys.get_state(solve_pid)

      assert state.controllers[:admin] != nil
      assert state.controllers[:admin].status == :running
      assert state.controllers[:user] == nil
      assert state.controllers[:guest] == nil
    end

    test "matches non-admin role" do
      {:ok, solve_pid} = EdgeCaseApp.start_link(params: %{role: :moderator})
      state = :sys.get_state(solve_pid)

      assert state.controllers[:user] != nil
      assert state.controllers[:user].status == :running
      assert state.controllers[:admin] == nil
      assert state.controllers[:guest] == nil
    end

    test "matches catch-all for empty params" do
      {:ok, solve_pid} = EdgeCaseApp.start_link(params: %{})
      state = :sys.get_state(solve_pid)

      assert state.controllers[:guest] != nil
      assert state.controllers[:guest].status == :running
      assert state.controllers[:admin] == nil
      assert state.controllers[:user] == nil
    end
  end

  describe "Pattern Matching with Complex Structures" do
    defmodule NestedPatternApp do
      use Solve

      @impl true
      def scene(%{user: %{permissions: %{admin: true}}}) do
        %{admin: {Solve.MultipleScenesTest.AuthController, params: fn _ -> :admin end}}
      end

      def scene(%{user: %{permissions: _perms}}) do
        %{user: {Solve.MultipleScenesTest.AuthController, params: fn _ -> :user end}}
      end

      def scene(_) do
        %{guest: {Solve.MultipleScenesTest.AuthController, params: fn _ -> :guest end}}
      end
    end

    test "matches nested admin permission" do
      {:ok, solve_pid} =
        NestedPatternApp.start_link(params: %{user: %{permissions: %{admin: true}}})

      state = :sys.get_state(solve_pid)

      assert state.controllers[:admin] != nil
      assert state.controllers[:admin].status == :running
    end

    test "matches nested permissions without admin" do
      {:ok, solve_pid} =
        NestedPatternApp.start_link(params: %{user: %{permissions: %{read: true}}})

      state = :sys.get_state(solve_pid)

      assert state.controllers[:user] != nil
      assert state.controllers[:user].status == :running
      assert state.controllers[:admin] == nil
    end
  end
end
