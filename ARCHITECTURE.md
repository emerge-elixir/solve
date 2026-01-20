# Solve Architecture

## Current Architecture (Post-Refactoring)

```
┌─────────────────────────────────────────────────────────────┐
│                       Solve (GenServer)                      │
│  • Manages controller lifecycle                              │
│  • Resolves dependency graph                                 │
│  • Provides controller PID lookup                            │
└─────────────────────────────────────────────────────────────┘
                    │ start/stop
                    │ get_controller_pid
                    ▼
┌─────────────────────────────────────────────────────────────┐
│                    Controllers (GenServers)                  │
│  • Manage state                                              │
│  • Handle events from LiveViews and LiveComponents           │
│  • Track dependents (LiveViews, LiveComponents, Controllers) │
│  • Send updates directly to dependents                       │
└─────────────────────────────────────────────────────────────┘
         │                              ▲
         │ {:solve_update, ...}         │ {:event, ...}
         │                              │
         ▼                              │
┌─────────────────────────────────────────────────────────────┐
│              LiveViews (Solve.LiveView)                      │
│  • Subscribe directly to controllers                         │
│  • Send events directly to controllers                       │
│  • Receive state updates directly from controllers           │
│  • Store Solve PID for LiveComponents                        │
└─────────────────────────────────────────────────────────────┘
         │ renders
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│           LiveComponents (Solve.LiveComponent)               │
│  • Access parent's Solve instance via __solve_pid__          │
│  • Subscribe directly to controllers                         │
│  • Send events directly to controllers                       │
│  • Receive state updates directly from controllers           │
│  • Multiple instances share same controller state            │
└─────────────────────────────────────────────────────────────┘
```

## Controller-to-Controller Dependencies

```
┌──────────────────┐
│ SourceController │ 
│   value: 5       │
└──────────────────┘
         │
         │ State changes
         │ notify_dependents()
         ▼
┌──────────────────┐       {:refresh_dependencies}
│DependentController│◄──────────────────────────────
│  computed: 50     │
└──────────────────┘
         │
         │ {:solve_update, ...}
         ▼
    ┌────────────┐
    │  LiveView  │
    └────────────┘
```

## Message Flow

### LiveView Event → Controller → LiveView Update

1. **LiveView sends event to controller:**
   ```elixir
   GenServer.cast(controller_pid, {:event, :increment, %{}})
   ```

2. **Controller processes event and notifies dependents:**
   ```elixir
   # In controller
   new_state = increment(state, params)
   notify_dependents(server_state, new_state)
   ```

3. **LiveView receives update:**
   ```elixir
   # In LiveView handle_info
   {:solve_update, :counter, :counter, %{count: 1}}
   ```

### Source Controller → Dependent Controller → LiveView

1. **Source controller state changes**
2. **Source notifies dependent controllers:**
   ```elixir
   GenServer.cast(dependent_pid, :refresh_dependencies)
   ```

3. **Dependent controller refreshes and recomputes:**
   ```elixir
   dependencies = get_dependencies_state(...)
   new_exposed_state = expose(state, dependencies)
   notify_dependents(...)
   ```

4. **LiveViews subscribed to dependent receive updates**

## LiveComponent Integration

LiveComponents provide reusable UI components that subscribe to controllers from the parent LiveView's Solve instance:

```
┌─────────────────────┐
│  Solve.LiveView     │
│  (Parent)           │
│                     │
│  Solve Instance ────┼─────┐
│  Controllers        │     │
└─────────────────────┘     │
         │                  │
         │ renders           │ accesses via __solve_pid__
         │                  │
         ▼                  │
┌─────────────────────┐     │
│  LiveComponent 1    │◄────┘
│  (id: "form-1")     │
│                     │
│  Subscribes to:     │
│  - :auth            │────┐
└─────────────────────┘    │
         │                 │
         │ shares state    │
         ▼                 │
┌─────────────────────┐    │
│  LiveComponent 2    │    │
│  (id: "form-2")     │    │ same controller
│                     │    │
│  Subscribes to:     │    │
│  - :auth            │────┤
└─────────────────────┘    │
                           │
        ┌──────────────────┘
        ▼
┌─────────────────────┐
│  AuthController     │
│  (shared)           │
└─────────────────────┘
```

### LiveComponent Features

- **Shared Controllers**: Access parent's Solve instance controllers
- **Shared State**: Multiple instances share the same controller state
- **Zero Props**: Components need only an `id`, all data comes from controllers
- **Params in init**: `init/1` receives all assigns (including `id`)
- **Reusability**: Can be used across different LiveViews

## Key Design Principles

1. **Direct Communication**: No intermediary routing through Solve
2. **Process Monitoring**: Controllers monitor their dependents, clean up on termination
3. **Dependency Management**: Solve notifies controllers about their dependents at startup
4. **Single Responsibility**: 
   - Solve: Lifecycle management
   - Controller: State + dependency propagation
   - LiveView: Page-level presentation + routing
   - LiveComponent: Reusable UI components

## Benefits

- ⚡ **Performance**: Fewer GenServer hops
- 🔌 **Decoupling**: Clear separation of concerns
- 📈 **Scalability**: No central bottleneck
- 🎯 **Clarity**: Each module has one job
- 🔄 **Real-time**: Direct updates enable instant reactivity

