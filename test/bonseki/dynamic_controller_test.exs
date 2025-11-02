defmodule Bonseki.DynamicControllerTest do
  use ExUnit.Case, async: false

  describe "Static on_when Conditions" do
    defmodule BaseController do
      use Bonseki.Controller, events: [:set_value]

      def init(_dependencies) do
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
      use Bonseki.Controller

      @impl true
      def init(_dependencies) do
        %{status: "always_on"}
      end

      @impl true
      def expose(state, _dependencies) do
        state
      end
    end

    defmodule AlwaysOffController do
      use Bonseki.Controller

      @impl true
      def init(_dependencies) do
        %{status: "always_off"}
      end

      @impl true
      def expose(state, _dependencies) do
        state
      end
    end

    defmodule StaticOnWhenApp do
      use Bonseki.App

      scene do
        # Base controller - always on (no on_when specified, defaults to true)
        controller(:base, Bonseki.DynamicControllerTest.BaseController)

        # Dependent controller with on_when: true - should start
        controller(:always_on, Bonseki.DynamicControllerTest.AlwaysOnController,
          dependencies: [:base],
          on_when: true
        )

        # Dependent controller with on_when: false - should NOT start
        controller(:always_off, Bonseki.DynamicControllerTest.AlwaysOffController,
          dependencies: [:base],
          on_when: false
        )
      end
    end

    test "controllers with on_when: false should not start" do
      {:ok, app_pid} = StaticOnWhenApp.start_link()
      state = :sys.get_state(app_pid)

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

  describe "Dynamic on_when Conditions" do
    defmodule DynamicBaseController do
      use Bonseki.Controller, events: [:increment, :decrement]

      def init(_dependencies) do
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
      use Bonseki.Controller

      @impl true
      def init(_dependencies) do
        %{status: "conditional"}
      end

      @impl true
      def expose(state, _dependencies) do
        state
      end
    end

    # App with dynamic on_when condition
    defmodule DynamicOnWhenApp do
      use Bonseki.App

      scene do
        # Base controller - always on
        controller(:dynamic_base, Bonseki.DynamicControllerTest.DynamicBaseController)

        # Always on dependent
        controller(:static_dependent, Bonseki.DynamicControllerTest.AlwaysOnController,
          dependencies: [:dynamic_base],
          on_when: true
        )

        # Conditionally on - only when base controller's value is even
        controller(:conditional, Bonseki.DynamicControllerTest.ConditionalController,
          dependencies: [:dynamic_base],
          on_when: fn dependencies ->
            base_state = Map.get(dependencies, :dynamic_base, %{value: 0})
            rem(base_state.value, 2) == 0
          end
        )
      end
    end

    test "controller starts when dynamic condition becomes true" do
      {:ok, app_pid} = DynamicOnWhenApp.start_link()

      state = :sys.get_state(app_pid)

      assert state.controllers[:dynamic_base]
      assert state.controllers[:dynamic_base].status == :running
      assert Process.alive?(state.controllers[:dynamic_base].pid)

      assert state.controllers[:static_dependent]
      assert state.controllers[:static_dependent].status == :running

      assert state.controllers[:conditional]
      assert state.controllers[:conditional].status == :stopped
      refute state.controllers[:conditional].pid

      :ok = GenServer.call(state.controllers[:dynamic_base].pid, {:event, :increment, %{}})

      state = :sys.get_state(app_pid)

      assert state.controllers[:conditional]
      assert state.controllers[:conditional].status == :running
      assert Process.alive?(state.controllers[:conditional].pid)

      assert Enum.all?(state.controllers, fn {_name, info} ->
               info.status == :running
             end)

      :ok = GenServer.call(state.controllers[:dynamic_base].pid, {:event, :decrement, %{}})

      state = :sys.get_state(app_pid)

      assert state.controllers[:conditional]
      assert state.controllers[:conditional].status == :stopped
      refute state.controllers[:conditional].pid
    end
  end
end
