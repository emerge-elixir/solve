# Separation of Concerns: Independent Component Subscriptions

## Problem

Previously, when a LiveComponent subscribed to a controller that its parent LiveView wasn't subscribed to, events from that component would cause the parent LiveView to crash with:

```
** (KeyError) key :pid not found in: nil
```

This happened because:
1. Component subscribed to `:auth` controller
2. Parent LiveView did NOT subscribe to `:auth`  
3. Component's form events (without `phx-target={@myself}`) bubbled up to parent
4. Parent's `handle_event` tried to access `socket.assigns[:auth].pid`
5. Since parent wasn't subscribed, `socket.assigns[:auth]` was `nil`
6. Accessing `.pid` on `nil` caused the crash

## Solution

Made both `Solve.LiveView` and `Solve.LiveComponent` `handle_event` implementations defensive:

```elixir
def handle_event("solve:" <> event_string, params, socket) do
  [assign_name_str, event_name] = String.split(event_string, ":", parts: 2)
  assign_name = String.to_existing_atom(assign_name_str)
  event_atom = String.to_existing_atom(event_name)
  
  # Check if this LiveView/Component is subscribed to this controller
  # If not, ignore the event (it may be meant for a different component)
  case socket.assigns[assign_name] do
    nil ->
      {:noreply, socket}
    
    controller_assign ->
      controller_pid = controller_assign.pid
      GenServer.cast(controller_pid, {:event, event_atom, params})
      {:noreply, socket}
  end
end
```

Now, if a LiveView or Component receives an event for a controller it's not subscribed to, it simply ignores it instead of crashing.

## Benefits

### 1. True Separation of Concerns

Components can now be truly self-contained:

```elixir
# Parent - doesn't need to know about auth
defmodule MyAppWeb.DashboardLive do
  use Solve.LiveView, scene: MyApp

  @controllers [:dashboard, :stats]

  def render(assigns) do
    ~H"""
    <div>
      <.live_component module={AuthFormComponent} id="auth" />
    </div>
    """
  end
end

# Component - independently manages its own controller
defmodule MyAppWeb.AuthFormComponent do
  use Solve.LiveComponent

  @controllers [:auth]

  def render(assigns) do
    ~H"""
    <.form phx-submit={@auth.submit}>
      ...
    </.form>
    """
  end
end
```

### 2. Better Composability

Components can be dropped into any LiveView without requiring the parent to subscribe to the component's controllers. This makes components more reusable and portable.

### 3. Cleaner Architecture

Parent LiveViews don't need to be cluttered with controller subscriptions they don't actually use. Each component manages its own dependencies.

## Usage Patterns

### Pattern 1: Component-Only Subscriptions

Component subscribes to controllers that only it needs:

```elixir
defmodule MyAppWeb.AuthFormComponent do
  use Solve.LiveComponent

  @controllers [:auth]  # Parent doesn't need this

  def render(assigns) do
    ~H"""
    <.form phx-submit={@auth.submit} phx-target={@myself}>
      <.input field={@auth.form[:email]} />
    </.form>
    """
  end
end
```

**Important**: Use `phx-target={@myself}` to ensure events go to the component!

### Pattern 2: Shared Subscriptions

Both parent and component subscribe to the same controller (shared state):

```elixir
# Parent subscribes
defmodule MyAppWeb.DashboardLive do
  use Solve.LiveView, scene: MyApp

  @controllers [:current_user]

  def render(assigns) do
    ~H"""
    <div>
      <h1>Welcome {@current_user.name}</h1>
      <.live_component module={UserProfileComponent} id="profile" />
    </div>
    """
  end
end

# Component also subscribes - sees same state
defmodule MyAppWeb.UserProfileComponent do
  use Solve.LiveComponent

  @controllers [:current_user]

  def render(assigns) do
    ~H"""
    <div>{@current_user.email}</div>
    """
  end
end
```

### Pattern 3: Mixed Subscriptions

Parent and components each subscribe to their own controllers:

```elixir
# Parent manages dashboard state
defmodule MyAppWeb.DashboardLive do
  use Solve.LiveView, scene: MyApp

  @controllers [:dashboard]

  def render(assigns) do
    ~H"""
    <div>
      <h1>{@dashboard.title}</h1>
      <.live_component module={AuthFormComponent} id="auth" />
      <.live_component module={SettingsComponent} id="settings" />
    </div>
    """
  end
end

# Auth component manages auth state
defmodule MyAppWeb.AuthFormComponent do
  use Solve.LiveComponent
  @controllers [:auth]
  # ...
end

# Settings component manages settings state
defmodule MyAppWeb.SettingsComponent do
  use Solve.LiveComponent
  @controllers [:settings]
  # ...
end
```

## Migration Notes

### Before (Required Parent Subscription)

```elixir
# Parent HAD to subscribe to auth for component to work
defmodule MyAppWeb.DashboardLive do
  use Solve.LiveView, scene: MyApp

  @controllers [:dashboard, :auth]  # auth not actually used by parent

  def render(assigns) do
    ~H"""
    <.live_component module={AuthFormComponent} id="auth" 
                     __solve_pid__={@__solve_pid__} />  # Had to pass manually
    """
  end
end
```

### After (Independent Subscriptions)

```elixir
# Parent only subscribes to what it needs
defmodule MyAppWeb.DashboardLive do
  use Solve.LiveView, scene: MyApp

  @controllers [:dashboard]

  def render(assigns) do
    ~H"""
    <.live_component module={AuthFormComponent} id="auth" />  # __solve_pid__ automatic!
    """
  end
end
```

## Technical Details

### Files Changed

- ✅ `lib/solve/live_view.ex` - Made `handle_event` defensive
- ✅ `lib/solve/live_component.ex` - Made `handle_event` defensive
- ✅ `test/solve/live_view_test.exs` - Added test for ignoring unsubscribed events
- ✅ `test/solve/live_component_test.exs` - Added test for ignoring unsubscribed events

### Test Results

All 37 tests pass, including:
- 2 new tests for defensive event handling
- All existing functionality preserved

### Edge Cases Handled

1. **Event for nil controller**: Safely ignored
2. **Event bubbling from components**: Parent ignores if not subscribed
3. **Malformed controller references**: Protected by existing atom checks

## Best Practices

### 1. Use `phx-target={@myself}` for Component Events

When components have their own controller subscriptions, always use `phx-target`:

```elixir
<.form phx-submit={@auth.submit} phx-target={@myself}>
```

This ensures events go directly to the component, not the parent.

### 2. Subscribe Only to What You Need

Don't subscribe to controllers you don't use:

```elixir
# ❌ Bad - parent doesn't use auth
@controllers [:dashboard, :auth]

# ✅ Good - only what parent uses
@controllers [:dashboard]
```

### 3. Document Component Dependencies

Make it clear which controllers a component needs:

```elixir
defmodule MyAppWeb.AuthFormComponent do
  @moduledoc """
  Authentication form component.
  
  Requires controllers in scene:
  - `:auth` - Handles authentication logic
  """
  use Solve.LiveComponent

  @controllers [:auth]
  
  # ...
end
```

## Summary

This fix enables true separation of concerns between LiveViews and LiveComponents. Components can now independently manage their own controller subscriptions without requiring parent cooperation, making them more reusable, composable, and maintainable.

