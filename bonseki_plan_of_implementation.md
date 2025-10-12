# Bonseki - Implementation Plan

## Overview

Bonseki is an Elixir library that provides a declarative state management architecture for Phoenix LiveView applications. It decouples state management from UI through a controller-based pattern, enabling clean separation of concerns and dependency management between state controllers.

## Architecture Components

### 1. Bonseki.App (GenServer)
**Purpose**: Central coordinator that manages controllers, resolves dependencies, and routes state updates to UIs.

**Responsibilities**:
- Start and supervise controllers based on dependency graph
- Validate no cyclic dependencies exist
- Route events from UIs to appropriate controllers
- Track subscribed UIs
- Notify UIs when controller state changes
- Call `expose/1` on controllers and their dependents when state changes

**State Structure**:
```elixir
%{
  controllers: %{
    LemonController => %{
      pid: pid,
      module: LemonController,
      dependencies: [],
      dependents: [LemonadeController],  # reverse deps
      on_when: true,
      status: :running
    },
    # ...
  },
  uis: [
    %{pid: ui_pid, subscriptions: %{lemons: LemonController, water: WaterController}}
  ],
  dependency_graph: %{} # For cycle detection
}
```

**API**:
- `start_link(scene_config)` - Start the app with scene configuration
- `dispatch_event(app_pid, controller_module, event_name, params)` - Route event to controller
- `register_ui(app_pid, ui_pid, subscriptions)` - Register a UI with its subscriptions
- `unregister_ui(app_pid, ui_pid)` - Cleanup when UI terminates

**Macro (`use Bonseki.App`)**:
- Provides `scene/1` macro to define controllers with dependencies
- Compiles scene configuration at compile-time
- Validates dependency graph for cycles
- Generates child_spec and supervision tree

### 2. Bonseki.Controller (GenServer)
**Purpose**: State container that handles domain logic and events.

**Responsibilities**:
- Maintain independent state
- Handle event callbacks
- Provide `init/1` for initial state (default: `%{}`)
- Provide `expose/1` to expose state to UIs (default: returns full state)
- Register with parent App on startup

**Macro (`use Bonseki.Controller, events: [...]`)**:
- Defines event handlers as `handle_call` callbacks
- Generates `definition/0` that returns event list
- Validates that all declared events have corresponding function definitions
- Provides default `init/1` and `expose/1` if not defined

**Event Handler Pattern**:
```elixir
def increment(state) do
  # Return new state
  %{state | count: state.count + 1}
end
```

**GenServer Callbacks**:
- `init/1` - Call user-defined `init/1`, register with App
- `handle_call({:event, event_name, params}, _from, state)` - Route to event handler
- `handle_call(:expose, _from, state)` - Call user-defined `expose/1`

### 3. Bonseki.UI (LiveView)
**Purpose**: Phoenix LiveView that subscribes to controller state and handles UI events.

**Responsibilities**:
- Subscribe to controllers via `subscribe(ControllerModule, :assign_name)`
- Handle state updates from App via `handle_info`
- Send events to App when user interacts
- Automatically update assigns when controller state changes

**Macro (`use Bonseki.UI, app: SomeApp`)**:
- Sets up LiveView boilerplate
- Injects `subscribe/2` helper
- Generates `mount/3` that calls user-defined `init/1`
- Generates `handle_event/3` that dispatches to App
- Generates `handle_info/2` for state updates

**Subscription Mechanism**:
```elixir
def init(_params) do
  subscribe(LemonController, :lemons)
  subscribe(WaterController, :water)
end
```

This registers the UI with the App and creates assigns with both state and events:
```elixir
@lemons = %{
  number_of: 5,
  increment: "dispatch-event:LemonController:increment",
  decrement: "dispatch-event:LemonController:decrement"
}
```

**Event Handling**:
User clicks: `<button phx-click={@lemons.increment}>` 
→ `handle_event("dispatch-event:LemonController:increment", params, socket)`
→ App receives event
→ Controller handles event
→ App sends updates via `handle_info({:bonseki_update, :lemons, new_state}, socket)`

## Implementation Phases

### Phase 1: Core Infrastructure
**Files to create**:
- `lib/bonseki.ex` - Main module with public API
- `lib/bonseki/controller.ex` - Controller macro and behavior
- `lib/bonseki/app.ex` - App GenServer and macro
- `lib/bonseki/ui.ex` - UI LiveView macro

**Deliverables**:
1. `Bonseki.Controller` macro that:
   - Accepts `events: [...]` option
   - Generates `use GenServer`
   - Provides default `init/1` returning `%{}`
   - Provides default `expose/1` returning full state
   - Validates event handlers exist at compile-time
   - Generates `definition/0` returning events list

2. Basic GenServer structure for controllers
3. Testing infrastructure

### Phase 2: Dependency Graph & App GenServer
**Deliverables**:
1. `Bonseki.App` GenServer implementation:
   - State management for controllers and UIs
   - Controller supervision
   
2. `Bonseki.App` macro with `scene/1`:
   - Parse controller definitions
   - Build dependency graph
   - Detect cyclic dependencies (topological sort)
   - Generate supervision tree

3. Dependency resolution:
   - Start controllers in correct order
   - Respect `on_when` conditions
   - Track dependent controllers (reverse dependencies)

### Phase 3: Event Routing & State Propagation
**Deliverables**:
1. Event dispatching from UI → App → Controller:
   - `handle_call({:dispatch_event, controller, event, params}, from, state)`
   - Route to controller's event handler
   - Track state changes

2. State propagation Controller → App → UIs:
   - Call `expose/1` on changed controller
   - Call `expose/1` on dependent controllers
   - Send `handle_info` messages to subscribed UIs
   - Only notify UIs subscribed to changed controllers

### Phase 4: UI Integration (LiveView)
**Deliverables**:
1. `Bonseki.UI` macro:
   - Generate `mount/3` calling user `init/1`
   - Implement `subscribe/2` helper
   - Store subscriptions in socket assigns
   - Register with App on mount

2. Event handler generation:
   - Generate `handle_event/3` for dispatching to App
   - Parse event string format: `"dispatch-event:Controller:event"`
   - Handle async/sync event responses

3. State update handling:
   - Generate `handle_info({:bonseki_update, assign_name, new_state}, socket)`
   - Merge controller state with event functions
   - Update socket assigns

### Phase 5: Advanced Features
**Deliverables**:
1. Controller lifecycle hooks:
   - `on_start/1` - Called when controller starts
   - `on_stop/1` - Called when controller stops
   - `on_dependency_ready/2` - Called when dependency becomes available

2. Conditional controller startup:
   - Implement `on_when` function evaluation
   - Re-evaluate when dependencies change
   - Dynamic controller start/stop

3. Error handling & supervision:
   - Controller crash recovery
   - App crash recovery
   - UI disconnection handling

### Phase 6: Developer Experience
**Deliverables**:
1. Compile-time validations:
   - Verify all events have handlers
   - Check controller module existence
   - Validate dependency graph

2. Runtime debugging:
   - Introspection API for controller state
   - Dependency graph visualization
   - Event tracing

3. Documentation & examples:
   - Comprehensive moduledocs
   - Usage examples
   - Migration guides

## Technical Details

### Dependency Graph Resolution
Use topological sort to:
1. Detect cycles (throw error if found)
2. Determine controller start order
3. Build reverse dependency map for propagation

**Algorithm**:
```elixir
defp resolve_dependencies(controllers) do
  # Build adjacency list
  graph = build_graph(controllers)
  
  # Topological sort with cycle detection
  case topological_sort(graph) do
    {:ok, order} -> {:ok, order}
    {:error, :cycle} -> raise "Cyclic dependency detected in controllers"
  end
end
```

### Event Encoding in UI
Events are encoded as special strings that the generated `handle_event/3` can parse:
- Format: `"bonseki:#{controller_module}:#{event_name}"`
- Parsed by macro-generated handler
- Dispatched to App synchronously

### State Propagation Strategy
When a controller's state changes:
1. Get list of dependent controllers from reverse dependency map
2. Call `expose/1` on changed controller and all dependents
3. For each subscribed UI:
   - Check which subscriptions are affected
   - Send `handle_info` for each affected subscription
   - UI merges state with event functions

### Subscription Data Structure
```elixir
# In UI socket assigns
%{
  __bonseki_subscriptions__: %{
    lemons: %{
      controller: LemonController,
      events: [:increment, :decrement],
      state: %{number_of: 5}
    }
  },
  lemons: %{
    number_of: 5,
    increment: "bonseki:LemonController:increment",
    decrement: "bonseki:LemonController:decrement"
  }
}
```

## API Examples

### Defining a Controller
```elixir
defmodule MyApp.CounterController do
  use Bonseki.Controller, events: [:increment, :decrement, :reset]
  
  def init(_params) do
    %{count: 0}
  end
  
  def increment(state) do
    %{state | count: state.count + 1}
  end
  
  def decrement(state) do
    %{state | count: state.count - 1}
  end
  
  def reset(_state) do
    %{count: 0}
  end
  
  def expose(state) do
    %{count: state.count, is_positive: state.count > 0}
  end
end
```

### Defining an App with Dependencies
```elixir
defmodule MyApp.App do
  use Bonseki.App
  
  scene do
    controller(LemonController)
    controller(WaterController)
    controller(SugarController)
    
    controller(LemonadeController,
      dependencies: [LemonController, WaterController, SugarController],
      on_when: fn deps_state ->
        # Only start if we have ingredients
        deps_state[LemonController].count > 0
      end
    )
  end
end
```

### Defining a UI
```elixir
defmodule MyAppWeb.DashboardLive do
  use Bonseki.UI, app: MyApp.App
  
  def init(_params) do
    subscribe(LemonController, :lemons)
    subscribe(WaterController, :water)
    subscribe(LemonadeController, :lemonades)
  end
  
  def render(assigns) do
    ~H"""
    <div>
      <h1>Lemons: {@lemons.count}</h1>
      <button phx-click={@lemons.increment}>Add Lemon</button>
      <button phx-click={@lemons.decrement}>Remove Lemon</button>
      
      <h1>Water: {@water.count}</h1>
      <button phx-click={@water.increment}>Add Water</button>
      
      <h1>Lemonades: {@lemonades.count}</h1>
    </div>
    """
  end
end
```

## Testing Strategy

### Unit Tests
- Test individual controllers in isolation
- Test dependency graph resolution
- Test cycle detection
- Test event routing logic

### Integration Tests
- Test full flow: UI → App → Controller → UI
- Test multiple UIs subscribing to same controller
- Test dependent controller updates
- Test conditional controller startup (`on_when`)

### Property Tests
- Generate random dependency graphs and verify no cycles
- Test event propagation consistency
- Test state synchronization across UIs

## Performance Considerations

1. **State Propagation**: Only notify UIs subscribed to changed controllers
2. **Dependency Updates**: Use reverse dependency map for O(1) lookup
3. **Event Routing**: Direct GenServer calls, no PubSub overhead
4. **Memory**: Each controller maintains independent state, no global state
5. **Concurrency**: Controllers can process events concurrently, App coordinates

## Error Handling

1. **Controller Crash**: App restarts controller, notifies UIs of state loss
2. **App Crash**: Supervision tree restarts App and all controllers
3. **UI Crash**: App removes UI from registry on monitor down
4. **Dependency Failure**: Dependent controllers can handle via `on_when`

## Migration Path

For existing apps:
1. Extract state management from LiveViews into Controllers
2. Define App with controller dependencies
3. Update LiveViews to use Bonseki.UI
4. Add subscriptions in place of assign initialization
5. Replace event handlers with controller dispatches

## Future Enhancements

1. **Persistence**: Automatic controller state persistence
2. **Time Travel**: Record state changes for debugging
3. **Multi-tenancy**: Scope controllers per user/session
4. **Distributed**: Support for distributed controller coordination
5. **DevTools**: Browser extension for visualizing state and events
6. **Middleware**: Pluggable event/state transformation pipeline
7. **Testing Helpers**: Utilities for testing controller interactions

## File Structure

```
bonseki/
├── lib/
│   ├── bonseki.ex                      # Main module, public API
│   ├── bonseki/
│   │   ├── app.ex                      # App GenServer + macro
│   │   ├── controller.ex               # Controller macro + behavior
│   │   ├── ui.ex                       # UI LiveView macro
│   │   ├── dependency_graph.ex         # Graph resolution utilities
│   │   ├── event_encoder.ex            # Event string encoding/decoding
│   │   └── subscription.ex             # Subscription management helpers
├── test/
│   ├── bonseki/
│   │   ├── app_test.exs
│   │   ├── controller_test.exs
│   │   ├── ui_test.exs
│   │   ├── dependency_graph_test.exs
│   │   └── integration_test.exs
└── mix.exs
```

## Summary

Bonseki provides a clean architecture for managing state in Phoenix LiveView applications by:
- **Decoupling state from UI** through controllers
- **Managing dependencies** between state containers
- **Coordinating updates** through a central App
- **Simplifying LiveViews** to pure rendering + subscriptions

This architecture scales well for complex applications with interdependent state, provides clear boundaries for testing, and maintains type safety through compile-time validations.

