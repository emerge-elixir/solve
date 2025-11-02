defmodule Bonseki do
  @moduledoc """
  Bonseki - A declarative state management architecture for Phoenix LiveView.

  Bonseki provides a clean separation between state management (Controllers),
  coordination (App), and presentation (UI). It enables dependency management
  between state containers with direct communication between all components.

  ## Architecture

  - **Controller**: A GenServer that manages state, handles events, and communicates
    directly with UIs and dependent controllers
  - **App**: A coordinator that manages controller lifecycle and dependency graph resolution
  - **UI**: A LiveView that subscribes directly to controllers and dispatches events to them

  ## Communication Flow

  Controllers communicate directly with their dependents (UIs and other controllers),
  eliminating the need for a central routing hub. This provides:

  - Better performance (fewer GenServer hops)
  - Clearer separation of concerns
  - Improved scalability

  ## Quick Example

      # Define a controller
      defmodule MyApp.CounterController do
        use Bonseki.Controller, events: [:increment, :decrement]

        def init(_dependencies), do: %{count: 0}

        def increment(state, _params), do: %{state | count: state.count + 1}
        def decrement(state, _params), do: %{state | count: state.count - 1}

        @impl true
        def expose(state, _dependencies), do: state
      end

      # Define an app
      defmodule MyApp.App do
        use Bonseki.App

        scene do
          controller(:counter, MyApp.CounterController)
        end
      end

      # Define a UI
      defmodule MyAppWeb.CounterLive do
        use Bonseki.UI, app: MyApp.App

        def init(_params) do
          %{counter: :counter}  # subscribe to :counter controller
        end

        def render(assigns) do
          ~H\"\"\"
          <div>
            <h1>Count: {@counter.count}</h1>
            <button phx-click={@counter.increment}>+</button>
            <button phx-click={@counter.decrement}>-</button>
          </div>
          \"\"\"
        end
      end

  ## Features

  - Declarative state management with direct communication
  - Dependency resolution between controllers
  - Automatic state propagation to UIs and dependent controllers
  - Type-safe event handling
  - Compile-time dependency cycle detection
  - Process monitoring and automatic cleanup
  """
end
