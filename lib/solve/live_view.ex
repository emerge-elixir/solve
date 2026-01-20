defmodule Solve.LiveView do
  @moduledoc """
  A macro for integrating Solve with Phoenix LiveView.

  LiveViews subscribe directly to controllers and communicate with them without
  any intermediary. This provides a clean, efficient architecture with
  minimal message passing overhead.

  ## Direct Communication

  - **Subscriptions**: LiveViews subscribe directly to controllers during mount
  - **Events**: LiveViews send events directly to controller PIDs
  - **Updates**: LiveViews receive state updates directly from controllers

  ## Multiple LiveView Instances

  Each LiveView instance automatically gets its own isolated Solve instance with
  independent controllers. This allows multiple users or sessions to have
  completely separate state:

      defmodule MyAppWeb.DashboardLive do
        use Solve.LiveView, scene: MyApp

        def init(_params) do
          %{counter: :counter}
        end
      end

  When multiple DashboardLive instances mount, each gets a uniquely named
  Solve instance (e.g., `MyAppWeb.DashboardLive.Solve.1`, `MyAppWeb.DashboardLive.Solve.2`, etc.)
  with its own controller processes and state.

  ## Subscribing to Controllers

  You can subscribe to controllers in two ways:

  ### Using @controllers (Recommended for most cases)

      defmodule MyAppWeb.DashboardLive do
        use Solve.LiveView, scene: MyApp

        # Simple list - assign name matches controller name
        @controllers [:lemons, :water, :current_user]

        # Or keyword list - assign name => controller name
        @controllers [my_lemons: :lemons, my_water: :water]

        def render(assigns) do
          ~H\"\"\"
          <div>
            <h1>Welcome {@current_user.first_name}!</h1>

            <h1>Lemons: {@lemons.count}</h1>
            <button phx-click={@lemons.add}>Add Lemon</button>

            <h1>Water: {@water.count}</h1>
            <button phx-click={@water.add}>Add Water</button>
          </div>
          \"\"\"
        end
      end

  ### Using init/1 (For dynamic subscriptions)

  Use `init/1` when you need to conditionally subscribe based on params:

      defmodule MyAppWeb.DashboardLive do
        use Solve.LiveView, scene: MyApp

        def init(params) do
          base = %{lemons: :lemons, water: :water}

          if params[:show_user] do
            Map.put(base, :current_user, :current_user)
          else
            base
          end
        end

        def render(assigns) do
          ~H\"\"\"
          <div>
            <h1>Lemons: {@lemons.count}</h1>
            <button phx-click={@lemons.add}>Add Lemon</button>
          </div>
          \"\"\"
        end
      end

  **Note**: If both `@controllers` and `init/1` are defined, `init/1` takes
  precedence when it returns a non-empty map.

  ## How It Works

  1. **Mount to Solve**: The `mount_to_solve/3` function is called to get params for Solve
  2. **Solve Creation**: A unique Solve instance is automatically started with those params
  3. **Init**: The `init/1` function returns a map of subscriptions (assign_name => controller_name)
  4. **Subscribe**: Each controller is subscribed to directly via `GenServer.call`
  5. **ControllerAssign**: A wrapper struct transparently provides access to both events and exposed state
  6. **Updates**: Controllers send `{:solve_update, ...}` messages directly to the LiveView

  ## Accessing Controller State and Events

  The ControllerAssign struct transparently provides access to both the exposed
  state and events from a controller:

  - **Exposed State**: Access values returned by the controller's `expose/2` function
  - **Events**: Event strings are automatically generated as `"solve:assign_name:event_name"`

  For example, if a controller exposes `%User{first_name: "Alice"}` and has
  an `:update_profile` event:

  - `@current_user.first_name` returns `"Alice"`
  - `@current_user.update_profile` returns `"solve:current_user:update_profile"`

  If the controller is not running, the entire assign is `nil`.

  ## After Actions

  You can define an `after_action` callback when configuring a controller in your scene.
  This callback is executed after every state update from that controller, allowing you
  to perform socket operations like redirects and flash messages based on the controller's
  exposed state:

      def scene(params) do
        %{
          auth: {AuthController,
            params: fn _ -> params[:live_action] end,
            after_action: fn socket, state ->
              case state.status do
                :success -> Phoenix.LiveView.redirect(socket, to: state.path)
                :error -> Phoenix.LiveView.put_flash(socket, :error, state.error)
                _ -> socket
              end
            end
          }
        }
      end

  The `after_action` function receives the socket and the controller's exposed state,
  and should return a modified socket. This allows controllers to remain unaware of
  LiveView internals while still being able to trigger navigation, flash messages,
  or other socket operations.
  """

  @doc """
  Ensures a Solve is started for the given LiveView module with the provided params.

  This function generates a unique Solve name based on the LiveView module and starts
  Solve with the given params. Each call creates a new instance with an
  incrementing counter.

  ## Examples

      iex> Solve.LiveView.ensure_solve_started(MyApp, MyAppWeb.DashboardLive, %{user: user})
      {:ok, #PID<0.123.0>}
  """
  def ensure_solve_started(solve_module, liveview_module, params) do
    counter = System.unique_integer([:positive])
    counter_atom = String.to_atom(Integer.to_string(counter))
    solve_name = Module.concat([liveview_module, Solve, counter_atom])
    solve_module.start_link(name: solve_name, params: params)
  end

  defmacro __before_compile__(env) do
    controllers = Module.get_attribute(env.module, :controllers)

    quote do
      def __controllers__ do
        Solve.LiveView.normalize_controllers(unquote(Macro.escape(controllers)))
      end
    end
  end

  @doc """
  Normalizes controller list from @controllers attribute to a map.

  Supports both list and keyword list formats:
  - `[:auth, :profile]` -> `%{auth: :auth, profile: :profile}`
  - `[my_auth: :auth, user: :profile]` -> `%{my_auth: :auth, user: :profile}`

  ## Examples

      iex> Solve.LiveView.normalize_controllers([:auth, :profile])
      %{auth: :auth, profile: :profile}

      iex> Solve.LiveView.normalize_controllers([my_auth: :auth_controller])
      %{my_auth: :auth_controller}

      iex> Solve.LiveView.normalize_controllers(nil)
      %{}
  """
  def normalize_controllers(nil), do: %{}
  def normalize_controllers([]), do: %{}

  def normalize_controllers(controllers) when is_list(controllers) do
    case controllers do
      # Keyword list: [my_auth: :auth, user: :profile]
      [{key, value} | _rest] = kw_list when is_atom(key) and is_atom(value) ->
        Map.new(kw_list)

      # Regular list: [:auth, :profile]
      list when is_list(list) ->
        Map.new(list, fn controller -> {controller, controller} end)
    end
  end

  defmacro __using__(opts) do
    solve_module = Keyword.fetch!(opts, :scene)

    quote do
      use Phoenix.LiveView
      import Phoenix.Component, except: [live_component: 1]

      @solve_module unquote(solve_module)
      Module.register_attribute(__MODULE__, :controllers, accumulate: false)

      @doc """
      Override live_component/1 to automatically inject __solve_pid__.
      This allows users to call live_component without manually passing __solve_pid__.
      """
      defmacro live_component(assigns) do
        quote do
          Phoenix.Component.live_component(
            Map.put(unquote(assigns), :__solve_pid__, var!(assigns).__solve_pid__)
          )
        end
      end

      @before_compile Solve.LiveView

      @impl true
      def mount(params, session, socket) do
        # Call mount_to_solve to get Solve params
        solve_params = mount_to_solve(params, session, socket)

        # Start Solve with params
        {:ok, solve_pid} =
          Solve.LiveView.ensure_solve_started(@solve_module, __MODULE__, solve_params)

        # Get controller subscriptions:
        # 1. Try init/1 first (takes precedence if non-empty)
        # 2. Fall back to __controllers__ if init returns empty
        subscriptions =
          case init(params) do
            empty when empty == %{} ->
              __controllers__()

            custom_subscriptions ->
              custom_subscriptions
          end

        socket =
          subscriptions
          |> Enum.reduce(socket, fn {assign_name, controller_name}, socket ->
            # Fetch controller PID
            controller_pid = GenServer.call(solve_pid, {:fetch_controller_pid, controller_name})

            # If controller is not alive (nil), assign nil
            if controller_pid == nil do
              Phoenix.Component.assign(socket, assign_name, nil)
            else
              # Subscribe to controller
              {:ok, exposed_state, events} =
                GenServer.call(controller_pid, {:subscribe_ui, assign_name})

              # Build ControllerAssign wrapper
              assign_value =
                Solve.ControllerAssign.new(controller_pid, events, exposed_state, assign_name)

              Phoenix.Component.assign(socket, assign_name, assign_value)
            end
          end)
          # Store Solve PID for LiveComponents to access
          |> Phoenix.Component.assign(:__solve_pid__, solve_pid)

        {:ok, socket}
      end

      @impl true
      def handle_event("solve:" <> event_string, params, socket) do
        [assign_name_str, event_name] = String.split(event_string, ":", parts: 2)
        assign_name = String.to_existing_atom(assign_name_str)
        event_atom = String.to_existing_atom(event_name)

        # Check if this LiveView is subscribed to this controller
        # If not, ignore the event (it may be meant for a LiveComponent)
        case socket.assigns[assign_name] do
          nil ->
            {:noreply, socket}

          controller_assign ->
            controller_pid = controller_assign.pid
            GenServer.cast(controller_pid, {:event, event_atom, params})
            {:noreply, socket}
        end
      end

      @impl true
      def handle_info(
            {:solve_update, assign_name, controller_name, new_exposed_state},
            socket
          ) do
        current_assign = socket.assigns[assign_name]

        # Rebuild ControllerAssign with new exposed state
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
      Called before mounting to get params that will be passed to Solve.
      Override this to provide custom params based on session or socket data.

      ## Example

          def mount_to_solve(_params, session, socket) do
            user = get_current_user(session)
            %{current_user: user}
          end
      """
      @callback mount_to_solve(
                  params :: map(),
                  session :: map(),
                  socket :: Phoenix.LiveView.Socket.t()
                ) :: map()

      def mount_to_solve(_params, _session, _socket) do
        %{}
      end

      @doc """
      Initialize the LiveView. Use this to subscribe to controllers dynamically.
      Returns a map of assign_name => controller_name.

      If this returns a non-empty map, it takes precedence over @controllers.
      If this returns an empty map (default), @controllers will be used.

      Use this when you need conditional subscriptions based on params.
      For static subscriptions, prefer using @controllers instead.
      """
      @callback init(params :: map()) :: map()

      def init(_params) do
        %{}
      end

      defoverridable mount_to_solve: 3, init: 1
    end
  end
end
