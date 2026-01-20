# Solve.LiveComponent Example

This example demonstrates how to use `Solve.LiveComponent` to create reusable components that subscribe to controllers.

## Controller

First, define a controller that will be shared by all component instances:

```elixir
defmodule MyApp.AuthController do
  use Solve.Controller, events: [:validate, :submit]

  alias MyApp.Accounts.User
  alias AshPhoenix.Form

  @impl true
  def init(live_action, _dependencies) do
    case live_action do
      :register ->
        %{
          form_id: "sign-up-form",
          cta: "Sign up",
          live_action: :register,
          form: set_form(:register_with_password)
        }

      :login ->
        %{
          form_id: "sign-in-form",
          cta: "Sign in",
          live_action: :login,
          form: set_form(:sign_in_with_password)
        }
    end
  end

  @impl true
  def expose(state, _dependencies) do
    state
  end

  def validate(%{form: form} = state, %{"user" => params}) do
    %{state | form: AshPhoenix.Form.validate(form, params, errors: false)}
  end

  def submit(%{form: form} = state, %{"user" => params}) do
    case AshPhoenix.Form.submit(form, params: params) do
      {:ok, user} ->
        token = user.__metadata__.token
        path = "/auth/user/password/sign_in_with_token?token=#{token}"
        %{state | socket_action: &Phoenix.LiveView.redirect(&1, to: path)}

      {:error, form} ->
        %{state | form: form}
    end
  end

  defp set_form(action) do
    User |> Form.for_action(action, as: "user") |> Phoenix.Component.to_form()
  end
end
```

## Solve Scene

Define your scene with the controller:

```elixir
defmodule MyApp do
  use Solve

  scene params do
    # Controller gets live_action from LiveView params
    controller(:auth, MyApp.AuthController,
      params: fn _deps -> params[:live_action] end
    )
  end
end
```

## LiveComponent

Create a reusable component that subscribes to the controller.

### Using @controllers (Recommended)

```elixir
defmodule MyAppWeb.AuthFormComponent do
  use Solve.LiveComponent

  # Subscribe to the auth controller
  @controllers [:auth]

  def render(assigns) do
    ~H"""
    <div class="auth-form">
      <.form
        for={@auth[:form]}
        id={@auth[:form_id]}
        phx-change={@auth.validate}
        phx-submit={@auth.submit}
      >
        <!-- No phx-target needed! Events automatically target this component -->
        <%= if @auth[:live_action] == :register do %>
          <fieldset>
            <.input
              form={@auth[:form]}
              field={:username}
              type="text"
              placeholder="Your Name"
            />
          </fieldset>
        <% end %>
        <fieldset>
          <.input
            form={@auth[:form]}
            field={:email}
            type="email"
            placeholder="Email"
          />
        </fieldset>
        <fieldset>
          <.input
            form={@auth[:form]}
            field={:password}
            type="password"
            placeholder="Password"
          />
        </fieldset>
        <button type="submit">
          {@auth[:cta]}
        </button>
      </.form>
    </div>
    """
  end
end
```

### Alternative: Using init/1 (For dynamic subscriptions)

If you need conditional subscriptions based on component assigns:

```elixir
defmodule MyAppWeb.AuthFormComponent do
  use Solve.LiveComponent

  def init(assigns) do
    # Conditionally subscribe based on assigns
    base = %{auth: :auth}
    
    if assigns[:show_extra] do
      Map.put(base, :extra, :extra_controller)
    else
      base
    end
  end

  # ... render function ...
end
```

## LiveView

Use the component in your LiveView:

```elixir
defmodule MyAppWeb.AuthLive do
  use Solve.LiveView, scene: MyApp

  def mount_to_solve(_params, _session, socket) do
    # Pass live_action to Solve so controller can use it
    %{live_action: socket.assigns[:live_action]}
  end

  def init(_params) do
    # LiveView doesn't need to subscribe to anything
    # The component handles that
    %{}
  end

  def render(assigns) do
    ~H"""
    <div class="auth-page">
      <h1>Welcome!</h1>
      
      <!-- Render the component with just an id -->
      <!-- All state management is handled by the controller -->
      <.live_component module={MyAppWeb.AuthFormComponent} id="auth-form" />
      
      <!-- You can render the same component multiple times -->
      <!-- They all share the same controller state -->
      <.live_component module={MyAppWeb.AuthFormComponent} id="auth-form-2" />
    </div>
    """
  end
end
```

## Key Points

1. **No Props Needed**: The component doesn't need any props passed to it beyond `id`. All data comes from the controller.

2. **Shared State**: Multiple instances of the component share the same controller state. Both `auth-form` and `auth-form-2` will see the same data.

3. **Reusable**: The component can be used anywhere in your application, as long as the parent is a `Solve.LiveView` with the required controllers.

4. **Clean Separation**: The component focuses only on rendering and user interaction. All business logic lives in the controller.

5. **Automatic Event Targeting**: Events automatically target the component - no need to manually add `phx-target={@myself}`! Solve uses Phoenix.LiveView.JS to ensure events stay within the component.

6. **Simple Subscriptions**: Use `@controllers [:controller_name]` for static subscriptions, or `init/1` when you need dynamic logic based on assigns.

7. **Independent Controllers**: Components can subscribe to controllers the parent doesn't have, enabling true separation of concerns.

