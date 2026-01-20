# Multiple Scene Patterns - Implementation Summary

> **Note**: This document describes a previous macro-based implementation. The current implementation uses a simpler function-based approach where `scene/1` is a regular function that returns a map of controllers. See `lib/solve.ex` for the current implementation.

## Overview

Successfully implemented pattern matching support for multiple `scene` clauses in Solve, allowing users to define different controller configurations based on runtime parameters.

## Implementation

### Changes Made

1. **Modified `__using__` macro** (`lib/solve.ex`)
   - Changed from `use GenServer` to `@behaviour GenServer` to prevent default callback injection
   - Added `@scene_clauses` module attribute with `accumulate: true` to collect multiple scenes
   - Added `@before_compile Solve` hook

2. **Updated `scene` macro** (`lib/solve.ex`)
   - Changed to accumulate pattern/controllers pairs instead of generating code directly
   - Stores each scene as `{pattern_ast, controllers_map}` tuple
   - Validates dependency graph for each scene at compile time

3. **Added `__before_compile__` macro** (`lib/solve.ex`)
   - Generates `select_controllers/1` function with case-based pattern matching
   - Generates all GenServer callbacks (`init/1`, `handle_cast/2`, `handle_call/3`, etc.)
   - Moved all code generation from `scene` macro to `__before_compile__`

4. **Pattern Matching Implementation**
   - Uses case statement with runtime pattern matching
   - Matches params against each scene pattern in order
   - First matching pattern's controllers are used
   - Raises error if no pattern matches

### Key Technical Decisions

1. **Case Statement over Function Clauses**: Used a single `select_controllers/1` function with a case statement internally, rather than multiple function clauses, to avoid AST generation complexity.

2. **Behaviour instead of `use GenServer`**: Changed from `use GenServer` to `@behaviour GenServer` because GenServer's default implementations were overriding our custom callbacks defined in `__before_compile__`.

3. **AST Storage**: Store pattern AST and controllers map as tuples, then generate matching code at compile-time via `__before_compile__`.

### Files Created

- **`test/solve/multiple_scenes_test.exs`**: Comprehensive test suite with 9 tests covering:
  - Basic pattern matching (logged-in vs logged-out)
  - Exact value matching (role-based)
  - Nested structure matching (permissions)
  - Catch-all patterns
  - Edge cases

- **`MULTIPLE_SCENES_FEATURE.md`**: Complete feature documentation including:
  - Usage examples
  - Pattern matching features
  - Limitations
  - Use cases
  - Migration guide

- **`MULTIPLE_SCENES_IMPLEMENTATION.md`**: This file

### Files Modified

- **`lib/solve.ex`**: Major refactoring to support multiple scenes
- **`lib/solve.ex` @moduledoc**: Added documentation for multiple scenes feature

## Usage Example

```elixir
defmodule RealworldApp do
  use Solve

  # Scene for logged-out users
  scene %{current_user: nil} do
    controller(:auth, AuthController, params: fn _ -> :login end)
  end

  # Scene for logged-in users
  scene %{current_user: _user} do
    controller(:current_user, CurrentUserController)
    controller(:dashboard, DashboardController)
  end
end
```

## Test Results

All tests passing:
```
23 tests, 0 failures
```

Test breakdown:
- 14 existing tests (backward compatibility)
- 9 new tests for multiple scene patterns

## Backward Compatibility

✅ Fully backward compatible with existing single-scene code:

```elixir
# This still works exactly as before
defmodule MyApp do
  use Solve

  scene _params do
    controller(:counter, CounterController)
  end
end
```

## Limitations

### Variable Capture

The name `params` can be used in controller configurations (it's bound during AST evaluation), but other pattern variables cannot:

```elixir
# ✓ Works - params is explicitly bound during evaluation
scene params do
  controller(:user, UserController, params: fn _ -> params end)
end

# ✓ Works - can use params even with pattern matching
scene %{current_user: nil} = params do
  controller(:auth, AuthController, params: fn _ -> params[:live_action] end)
end

# ❌ Does NOT work - other captured variables aren't available
scene %{user: user} do
  controller(:current_user, UserController, params: fn _ -> user end)
end
```

**Reason**: Only `params` is explicitly bound during AST evaluation via `Code.eval_quoted(ast, params: app_params)`. Other pattern variables are bound during pattern matching but aren't available in the evaluated AST context.

**Workaround**: Use `params` to access any values from the runtime params map.

### Guards
Pattern guards are not currently supported:

```elixir
# Does NOT work:
scene %{count: n} when n > 10 do
  # ...
end
```

**Reason**: Guards would require more complex AST manipulation and evaluation logic.

**Workaround**: Use separate patterns for each case or conditional logic in controllers.

## Performance

- Pattern matching happens once at initialization time
- No runtime overhead after scene selection
- Same performance as single scene after startup

## Future Enhancements

Potential improvements for future versions:

1. **Variable Capture Support**: Allow captured variables to be used in controller configurations through more sophisticated AST binding

2. **Guard Support**: Add support for pattern guards like `when`

3. **Scene Composition**: Allow scenes to inherit/compose controller configurations

4. **Dynamic Scene Switching**: Support changing scenes at runtime without restarting

## Migration Path

For users wanting to adopt multiple scenes:

1. **Current single scene with conditionals**:
   ```elixir
   scene params do
     controller(:auth, AuthController, 
       params: fn _ -> if params[:current_user], do: false, else: true end)
   end
   ```

2. **Refactored to multiple scenes**:
   ```elixir
   scene %{current_user: nil} do
     controller(:auth, AuthController)
   end
   
   scene %{current_user: _} do
     controller(:dashboard, DashboardController)
   end
   ```

Benefits:
- Clearer intent
- Better maintainability
- Compile-time validation
- No conditional logic needed

## Related Files

- Implementation: `lib/solve.ex`
- Tests: `test/solve/multiple_scenes_test.exs`
- Documentation: `MULTIPLE_SCENES_FEATURE.md`
- LiveComponent: `lib/solve/live_component.ex` (from previous feature)

