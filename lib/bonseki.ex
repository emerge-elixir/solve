defmodule Bonseki do
  @moduledoc """
  Bonseki - A declarative state management architecture for Phoenix LiveView.

  Bonseki provides a clean separation between state management (Controllers),
  coordination (App), and presentation (UI). It enables dependency management
  between state containers and automatic propagation of state changes to UIs.

  ## Architecture

  - **Controller**: A GenServer that manages state and handles events
  - **App**: A coordinator that manages controllers and routes events
  - **UI**: A LiveView that subscribes to controllers and displays state

  ## Quick Example

      # Define a controller
      defmodule MyApp.CounterController do
        use Bonseki.Controller, events: [:increment, :decrement]

        def init(_params), do: %{count: 0}

        def increment(state, _params), do: %{state | count: state.count + 1}
        def decrement(state, _params), do: %{state | count: state.count - 1}
      end

      # Define an app
      defmodule MyApp.App do
        use Bonseki.App

        scene do
          controller(MyApp.CounterController)
        end
      end

      # Define a UI
      defmodule MyAppWeb.CounterLive do
        use Bonseki.UI, app: MyApp.App

        def init(_params) do
          subscribe(MyApp.CounterController, :counter)
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

  - Declarative state management
  - Dependency resolution between controllers
  - Automatic state propagation to UIs
  - Type-safe event handling
  - Compile-time validations
  """
end
