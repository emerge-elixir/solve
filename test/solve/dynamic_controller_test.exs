defmodule Solve.DynamicControllerTest do
  use ExUnit.Case, async: false

  describe "Static params Conditions" do
    defmodule BaseController do
      use Solve.Controller, events: [:set_value]

      @impl true
      def init(_params, _dependencies) do
        %{value: 1}
      end

      def set_value(_state, %{value: new_value}) do
        %{value: new_value}
      end

      @impl true
      def expose(state, _dependencies) do
        state
      end
    end

    defmodule AlwaysOnController do
      use Solve.Controller

      @impl true
      def init(_params, _dependencies) do
        %{status: "always_on"}
      end

      @impl true
      def expose(state, _dependencies) do
        state
      end
    end

    defmodule AlwaysOffController do
      use Solve.Controller

      @impl true
      def init(_params, _dependencies) do
        %{status: "always_off"}
      end

      @impl true
      def expose(state, _dependencies) do
        state
      end
    end

    defmodule StaticOnWhenSolve do
      use Solve

      @impl true
      def scene(_params) do
        %{
          # Base controller - always on (no params specified, defaults to true)
          base: Solve.DynamicControllerTest.BaseController,
          # Dependent controller with params: true - should start
          always_on: {Solve.DynamicControllerTest.AlwaysOnController,
            dependencies: [:base],
            params: fn _ -> true end
          },
          # Dependent controller with params: false - should NOT start
          always_off: {Solve.DynamicControllerTest.AlwaysOffController,
            dependencies: [:base],
            params: fn _ -> false end
          }
        }
      end
    end

    test "controllers with params: false should not start" do
      {:ok, solve_pid} = StaticOnWhenSolve.start_link()
      state = :sys.get_state(solve_pid)

      assert state.controllers[:base]
      assert state.controllers[:base].status == :running
      assert Process.alive?(state.controllers[:base].pid)

      assert state.controllers[:always_on]
      assert state.controllers[:always_on].status == :running
      assert Process.alive?(state.controllers[:always_on].pid)

      assert state.controllers[:always_off]
      assert state.controllers[:always_off].status == :stopped
      refute state.controllers[:always_off].pid
    end
  end

  describe "Dynamic params Conditions" do
    defmodule DynamicBaseController do
      use Solve.Controller, events: [:increment, :decrement]

      @impl true
      def init(_params, _dependencies) do
        %{value: 1}
      end

      def increment(state, _params) do
        %{value: state.value + 1}
      end

      def decrement(state, _params) do
        %{value: state.value - 1}
      end

      @impl true
      def expose(state, _dependencies) do
        state
      end
    end

    defmodule ConditionalController do
      use Solve.Controller

      @impl true
      def init(_params, _dependencies) do
        %{status: "conditional"}
      end

      @impl true
      def expose(state, _dependencies) do
        state
      end
    end

    # Solve with dynamic params condition
    defmodule DynamicOnWhenSolve do
      use Solve

      @impl true
      def scene(_params) do
        %{
          # Base controller - always on
          dynamic_base: Solve.DynamicControllerTest.DynamicBaseController,
          # Always on dependent
          static_dependent: {Solve.DynamicControllerTest.AlwaysOnController,
            dependencies: [:dynamic_base],
            params: fn _ -> true end
          },
          # Conditionally on - only when base controller's value is even
          conditional: {Solve.DynamicControllerTest.ConditionalController,
            dependencies: [:dynamic_base],
            params: fn dependencies ->
              base_state = Map.get(dependencies, :dynamic_base, %{value: 0})
              if rem(base_state.value, 2) == 0 do
                true
              else
                nil
              end
            end
          }
        }
      end
    end

    test "controller starts when dynamic condition becomes true" do
      {:ok, solve_pid} = DynamicOnWhenSolve.start_link()

      state = :sys.get_state(solve_pid)

      assert state.controllers[:dynamic_base]
      assert state.controllers[:dynamic_base].status == :running
      assert Process.alive?(state.controllers[:dynamic_base].pid)

      assert state.controllers[:static_dependent]
      assert state.controllers[:static_dependent].status == :running

      assert state.controllers[:conditional]
      assert state.controllers[:conditional].status == :stopped
      refute state.controllers[:conditional].pid

      GenServer.call(state.controllers[:dynamic_base].pid, {:event, :increment, %{}})

      state = :sys.get_state(solve_pid)

      assert state.controllers[:conditional]
      assert state.controllers[:conditional].status == :running
      assert Process.alive?(state.controllers[:conditional].pid)

      assert Enum.all?(state.controllers, fn {_name, info} ->
               info.status == :running
             end)

      GenServer.call(state.controllers[:dynamic_base].pid, {:event, :decrement, %{}})

      state = :sys.get_state(solve_pid)

      assert state.controllers[:conditional]
      assert state.controllers[:conditional].status == :stopped
      refute state.controllers[:conditional].pid
    end
  end
end
