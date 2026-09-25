defmodule Solve.Lookup.Transport do
  @moduledoc false

  def timeout! do
    case Application.get_env(:solve, :lookup_timeout, 5_000) do
      timeout when is_integer(timeout) and timeout > 0 ->
        timeout

      value ->
        raise ArgumentError, "lookup_timeout must be a positive integer, got: #{inspect(value)}"
    end
  end

  def deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  def remaining!(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> remaining
      _ -> exit({:timeout, {Solve.Lookup, :acquire, []}})
    end
  end

  # Reserved name forms must precede the generic two-atom remote-name form.
  def remote_name?({:global, _}), do: false
  def remote_name?({name, host}) when is_atom(name) and is_atom(host), do: host != node()
  def remote_name?(_), do: false

  def resolve!(pid, _deadline) when is_pid(pid), do: pid
  def resolve!({:global, _} = app, _deadline), do: named!(app, GenServer.whereis(app))
  def resolve!({:via, _, _} = app, _deadline), do: named!(app, GenServer.whereis(app))

  def resolve!({name, host} = app, deadline) when is_atom(name) and is_atom(host) do
    pid =
      if host == node(),
        do: Process.whereis(name),
        else: rpc!(host, Process, :whereis, [name], deadline)

    named!(app, pid)
  end

  def resolve!(app, _deadline), do: named!(app, GenServer.whereis(app))

  defp named!(_app, pid) when is_pid(pid), do: pid
  defp named!(app, _), do: missing!(app)
  defp missing!(app), do: exit({:noproc, {Solve.Lookup, :resolve_app, [app]}})

  defp rpc!(host, module, function, args, deadline) do
    case :rpc.call(host, module, function, args, remaining!(deadline)) do
      {:badrpc, reason} -> exit({{:badrpc, reason}, {Solve.Lookup, :resolve_app, [host]}})
      result -> result
    end
  end
end
