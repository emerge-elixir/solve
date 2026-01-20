# Solve.LiveComponent Implementation

## Overview

`Solve.LiveComponent` has been implemented to wrap Phoenix LiveComponent, enabling reusable components that subscribe to controllers from the parent LiveView's Solve instance.

## Key Features

1. **Shared Controller Access**: LiveComponents access controllers from the parent Solve.LiveView instance
2. **Shared State**: Multiple instances of the same component share the same controller state
3. **Params-based Initialization**: The `init/1` function receives all assigns (including `id`) passed to the component
4. **Zero-prop Components**: Components can be rendered with just an `id`, no additional props needed
5. **Event Handling**: Components handle events and forward them to controllers
6. **Socket Actions**: Components support socket actions just like LiveViews

## Architecture

```
┌─────────────────────┐
│  Solve.LiveView     │
│  (Parent)           │
│                     │
│  Solve Instance ────┼─────┐
│  Controllers        │     │
└─────────────────────┘     │
         │                  │
         │ renders          │ accesses
         │                  │
         ▼                  │
┌─────────────────────┐     │
│  LiveComponent 1    │◄────┘
│  (id: "form-1")     │
│                     │
│  Subscribes to:     │
│  - :auth            │────┐
│  - :user            │    │
└─────────────────────┘    │
         │                 │
         │ shares state    │
         ▼                 │
┌─────────────────────┐    │
│  LiveComponent 2    │    │
│  (id: "form-2")     │    │ same controllers
│                     │    │
│  Subscribes to:     │    │
│  - :auth            │────┤
│  - :user            │    │
└─────────────────────┘    │
                           │
        ┌──────────────────┘
        ▼
┌─────────────────────┐
│  Controller         │
│  (shared by all)    │
└─────────────────────┘
```

## Implementation Details

### 1. Solve.LiveComponent Module (`lib/solve/live_component.ex`)

- Wraps `Phoenix.LiveComponent`
- Implements `update/2` callback to handle subscriptions
- Implements `handle_event/3` to forward events to controllers
- Implements `handle_info/2` to receive state updates from controllers
- Provides `init/1` callback for users to define controller subscriptions

### 2. Solve.LiveView Update (`lib/solve/live_view.ex`)

- Stores Solve PID in socket assigns as `__solve_pid__`
- LiveComponents access this PID to subscribe to controllers

### 3. Tests (`test/solve/live_component_test.exs`)

Comprehensive test coverage including:
- Controller subscription
- Multiple instances sharing state
- Event handling
- Error handling when parent is not Solve.LiveView
- Params passing to `init/1`

## Usage Example

### Define a Controller

```elixir
defmodule MyApp.AuthController do
  use Solve.Controller, events: [:validate, :submit]

  @impl true
  def init(live_action, _dependencies) do
    %{
      form_id: "auth-form",
      cta: "Sign in",
      form: build_form(live_action)
    }
  end

  @impl true
  def expose(state, _dependencies), do: state

  def validate(state, params), do: %{state | form: validate_form(state.form, params)}
  def submit(state, params), do: handle_submit(state, params)
end
```

### Define a Scene

```elixir
defmodule MyApp do
  use Solve

  scene params do
    controller(:auth, MyApp.AuthController,
      params: fn _deps -> params[:live_action] end
    )
  end
end
```

### Create a LiveComponent

```elixir
defmodule MyAppWeb.AuthFormComponent do
  use Solve.LiveComponent

  def init(_params) do
    %{auth: :auth}  # Subscribe to auth controller
  end

  def render(assigns) do
    ~H"""
    <.form for={@auth.form} phx-submit={@auth.submit} phx-target={@myself}>
      <.input field={@auth.form[:email]} type="email" />
      <button>{@auth.cta}</button>
    </.form>
    """
  end
end
```

### Use in LiveView

```elixir
defmodule MyAppWeb.AuthLive do
  use Solve.LiveView, scene: MyApp

  def mount_to_solve(_params, _session, socket) do
    %{live_action: socket.assigns[:live_action]}
  end

  def init(_params), do: %{}

  def render(assigns) do
    ~H"""
    <div>
      <.live_component module={MyAppWeb.AuthFormComponent} id="auth-form" />
    </div>
    """
  end
end
```

## Benefits

1. **Reusability**: Components can be reused across different LiveViews
2. **Clean Separation**: Business logic stays in controllers, components focus on rendering
3. **No Prop Drilling**: No need to pass data through multiple component layers
4. **Shared State**: Multiple instances automatically share state without coordination
5. **Type Safety**: Events are type-checked at compile time via `use Solve.Controller`

## Files Changed

- ✅ Created `lib/solve/live_component.ex`
- ✅ Updated `lib/solve/live_view.ex`
- ✅ Created `test/solve/live_component_test.exs`
- ✅ Updated `test/solve/live_view_test.exs` (fixed state assertions)
- ✅ Created `examples/live_component_example.md`

## Test Results

All tests passing:
- 14 total tests
- 0 failures
- Coverage includes both LiveView and LiveComponent functionality

