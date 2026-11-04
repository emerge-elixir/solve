defmodule Solve.EventPayloadTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias Solve.Lookup

  defmodule Receiver do
    use Solve.Controller, events: [:remember]

    @impl true
    def init(_params, _dependencies), do: %{payload: nil, unexpected: []}

    def remember(payload, state), do: %{state | payload: payload}

    def handle_info(message, state), do: %{state | unexpected: [message | state.unexpected]}
  end

  defmodule App do
    use Solve

    @impl true
    def controllers, do: [controller!(name: :receiver, module: Receiver)]
  end

  setup do
    app = start_supervised!(App)
    receiver = Lookup.solve(app, :receiver)
    {pid, _message} = Lookup.event(receiver, :remember)
    %{receiver: receiver, pid: pid}
  end

  test "appended payloads reach the declared event handler", context do
    for {argument, payload} <- [
          {1.6, %{phase: :move, x: 12.5, y: -4.0}},
          {{:item, 42}, %{x: 1.0, y: 2.0}},
          {%{id: 42}, {:sample, 9}},
          {nil, false},
          {false, nil}
        ] do
      {pid, message} = Lookup.event(context.receiver, :remember, argument)
      send(pid, Tuple.insert_at(message, tuple_size(message), payload))
      assert_payload(pid, {argument, payload})
    end
  end

  test "Lookup dispatch accepts appended payloads and attaches them to fixed arguments",
       context do
    argument = {:item, 42}
    payload = %{start: %{x: 10.0, y: 20.0}, end: %{x: 90.0, y: 22.0}, duration_ms: 180.0}
    binding = Lookup.event(context.receiver, :remember, argument)

    assert :ok = Lookup.dispatch(binding, payload)
    assert_payload(context.pid, {argument, payload})

    {pid, message} = binding
    assert :ok = Lookup.dispatch({pid, Tuple.insert_at(message, tuple_size(message), nil)})
    assert_payload(pid, {argument, nil})
  end

  test "payload-free, runtime-only and fixed-only events keep their existing shapes", context do
    binding = Lookup.event(context.receiver, :remember)
    assert :ok = Lookup.dispatch(binding)
    assert_payload(context.pid, %{})

    payload = %{x: 12.5, y: 20.0}
    assert :ok = Lookup.dispatch(binding, payload)
    assert_payload(context.pid, payload)

    for argument <- [{:item, 42}, %{id: 42}, nil, false] do
      assert :ok = Lookup.dispatch(Lookup.event(context.receiver, :remember, argument))
      assert_payload(context.pid, argument)
    end
  end

  test "undeclared appended-payload events remain reserved from handle_info", context do
    log =
      capture_log(fn ->
        send(context.pid, {:solve_event, :unknown, :argument, %{x: 1.0, y: 2.0}})
        assert_payload(context.pid, nil)
      end)

    assert log =~ "discarding undeclared Solve controller event :unknown"
  end

  defp assert_payload(pid, payload) do
    # A public synchronous read also orders the preceding send; no polling needed.
    assert Solve.Controller.subscribe(pid) == %{payload: payload, unexpected: []}
  end
end
