# Solve UI Refactoring - Summary of Changes

## Overview
Refactored Solve to support mount-time params, updated controller initialization, and implemented transparent access to both controller events and exposed state.

## Key Changes

### 1. New `Solve.ControllerAssign` Wrapper Struct
**File:** `lib/solve/controller_assign.ex`

- Created a new struct that implements the `Access` behavior
- Provides transparent access to both controller events and exposed state
- Events and exposed data are kept separate internally but accessed uniformly
- When a key is accessed, it first checks if it's an event, then falls back to exposed state
- Supports any type of exposed value (maps, structs, primitives)

**Benefits:**
- Clean separation between events and data
- No naming conflicts between events and state fields
- Transparent access: `@current_user.first_name` (dot notation) and `@current_user[:update_profile]` (bracket notation for events)
- Enumerable support: Can iterate over lists exposed by controllers using `for item <- @items do`

### 2. Updated Controller Behavior
**File:** `lib/solve/controller.ex`

**Changes:**
- `init/1` → `init/2`: Now receives both `dependencies` and `params`
- `expose/2` return type changed from `map()` to `any()` to support returning structs or primitives
- Added `@callback init(dependencies :: map(), params :: map()) :: map()`
- Controllers now store `params` in their server state

**Example:**
```elixir
defmodule CurrentUserController do
  use Solve.Controller, events: [:update_profile, :logout]

  @impl true
  def init(_dependencies, params) do
    %{user: params[:user], session_data: %{}}
  end

  @impl true
  def expose(state, _dependencies) do
    # Can return just the user struct
    state.user
  end
end
```

### 3. Updated App with Scene Params
**File:** `lib/solve/app.ex`

**Changes:**
- `scene do ... end` → `scene params do ... end`
- Controllers can now accept a `params:` option with a function
- App accepts params during initialization via `start_link(params: %{...})`
- Added `evaluate_params_fn/3` to evaluate controller params functions

**Example:**
```elixir
defmodule MyApp do
  use Solve

  scene params do
    # params variable is available in the params function
    controller(:current_user, CurrentUserController,
      params: fn _deps -> %{user: params[:user]} end
    )
    
    controller(:settings, SettingsController,
      dependencies: [:current_user],
      params: fn deps -> %{user_id: deps[:current_user].id} end
    )
  end
end
```

**Note:** The `params` variable from the `scene params do` block is automatically available inside params functions through binding during AST evaluation.

### 4. Updated UI with `mount_to_solve` Callback
**File:** `lib/solve/ui.ex`

**Changes:**
- Added `mount_to_solve/3` callback for custom mount logic
- `ensure_app_started/3` now accepts params
- Mount process now uses `ControllerAssign` wrapper for all controller subscriptions
- Controllers that are not alive result in `nil` assigns (no longer raise errors)

**Example:**
```elixir
defmodule MyAppWeb.DashboardLive do
  use Solve.LiveView, scene: MyApp

  def mount_to_solve(_params, session, _socket) do
    user = get_current_user(session)
    %{current_user: user}
  end

  def init(_params) do
    %{
      current_user: :current_user,
      counter: :counter
    }
  end

  def render(assigns) do
    ~H"""
    <div>
      <%= if @current_user do %>
        <h1>Welcome {@current_user.first_name}!</h1>
        <button phx-click={@current_user.logout}>Logout</button>
      <% else %>
        <p>No user session</p>
      <% end %>
      
      <p>Count: {@counter.count}</p>
      <button phx-click={@counter.increment}>+</button>
    </div>
    """
  end
end
```

### 5. Updated Tests
**Files:** `test/solve/ui_test.exs`, `test/solve/dynamic_controller_test.exs`

- Updated all controller `init` callbacks to accept two parameters
- Updated all `scene` blocks to accept params argument
- Fixed test assertions to access exposed state via `.exposed` property
- Changed behavior test: controllers not alive now result in `nil` instead of raising

## Migration Guide

### For Controller Authors

**Before:**
```elixir
def init(dependencies) do
  %{count: 0}
end
```

**After:**
```elixir
@impl true
def init(dependencies, params) do
  initial_count = Map.get(params, :initial_count, 0)
  %{count: initial_count}
end
```

### For App Definitions

**Before:**
```elixir
scene do
  controller(:counter, CounterController)
end
```

**After:**
```elixir
scene params do
  controller(:counter, CounterController,
    params: fn _deps -> %{initial_count: params[:start_value] || 0} end
  )
end
```

### For UI Definitions

**Before:**
```elixir
use Solve.LiveView, scene: MyApp.Scene

def init(_params) do
  %{counter: :counter}
end

def render(assigns) do
  ~H"""
  <p>{@counter.count}</p>
  """
end
```

**After:**
```elixir
use Solve.LiveView, scene: MyApp.Scene

def mount_to_solve(_params, session, _socket) do
  user = get_current_user(session)
  %{current_user: user}
end

def init(_params) do
  %{counter: :counter}
end

def render(assigns) do
  ~H"""
  <%= if @counter do %>
    <p>{@counter.count}</p>
  <% end %>
  """
end
```

## Benefits

1. **Session Integration**: UIs can now pass session data to controllers via `mount_to_solve`
2. **Flexible Expose**: Controllers can expose any type (not just maps), including structs
3. **Clean Separation**: Events and exposed state are kept separate internally, avoiding naming conflicts
4. **Transparent Access**: The `ControllerAssign` wrapper provides uniform access to both events and state
5. **Nil Safety**: Controllers that aren't running result in `nil` assigns, making conditional rendering natural
6. **Type Safety**: Better type definitions with explicit callbacks for `init/2` and `expose/2`

## Test Results

All tests passing:
```
.......
Finished in 1.2 seconds (0.00s async, 1.2s sync)
7 tests, 0 failures
```

No linter errors or warnings.

## Bug Fixes

### Params Variable Scoping in Scene Block

**Issue:** When using `params` inside a params function like `params: fn _ -> params end`, the variable was undefined at runtime.

**Fix:** The `params` variable from the scene block is now properly bound when evaluating params function AST. The app's params are passed through the entire controller initialization chain:
- `start_controller_if_ready` → `start_controller` → `evaluate_params_fn`
- When evaluating AST, params are bound: `Code.eval_quoted(ast, params: app_params)`

This allows users to safely reference the `params` variable inside their params functions.

### Enumerable Protocol for ControllerAssign

**Issue:** When a controller exposes a list directly (e.g., `expose(state, _) do state.articles end`), users couldn't iterate over it in templates with `for article <- @articles`.

**Fix:** Implemented the `Enumerable` protocol for `ControllerAssign` that delegates to the exposed value's `Enumerable` implementation.

**Usage:**
```elixir
# Controller
def expose(state, _dependencies) do
  state.articles  # Returns a list
end

# Template
<%= for article <- @articles do %>
  <div>{article.title}</div>
<% end %>
```

This works for any enumerable exposed value (lists, maps, ranges, streams, etc.).

