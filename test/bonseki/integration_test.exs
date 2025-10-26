defmodule Bonseki.IntegrationTest do
  use ExUnit.Case, async: false

  # Test Controllers
  defmodule LemonController do
    use Bonseki.Controller, events: [:add, :remove]

    def init(_params) do
      %{count: 0}
    end

    def add(state, _params) do
      %{state | count: state.count + 1}
    end

    def remove(state, _params) do
      %{state | count: max(0, state.count - 1)}
    end

    def expose(state, _dependencies) do
      %{count: state.count, has_lemons: state.count > 0}
    end
  end

  defmodule WaterController do
    use Bonseki.Controller, events: [:add, :remove]

    def init(_params) do
      %{count: 0}
    end

    def add(state, _params) do
      %{state | count: state.count + 1}
    end

    def remove(state, _params) do
      %{state | count: max(0, state.count - 1)}
    end

    def expose(state, _dependencies) do
      %{count: state.count}
    end
  end

  defmodule SugarController do
    use Bonseki.Controller, events: [:add]

    def init(_params) do
      %{count: 0}
    end

    def add(state, _params) do
      %{state | count: state.count + 1}
    end

    def expose(state, _dependencies) do
      %{count: state.count}
    end
  end

  defmodule LemonadeController do
    use Bonseki.Controller

    def init(dependencies) do
      # Handle both empty dependencies (initial) and with dependencies (re-init)
      total =
        if map_size(dependencies) > 0 do
          Map.get(dependencies, :lemons, %{count: 0}).count +
            Map.get(dependencies, :water, %{count: 0}).count +
            Map.get(dependencies, :sugar, %{count: 0}).count
        else
          0
        end

      %{total: total}
    end

    def expose(state, dependencies) do
      %{lemons: lemons, water: water, sugar: sugar} = dependencies

      total = lemons.count + water.count + sugar.count

      %{total: total}
    end
  end

  # Test App
  defmodule TestApp do
    use Bonseki.App

    scene do
      # default values
      controller(:lemons, Bonseki.IntegrationTest.LemonController,
        dependencies: [],
        on_when: true
      )

      controller(:water, Bonseki.IntegrationTest.WaterController)
      controller(:sugar, Bonseki.IntegrationTest.SugarController)

      controller(:lemonade, Bonseki.IntegrationTest.LemonadeController,
        dependencies: [:lemons, :water, :sugar]
      )
    end
  end

  describe "Bonseki Integration" do
    setup do
      app_pid =
        case Process.whereis(TestApp) do
          nil ->
            {:ok, app_pid} = TestApp.start_link()
            app_pid

          pid ->
            pid
        end

      {:ok, app_pid: app_pid}
    end

    test "controllers start in dependency order", %{app_pid: app_pid} do
      # Verify app is running
      assert Process.alive?(app_pid)

      # Verify app state has all controllers registered
      state = :sys.get_state(app_pid)
      assert map_size(state.controllers) == 4
      assert state.controllers[:lemons]
      assert state.controllers[:water]
      assert state.controllers[:sugar]
      assert state.controllers[:lemonade]
    end

    test "can dispatch events to controllers", %{app_pid: app_pid} do
      Process.alive?(app_pid)
      state = :sys.get_state(app_pid)
      lemons_pid = state.controllers[:lemons].pid
      exposed_state = GenServer.call(lemons_pid, :get_exposed_state)

      assert exposed_state.count == 0

      :ok = GenServer.call(app_pid, {:dispatch_event, :lemons, :add, %{}})

      lemons_pid = state.controllers[:lemons].pid
      exposed_state = GenServer.call(lemons_pid, :get_exposed_state)
      assert exposed_state.count == 1
      assert exposed_state.has_lemons == true
    end

    test "UI can register and receive initial state", %{app_pid: app_pid} do
      # Register a mock UI
      subscriptions = %{
        lemons: :lemons,
        water: :water
      }

      {:ok, initial_states} =
        GenServer.call(app_pid, {:register_ui, self(), subscriptions})

      # Verify initial states
      assert initial_states.lemons
      {controller_name, state, events} = initial_states.lemons
      assert controller_name == :lemons
      assert state.count == 0
      assert :add in events
      assert :remove in events

      assert initial_states.water
      {controller_name, state, _events} = initial_states.water
      assert controller_name == :water
      assert state.count == 0
    end

    test "UI receives updates when controller state changes", %{app_pid: app_pid} do
      # Register a mock UI
      subscriptions = %{
        lemons: :lemons
      }

      {:ok, _initial_states} =
        GenServer.call(app_pid, {:register_ui, self(), subscriptions})

      # Dispatch event to change state
      :ok = GenServer.call(app_pid, {:dispatch_event, :lemons, :add, %{}})

      # Wait for update message
      assert_receive {:bonseki_update, :lemons, :lemons, new_state}, 1000

      assert new_state.count == 1
      assert new_state.has_lemons == true
    end

    test "dependent controllers are notified when dependency changes", %{app_pid: app_pid} do
      # Register UI to lemonade controller
      subscriptions = %{lemonade: :lemonade}

      {:ok, _initial_states} = GenServer.call(app_pid, {:register_ui, self(), subscriptions})

      state = :sys.get_state(app_pid)

      lemons_state = :sys.get_state(state.controllers[:lemons].pid)
      lemonade_state = :sys.get_state(state.controllers[:lemonade].pid)
      # Change a dependency (:lemons controller)
      :ok = GenServer.call(app_pid, {:dispatch_event, :lemons, :add, %{}})
      :ok = GenServer.call(app_pid, {:dispatch_event, :water, :add, %{}})
      :ok = GenServer.call(app_pid, {:dispatch_event, :sugar, :add, %{}})

      lemonade_state = :sys.get_state(state.controllers[:lemonade].pid)

      assert lemonade_state.state.total == 3
    end

    test "lemonade controller calculates total from dependencies", %{app_pid: app_pid} do
      # Extra sleep to ensure lemonade's handle_continue has fully completed

      # Add to each ingredient
      :ok = GenServer.call(app_pid, {:dispatch_event, :lemons, :add, %{}})
      :ok = GenServer.call(app_pid, {:dispatch_event, :lemons, :add, %{}})
      :ok = GenServer.call(app_pid, {:dispatch_event, :water, :add, %{}})
      :ok = GenServer.call(app_pid, {:dispatch_event, :water, :add, %{}})
      :ok = GenServer.call(app_pid, {:dispatch_event, :water, :add, %{}})
      :ok = GenServer.call(app_pid, {:dispatch_event, :sugar, :add, %{}})

      # Get lemonade controller state
      state = :sys.get_state(app_pid)
      lemonade_pid = state.controllers[:lemonade].pid
      exposed_state = GenServer.call(lemonade_pid, :get_exposed_state)

      # Should be sum of all ingredients: 2 + 3 + 1 = 6
      assert exposed_state.total == 6
    end

    test "multiple UIs can subscribe to same controller", %{app_pid: app_pid} do
      # Register first UI
      subscriptions1 = %{lemons: :lemons}
      {:ok, _} = GenServer.call(app_pid, {:register_ui, self(), subscriptions1})

      # Spawn second UI process
      test_pid = self()

      ui2_pid =
        spawn(fn ->
          subscriptions2 = %{lemons: :lemons}
          {:ok, _} = GenServer.call(app_pid, {:register_ui, self(), subscriptions2})

          receive do
            {:bonseki_update, :lemons, :lemons, state} ->
              send(test_pid, {:ui2_received, state})
          after
            1000 -> :timeout
          end
        end)

      # Give UI2 time to register

      # Dispatch event
      :ok = GenServer.call(app_pid, {:dispatch_event, :lemons, :add, %{}})

      # Both UIs should receive update
      assert_receive {:bonseki_update, :lemons, :lemons, state1}, 1000
      assert state1.count == 1

      assert_receive {:ui2_received, state2}, 1000
      assert state2.count == 1

      # Cleanup
      Process.exit(ui2_pid, :kill)
    end

    test "UI is removed from registry when it terminates", %{app_pid: app_pid} do
      subscriptions = %{lemons: :lemons}
      {:ok, _} = GenServer.call(app_pid, {:register_ui, self(), subscriptions})

      state = :sys.get_state(app_pid)
      assert [ui] = state.uis

      :ok = GenServer.call(app_pid, {:unregister_ui, ui.pid})

      state = :sys.get_state(app_pid)
      assert [] == state.uis
    end

    test "controller exposes only specified state", %{app_pid: app_pid} do
      # Get lemons controller pid
      state = :sys.get_state(app_pid)
      lemons_pid = state.controllers[:lemons].pid

      # Add some lemons
      :ok = GenServer.call(lemons_pid, {:event, :add, %{}})
      :ok = GenServer.call(lemons_pid, {:event, :add, %{}})

      # Get full state
      full_state = GenServer.call(lemons_pid, :get_state)
      assert full_state == %{count: 2, has_lemons: true}

      # Get exposed state
      exposed_state = GenServer.call(lemons_pid, :get_exposed_state)
      assert exposed_state == %{count: 2, has_lemons: true}
    end

    test "events are properly defined and callable", %{app_pid: app_pid} do
      # Get lemons controller info
      state = :sys.get_state(app_pid)
      lemons_info = state.controllers[:lemons]

      # Get event definition
      events = lemons_info.module.definition()
      assert :add in events
      assert :remove in events

      # Call events
      :ok = GenServer.call(lemons_info.pid, {:event, :add, %{}})
      controller_state = GenServer.call(lemons_info.pid, :get_state)
      assert controller_state.count == 1

      :ok = GenServer.call(lemons_info.pid, {:event, :remove, %{}})
      controller_state = GenServer.call(lemons_info.pid, :get_state)
      assert controller_state.count == 0
    end

    test "UI unregistration works correctly", %{app_pid: app_pid} do
      # Register UI
      subscriptions = %{lemons: :lemons}
      {:ok, _} = GenServer.call(app_pid, {:register_ui, self(), subscriptions})

      # Verify registered
      state = :sys.get_state(app_pid)
      assert length(state.uis) == 1

      # Unregister
      :ok = GenServer.call(app_pid, {:unregister_ui, self()})

      # Verify unregistered
      state = :sys.get_state(app_pid)
      assert length(state.uis) == 0
    end
  end

  describe "Dependency Graph" do
    test "detects cyclic dependencies" do
      # This should raise a compile error due to cycle
      assert_raise CompileError, ~r/Cyclic dependency/, fn ->
        Code.eval_string("""
        defmodule Bonseki.IntegrationTest.CyclicApp do
          use Bonseki.App

          defmodule A do
            use Bonseki.Controller, events: []
          end

          defmodule B do
            use Bonseki.Controller, events: []
          end

          scene do
            controller(:a, A, dependencies: [:b])
            controller(:b, B, dependencies: [:a])
          end
        end
        """)
      end
    end

    test "correctly resolves complex dependencies" do
      defmodule ComplexApp do
        use Bonseki.App

        defmodule ControllerA do
          use Bonseki.Controller, events: []
          def init(_), do: %{}
          def expose(state, _), do: state
        end

        defmodule ControllerB do
          use Bonseki.Controller, events: []
          def init(_), do: %{}
          def expose(state, _), do: state
        end

        defmodule ControllerC do
          use Bonseki.Controller, events: []
          def init(_), do: %{}
          def expose(state, _), do: state
        end

        defmodule ControllerD do
          use Bonseki.Controller, events: []
          def init(_), do: %{}
          def expose(state, _), do: state
        end

        scene do
          controller(:a, ControllerA)
          controller(:b, ControllerB, dependencies: [:a])
          controller(:c, ControllerC, dependencies: [:a])
          controller(:d, ControllerD, dependencies: [:b, :c])
        end
      end

      {:ok, app_pid} = ComplexApp.start_link()

      # Give controllers time to start and fully initialize (handle_continue)

      # All controllers should be registered
      state = :sys.get_state(app_pid)
      assert map_size(state.controllers) == 4
      assert state.controllers[:a]
      assert state.controllers[:b]
      assert state.controllers[:c]
      assert state.controllers[:d]

      # Cleanup
      Process.exit(app_pid, :kill)
    end
  end
end
