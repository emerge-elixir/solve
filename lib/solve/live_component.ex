defmodule Solve.LiveComponent do
  @moduledoc """
  A macro for integrating Solve with Phoenix LiveComponent.

  LiveComponents subscribe to controllers from the parent LiveView's Solve instance.
  Multiple instances of the same component share the same controller state.

  ## Subscribing to Controllers

  You can subscribe to controllers in two ways:

  ### Using @controllers (Recommended for most cases)

      defmodule MyAppWeb.AuthFormComponent do
        use Solve.LiveComponent

        # Simple list - assign name matches controller name
        @controllers [:auth]

        # Or keyword list - assign name => controller name
        @controllers [my_auth: :auth_controller]

        def render(assigns) do
          ~H\"\"\"
          <div>
            <.form phx-submit={@auth.submit}>
              <.input field={@auth.form[:email]} type="email" />
              <.input field={@auth.form[:password]} type="password" />
              <button>{@auth.cta}</button>
            </.form>
          </div>
          \"\"\"
        end
      end

  ### Using init/1 (For dynamic subscriptions)

  Use `init/1` when you need to conditionally subscribe based on assigns:

      defmodule MyAppWeb.ProfileComponent do
        use Solve.LiveComponent

        def init(assigns) do
          base = %{profile: :profile}

          if assigns[:show_settings] do
            Map.put(base, :settings, :settings)
          else
            base
          end
        end

        def render(assigns) do
          ~H\"\"\"
          <div>Profile content...</div>
          \"\"\"
        end
      end

  **Note**: If both `@controllers` and `init/1` are defined, `init/1` takes
  precedence when it returns a non-empty map.

  Then in your Solve.LiveView:

      def render(assigns) do
        ~H\"\"\"
        <div>
          <.live_component module={MyAppWeb.AuthFormComponent} id="auth-form" />
        </div>
        \"\"\"
      end

  ## How It Works

  1. **Mount**: The component accesses the parent's Solve PID from socket assigns
     (__solve_pid__ is automatically injected by Solve.LiveView)
  2. **Init**: The `init/1` function receives params (including `id` and any other assigns)
     and returns a map of subscriptions (assign_name => controller_name)

     **IMPORTANT**: LiveComponents subscribe to controllers already defined in the
     parent's Solve scene. Use simple atoms like `%{auth: :auth}`, NOT tuples with
     controller modules and params like `%{auth: {MyController, params: fn -> ... end}}`.

  3. **Subscribe**: Each controller is subscribed to directly via `GenServer.call`
  4. **ControllerAssign**: A wrapper struct provides access to both events and exposed state
  5. **Updates**: Controllers send `{:solve_update, ...}` messages directly to the LiveComponent

  ## Shared State

  Multiple instances of the same component (with different IDs) will share the same
  controller state. For example:

      <.live_component module={MyForm} id="form-1" />
      <.live_component module={MyForm} id="form-2" />

  Both instances will see and interact with the same controller state.

  ## Separation of Concerns

  LiveComponents can subscribe to controllers independently of their parent LiveView.
  This allows for clean separation of concerns where:

  - The parent LiveView only subscribes to controllers it needs
  - Child components subscribe to their own controllers
  - Components are self-contained and reusable
  - **Events are automatically targeted** to the component (no need for manual `phx-target={@myself}`)

  Example:

      # Parent LiveView - doesn't subscribe to auth
      defmodule MyAppWeb.DashboardLive do
        use Solve.LiveView, scene: MyApp

        @controllers [:dashboard]

        def render(assigns) do
          ~H\"\"\"
          <div>
            <h1>Dashboard</h1>
            <.live_component module={MyAppWeb.AuthFormComponent} id="auth" />
          </div>
          \"\"\"
        end
      end

      # Child component - subscribes to auth independently
      defmodule MyAppWeb.AuthFormComponent do
        use Solve.LiveComponent

        @controllers [:auth]

        def render(assigns) do
          ~H\"\"\"
          <.form phx-submit={@auth.submit}>
            <!-- Events automatically target this component! -->
            <!-- No need for phx-target={@myself} -->
            ...
          </.form>
          \"\"\"
        end
      end

  ## Automatic Event Targeting

  When you use controller events in a LiveComponent (e.g., `phx-submit={@auth.submit}`),
  Solve automatically generates JavaScript commands that target the component. This means:

  - ✅ Events stay within the component (no bubbling to parent)
  - ✅ No need to manually add `phx-target={@myself}`
  - ✅ Parent can safely ignore events for controllers it doesn't subscribe to
  - ✅ Components are truly independent and self-contained

  This is done using `Phoenix.LiveView.JS.push/2` behind the scenes to ensure
  events are routed to the correct component.

  ## After Actions

  Components support after actions just like LiveViews. The `after_action` callback
  defined in the scene is applied after every controller state update, allowing
  socket operations like redirects and flash messages.
  """

  defmacro __before_compile__(env) do
    controllers = Module.get_attribute(env.module, :controllers)

    quote do
      def __controllers__ do
        Solve.LiveView.normalize_controllers(unquote(Macro.escape(controllers)))
      end
    end
  end

  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveComponent
      import Phoenix.Component

      Module.register_attribute(__MODULE__, :controllers, accumulate: false)

      @before_compile Solve.LiveComponent

      @impl true
      def mount(socket) do
        {:ok, socket}
      end

      @impl true
      def update(assigns, socket) do
        # Get the Solve PID from assigns (set by parent LiveView)
        solve_pid = assigns[:__solve_pid__]

        if solve_pid == nil do
          raise "Solve.LiveComponent requires parent LiveView to use Solve.LiveView"
        end

        # Check if this is the first update (subscriptions not yet set up)
        needs_subscription = is_nil(socket.assigns[:__solve_subscribed__])

        socket =
          if needs_subscription do
            # Get controller subscriptions:
            # 1. Try init/1 first (takes precedence if non-empty)
            # 2. Fall back to __controllers__ if init returns empty
            subscriptions =
              case init(assigns) do
                empty when empty == %{} ->
                  __controllers__()

                custom_subscriptions ->
                  custom_subscriptions
              end

            # Subscribe to controllers
            socket =
              subscriptions
              |> Enum.reduce(socket, fn {assign_name, controller_name}, socket ->
                # Fetch controller PID
                controller_pid =
                  GenServer.call(solve_pid, {:fetch_controller_pid, controller_name})

                # If controller is not alive (nil), assign nil
                if controller_pid == nil do
                  assign(socket, assign_name, nil)
                else
                  # Subscribe to controller
                  {:ok, exposed_state, events} =
                    GenServer.call(controller_pid, {:subscribe_ui, assign_name})

                  # Build ControllerAssign wrapper with @myself for automatic targeting
                  # @myself will be available after first assignment from parent
                  myself = assigns[:myself]

                  assign_value =
                    Solve.ControllerAssign.new(
                      controller_pid,
                      events,
                      exposed_state,
                      assign_name,
                      myself
                    )

                  assign(socket, assign_name, assign_value)
                end
              end)

            # Mark as subscribed and store solve_pid
            socket
            |> assign(:__solve_subscribed__, true)
            |> assign(:__solve_pid__, solve_pid)
          else
            socket
          end

        # Assign all other assigns from parent
        socket = assign(socket, assigns)

        {:ok, socket}
      end

      @impl true
      def handle_event("solve:" <> event_string, params, socket) do
        [assign_name_str, event_name] = String.split(event_string, ":", parts: 2)
        assign_name = String.to_existing_atom(assign_name_str)
        event_atom = String.to_existing_atom(event_name)

        # Check if this component is subscribed to this controller
        case socket.assigns[assign_name] do
          nil ->
            {:noreply, socket}

          controller_assign ->
            controller_pid = controller_assign.pid
            GenServer.cast(controller_pid, {:event, event_atom, params})
            {:noreply, socket}
        end
      end

      # Handle state updates from controllers
      def handle_info(
            {:solve_update, assign_name, controller_name, new_exposed_state},
            socket
          ) do
        current_assign = socket.assigns[assign_name]

        # Rebuild ControllerAssign with new exposed state (preserve myself)
        updated_assign =
          %{current_assign | exposed: new_exposed_state}

        socket = assign(socket, assign_name, updated_assign)

        # Apply after_action via Solve (which stores the after_action metadata)
        solve_pid = socket.assigns.__solve_pid__

        socket =
          GenServer.call(
            solve_pid,
            {:apply_after_action, controller_name, socket, new_exposed_state}
          )

        {:noreply, socket}
      end

      @doc """
      Initialize the LiveComponent. Use this to subscribe to controllers dynamically.
      Receives all assigns passed to the component (including `id`).
      Returns a map of assign_name => controller_name.

      If this returns a non-empty map, it takes precedence over @controllers.
      If this returns an empty map (default), @controllers will be used.

      Use this when you need conditional subscriptions based on assigns.
      For static subscriptions, prefer using @controllers instead.

      ## Example

          def init(assigns) do
            # assigns includes :id and any other assigns from parent
            base = %{auth: :auth_controller}

            if assigns[:show_profile] do
              Map.put(base, :profile, :current_user)
            else
              base
            end
          end
      """
      @callback init(params :: map()) :: map()

      def init(_params) do
        %{}
      end

      defoverridable init: 1, mount: 1, update: 2, handle_event: 3, handle_info: 2
    end
  end
end
