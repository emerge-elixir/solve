# Multiple Scene Patterns

## Overview

Solve supports defining multiple `scene/1` function clauses with pattern matching, allowing you to configure different sets of controllers based on the runtime parameters passed to your Solve instance.

## Basic Usage

```elixir
defmodule RealworldApp do
  use Solve

  @impl true
  # Scene for logged-out users
  def scene(%{current_user: nil}) do
    %{auth: {AuthController, params: fn _ -> :login end}}
  end

  # Scene for logged-in users
  def scene(%{current_user: _user}) do
    %{current_user: {CurrentUserController, params: fn _ -> :logged_in end}}
  end
end
```

When you start the Solve instance, it will match the params against each scene pattern in order and use the first matching scene:

```elixir
# Will use the first scene (logged-out)
{:ok, pid} = RealworldApp.start_link(params: %{current_user: nil})

# Will use the second scene (logged-in)
{:ok, pid} = RealworldApp.start_link(params: %{current_user: %{id: 1, name: "Alice"}})
```

## Pattern Matching Features

### Exact Value Matching

```elixir
@impl true
def scene(%{role: :admin}) do
  %{admin_panel: AdminController}
end

def scene(%{role: :moderator}) do
  %{mod_panel: ModeratorController}
end
```

### Catch-All Patterns

```elixir
@impl true
def scene(%{role: :admin}) do
  %{admin: AdminController}
end

def scene(_) do
  # Matches any other params
  %{guest: GuestController}
end
```

### Nested Structures

```elixir
@impl true
def scene(%{user: %{permissions: %{admin: true}}}) do
  %{admin: AdminController}
end

def scene(%{user: %{permissions: _}}) do
  %{user: UserController}
end

def scene(_) do
  %{guest: GuestController}
end
```

## Pattern Matching Order

Scenes are matched in the order they are defined, similar to Elixir function clauses. The first pattern that matches will be used:

```elixir
defmodule MyApp do
  use Solve

  @impl true
  # Matches first if role is :admin
  def scene(%{role: :admin}) do
    %{admin: AdminController}
  end

  # Matches if role is anything else (but not nil)
  def scene(%{role: _}) do
    %{user: UserController}
  end

  # Matches if no role key exists or params is any other value
  def scene(_) do
    %{guest: GuestController}
  end
end
```

## Error Handling

If no scene pattern matches the provided params, a runtime error will be raised:

```elixir
# If none of your patterns match this:
RealworldApp.start_link(params: %{unexpected: :value})
# => ** (RuntimeError) No scene pattern matched params: %{unexpected: :value}
```

## Using Params in Controller Configurations

### Accessing Full Params

You can use `params` in your controller configurations to access the runtime params:

```elixir
@impl true
def scene(params) do
  %{
    user: {UserController, params: fn _ -> params end}  # ✓ Works - passes full params
  }
end

# Or with pattern matching:
@impl true
def scene(%{current_user: nil} = params) do
  %{
    auth: {AuthController, params: fn _ -> params[:live_action] end}  # ✓ Works - accesses specific key
  }
end
```

### Pattern Variable Capture

Since `scene/1` is a regular function, you can use any pattern variables directly:

```elixir
@impl true
def scene(%{user: user}) do
  %{
    current_user: {UserController, params: fn _ -> user end}  # ✓ Works - user is available
  }
end

# You can also access params if you need the full map:
@impl true
def scene(%{user: _} = params) do
  %{
    current_user: {UserController, params: fn _ -> params[:user] end}  # ✓ Also works
  }
end
```

### Guards

Pattern guards work as expected with regular function definitions:

```elixir
@impl true
def scene(%{count: n}) when n > 10 do
  %{high_count: HighCountController}
end

def scene(%{count: n}) when n <= 10 do
  %{low_count: LowCountController}
end
```

## Use Cases

### Authentication States

```elixir
defmodule MyApp do
  use Solve

  @impl true
  def scene(%{current_user: nil}) do
    %{
      auth: AuthController,
      public_content: PublicController
    }
  end

  def scene(%{current_user: _user}) do
    %{
      current_user: CurrentUserController,
      dashboard: DashboardController,
      notifications: NotificationsController
    }
  end
end
```

### Feature Flags

```elixir
defmodule MyApp do
  use Solve

  @impl true
  def scene(%{features: %{beta: true}}) do
    %{
      beta_features: BetaController,
      analytics: AnalyticsController
    }
  end

  def scene(_) do
    %{standard_features: StandardController}
  end
end
```

### User Roles

```elixir
defmodule MyApp do
  use Solve

  @impl true
  def scene(%{user: %{role: :admin}}) do
    %{
      admin_panel: AdminController,
      user_management: UserManagementController,
      system_settings: SystemController
    }
  end

  def scene(%{user: %{role: :moderator}}) do
    %{
      mod_panel: ModController,
      content_moderation: ModerationController
    }
  end

  def scene(%{user: _}) do
    %{user_dashboard: DashboardController}
  end

  def scene(_) do
    %{guest: GuestController}
  end
end
```

## Migration Guide

### From Single Scene

If you currently have a single scene with conditional controller starting:

```elixir
# Old approach
defmodule MyApp do
  use Solve

  @impl true
  def scene(params) do
    %{
      auth: {AuthController,
        params: fn _ -> if params[:current_user], do: false, else: true end
      },
      dashboard: {DashboardController,
        params: fn _ -> if params[:current_user], do: true, else: false end
      }
    }
  end
end
```

You can refactor to multiple scene clauses:

```elixir
# New approach
defmodule MyApp do
  use Solve

  @impl true
  def scene(%{current_user: nil}) do
    %{auth: AuthController}
  end

  def scene(%{current_user: _}) do
    %{dashboard: DashboardController}
  end
end
```

Benefits:
- Clearer intent
- Better pattern matching validation
- Easier to understand and maintain
- No need for conditional logic in params functions

## Implementation Details

- `scene/1` is a regular function with pattern matching
- Pattern matching happens at runtime when `init/1` calls `scene(params)`
- The first matching function clause's controllers are instantiated
- Full support for Elixir pattern matching features (guards, nested patterns, etc.)
- Validates controller dependency graph at runtime

## Testing

The test suite includes comprehensive coverage of multiple scene patterns:

```bash
mix test test/solve/multiple_scenes_test.exs
```

Tests cover:
- Basic pattern matching (logged-in vs logged-out)
- Exact value matching (admin, moderator, guest roles)
- Nested structure matching (permissions)
- Catch-all patterns
- Pattern matching order

