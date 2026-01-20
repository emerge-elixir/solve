defmodule Solve.ControllerAssign do
  @moduledoc """
  A wrapper struct that provides transparent access to both controller events
  and exposed state without merging them.

  When you access a key (e.g., `@current_user.first_name`), it first checks if
  it's an event, then falls back to the exposed state. This allows events and
  exposed data to coexist without conflicts.

  ## Examples

      # Controller exposes a user struct
      %User{first_name: "Alice", last_name: "Smith"}

      # Events are [:update_profile, :logout]

      # In a LiveView template:
      @current_user.first_name       # => "Alice" (from exposed state)
      @current_user.update_profile   # => "solve:current_user:update_profile" (event string)

      # In a LiveComponent template:
      @current_user.first_name       # => "Alice" (from exposed state)
      @current_user.update_profile   # => JS command with automatic targeting

  ## Automatic Event Targeting in Components

  When used in a LiveComponent, event accessors automatically return
  `Phoenix.LiveView.JS.push/2` commands that target the component. This means
  you don't need to manually add `phx-target={@myself}` - events automatically
  stay within the component.
  """

  @behaviour Access

  defstruct [:pid, :events, :exposed, :myself]

  @type t :: %__MODULE__{
          pid: pid(),
          events: map(),
          exposed: any(),
          myself: any()
        }

  @doc """
  Creates a new ControllerAssign.

  ## Parameters
    - `pid`: The controller PID
    - `events`: List of event atoms
    - `exposed`: The value returned by the controller's expose/2 function
    - `assign_name`: The name used for this assignment in the UI
    - `myself`: (Optional) The component ID for automatic event targeting
  """
  def new(pid, events, exposed, assign_name, myself \\ nil) do
    events_map =
      Enum.into(events, %{}, fn event ->
        event_name = "solve:#{assign_name}:#{event}"

        # When in a component, return JS command that targets the component
        # Otherwise, return plain event string
        event_value =
          if myself do
            Phoenix.LiveView.JS.push(event_name, target: myself)
          else
            event_name
          end

        {event, event_value}
      end)

    %__MODULE__{
      pid: pid,
      events: events_map,
      exposed: exposed,
      myself: myself
    }
  end

  @impl Access
  def fetch(%__MODULE__{events: events, exposed: exposed}, key) do
    # First check if it's an event
    case Map.fetch(events, key) do
      {:ok, _value} = result ->
        result

      :error ->
        # Fall back to exposed state
        cond do
          # If exposed is a map, fetch from it
          is_map(exposed) and not is_struct(exposed) ->
            Map.fetch(exposed, key)

          # If exposed is a struct, use Map.fetch (works for structs too)
          is_struct(exposed) ->
            Map.fetch(exposed, key)

          # Otherwise, can't fetch
          true ->
            :error
        end
    end
  end

  @impl Access
  def get_and_update(%__MODULE__{} = assign, key, fun) do
    # This is primarily for reading in LiveView; updates should go through events
    current =
      case fetch(assign, key) do
        {:ok, value} -> value
        :error -> nil
      end

    case fun.(current) do
      {get_value, new_value} ->
        # We don't actually update the struct as it's read-only from UI perspective
        # Events should be used for mutations
        {get_value, put(assign, key, new_value)}

      :pop ->
        {current, assign}
    end
  end

  @impl Access
  def pop(%__MODULE__{} = assign, key) do
    current =
      case fetch(assign, key) do
        {:ok, value} -> value
        :error -> nil
      end

    {current, assign}
  end

  defp put(%__MODULE__{} = assign, _key, _value) do
    # Since this is read-only from UI perspective, just return unchanged
    assign
  end

  defimpl Enumerable do
    def count(%Solve.ControllerAssign{exposed: exposed}) do
      Enumerable.count(exposed)
    end

    def member?(%Solve.ControllerAssign{exposed: exposed}, element) do
      Enumerable.member?(exposed, element)
    end

    def reduce(%Solve.ControllerAssign{exposed: exposed}, acc, fun) do
      Enumerable.reduce(exposed, acc, fun)
    end

    def slice(%Solve.ControllerAssign{exposed: exposed}) do
      Enumerable.slice(exposed)
    end
  end
end
