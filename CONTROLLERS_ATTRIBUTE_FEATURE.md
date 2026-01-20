# @controllers Attribute Feature

This document describes the new `@controllers` module attribute feature added to both `Solve.LiveView` and `Solve.LiveComponent`.

## Overview

The `@controllers` attribute provides a declarative, concise way to subscribe to controllers without needing to define an `init/1` function. This reduces boilerplate for the common case of static controller subscriptions.

## Features

### 1. Two Subscription Methods

Both `Solve.LiveView` and `Solve.LiveComponent` now support two ways to subscribe to controllers:

#### A. Using @controllers (Recommended for static subscriptions)

```elixir
defmodule MyAppWeb.DashboardLive do
  use Solve.LiveView, scene: MyApp

  # Simple list - assign name matches controller name
  @controllers [:lemons, :water]

  # Or keyword list - custom assign names
  @controllers [my_lemons: :lemons, my_water: :water]

  def render(assigns) do
    ~H"""
    <h1>Lemons: {@lemons.count}</h1>
    """
  end
end
```

#### B. Using init/1 (For dynamic subscriptions)

```elixir
defmodule MyAppWeb.DashboardLive do
  use Solve.LiveView, scene: MyApp

  def init(params) do
    base = %{lemons: :lemons}
    
    if params[:show_water] do
      Map.put(base, :water, :water)
    else
      base
    end
  end

  def render(assigns) do
    ~H"""
    <h1>Lemons: {@lemons.count}</h1>
    """
  end
end
```

### 2. Precedence Rules

When both `@controllers` and `init/1` are defined:
- If `init/1` returns a **non-empty map**, it takes precedence
- If `init/1` returns an **empty map** (default), `@controllers` is used

This allows for flexible configuration where you can:
- Use `@controllers` for the default case
- Override with `init/1` when needed based on runtime conditions

### 3. Supported Formats

The `@controllers` attribute supports two formats:

#### List Format (Simple)
```elixir
@controllers [:auth, :profile, :settings]
```
- Assign name matches controller name
- Most common use case
- Clean and concise

#### Keyword List Format (Custom Names)
```elixir
@controllers [my_auth: :auth_controller, user: :current_user]
```
- Custom assign names mapped to controller names
- Useful when you want different naming conventions
- Provides flexibility for specific use cases

## Implementation Details

### Technical Approach

1. **Module Attribute Registration**: Both macros register `@controllers` as a module attribute during compilation
2. **Before Compile Hook**: A `__before_compile__` macro captures the `@controllers` value and generates a `__controllers__/0` function
3. **Runtime Access**: During mount/update, the code checks `init/1` first, then falls back to calling `__controllers__()`
4. **Normalization**: The `Solve.LiveView.normalize_controllers/1` function converts both formats to a standard map

### Benefits

1. **Less Boilerplate**: No need to define `init/1` for simple cases
2. **Declarative**: Clear, at-a-glance understanding of controller subscriptions
3. **Backward Compatible**: Existing code using `init/1` continues to work
4. **Flexible**: Supports both static and dynamic subscription patterns
5. **Type Safe**: Compile-time attribute checking

## Files Changed

### Core Implementation
- ✅ `lib/solve/live_view.ex` - Added @controllers support, __before_compile__ hook, normalize_controllers/1
- ✅ `lib/solve/live_component.ex` - Added @controllers support, __before_compile__ hook

### Tests
- ✅ `test/solve/live_view_test.exs` - Added 3 test cases for @controllers
- ✅ `test/solve/live_component_test.exs` - Added 3 test cases for @controllers

### Documentation
- ✅ Updated moduledoc in `lib/solve/live_view.ex` with examples
- ✅ Updated moduledoc in `lib/solve/live_component.ex` with examples
- ✅ Updated `examples/live_component_example.md` with @controllers examples

## Test Results

All 35 tests pass:
- 14 tests for LiveView (including 3 new @controllers tests)
- 10 tests for LiveComponent (including 3 new @controllers tests)
- 11 tests for other features

## Usage Examples

### LiveView Example

```elixir
defmodule MyAppWeb.AuthLive do
  use Solve.LiveView, scene: MyApp

  @controllers [:auth]

  def render(assigns) do
    ~H"""
    <.form phx-submit={@auth.submit}>
      <.input field={@auth.form[:email]} />
      <button>{@auth.cta}</button>
    </.form>
    """
  end
end
```

### LiveComponent Example

```elixir
defmodule MyAppWeb.AuthFormComponent do
  use Solve.LiveComponent

  @controllers [:auth]

  def render(assigns) do
    ~H"""
    <div>
      <.form phx-submit={@auth.submit} phx-target={@myself}>
        <.input field={@auth.form[:email]} />
        <button>{@auth.cta}</button>
      </.form>
    </div>
    """
  end
end
```

### Mixed Approach Example

```elixir
defmodule MyAppWeb.DashboardLive do
  use Solve.LiveView, scene: MyApp

  @controllers [:lemons, :water]

  # Override @controllers conditionally
  def init(params) do
    if params[:admin_mode] do
      %{lemons: :lemons, water: :water, admin: :admin_controller}
    else
      %{}  # Use @controllers
    end
  end

  def render(assigns) do
    ~H"""
    <h1>Dashboard</h1>
    """
  end
end
```

## Migration Guide

### Before (Old Way)

```elixir
defmodule MyAppWeb.DashboardLive do
  use Solve.LiveView, scene: MyApp

  def init(_params) do
    %{
      lemons: :lemons,
      water: :water,
      settings: :settings
    }
  end
end
```

### After (New Way)

```elixir
defmodule MyAppWeb.DashboardLive do
  use Solve.LiveView, scene: MyApp

  @controllers [:lemons, :water, :settings]
end
```

**Note**: The old way still works! This is purely additive functionality.

## Additional Improvements

As part of this feature, we also:

1. **Made `__solve_pid__` implicit** - LiveViews now automatically inject `__solve_pid__` into `live_component` calls, so users don't need to manually pass it
2. **Improved documentation** - Added clearer examples and explanations about when to use each approach
3. **Enhanced error messages** - Better guidance when controllers aren't found

## Future Enhancements

Potential future improvements:
- Compile-time validation that referenced controllers exist in the scene
- IDE tooling support for autocomplete of controller names
- Migration tool to automatically convert `init/1` to `@controllers` where applicable

