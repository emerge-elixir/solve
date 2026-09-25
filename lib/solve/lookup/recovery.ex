defmodule Solve.Lookup.Recovery do
  @moduledoc false

  alias Solve.Lookup.Watcher

  @key {Solve.Lookup, :recovery}
  @watcher_tag :solve_lookup_watcher_down

  def state,
    do: Process.get(@key, %{bindings: %{}, watcher: nil, restart: nil, notifications: %{}})

  def get_binding(app), do: state().bindings[app]
  def bindings, do: state().bindings

  def config_for(pid) do
    Enum.find_value(bindings(), fn {_, b} -> if b.pid == pid, do: b.config end)
  end

  def status(app) do
    case get_binding(app) do
      nil -> :unknown
      %{phase: :connected, pid: pid} -> {:connected, pid}
      %{phase: phase, reason: reason} -> {phase, reason}
    end
  end

  def request(app, target, kind) do
    case get_binding(app) do
      %{phase: phase} = b when phase != :connected ->
        unless Map.has_key?(b.targets, target) do
          put(app, %{b | targets: Map.put(b.targets, target, kind), token: make_ref()})
          sync()
        end

        pending!(app)

      _ ->
        :ok
    end
  end

  def pending!(app) do
    case status(app) do
      {phase, reason} when phase in [:reconnecting, :unavailable] ->
        exit({{phase, reason}, {Solve.Lookup, :acquire, [app]}})

      _ ->
        :ok
    end
  end

  def visible?(pid, target) do
    Enum.any?(bindings(), fn {_, b} ->
      b.pid == pid and b.phase == :connected and Map.has_key?(b.targets, target)
    end)
  end

  def remember(app, pid, target, kind, config) do
    old = get_binding(app)

    retain_previous(old, pid)
    b = binding_for(old, pid, config)
    put(app, %{b | targets: Map.put(b.targets, target, kind)})
  end

  def failed_acquisition(app, pid, target, kind, reason, config) do
    old = get_binding(app)

    retain_previous(old, pid)
    b = binding_for(old, pid, config)
    b = %{b | pid: pid || b.pid, targets: Map.put(b.targets, target, kind)}
    put(app, disconnected(app, b, reason))
    sync()
  end

  def invalidate(pid, reason) do
    Enum.each(bindings(), fn {app, b} ->
      if b.pid == pid, do: put(app, after_down(app, b, reason))
    end)

    sync()
  end

  def cancel(app, pid, target) do
    Enum.each(bindings(), fn {address, b} ->
      if (pid != nil and b.pid == pid) or (pid == nil and address === app) do
        cancel_binding(address, b, target)
      end
    end)

    sync()
  end

  defp cancel_binding(address, b, target) do
    targets = Map.delete(b.targets, target)

    cond do
      map_size(targets) == 0 ->
        delete(address)

      targets == b.targets ->
        :ok

      true ->
        phase =
          if b.phase == :unavailable and not is_pid(address) and b.candidate,
            do: :reconnecting,
            else: b.phase

        put(address, %{b | targets: targets, token: make_ref(), phase: phase})
    end
  end

  def candidate(watcher, app, token, pid) do
    case current(watcher, app, token) do
      nil ->
        nil

      b ->
        b = %{b | pid: pid, candidate: pid}
        put(app, b)
        b
    end
  end

  def complete(app) do
    b = get_binding(app)
    put(app, %{b | phase: :connected, reason: nil, delay: b.config.initial, candidate: nil})
    sync()
  end

  def terminal(app, reason) do
    b = get_binding(app)
    put(app, %{b | phase: :unavailable, reason: reason, token: make_ref()})
    sync()
  end

  def retry(app, reason) do
    b = get_binding(app)

    case state().watcher do
      {watcher, _} -> Watcher.retry(watcher, app, b.token, {:exit, reason})
      nil -> sync()
    end
  end

  def failed(watcher, app, token, failure, delay) do
    case current(watcher, app, token) do
      nil ->
        :ok

      b ->
        reason = failure_reason(failure)

        cond do
          terminal_failure?(app, failure) ->
            terminal(app, reason)

          missing?(reason) and is_pid(b.candidate) ->
            {:retire, b.candidate, :noproc}

          true ->
            put(app, %{b | reason: reason, delay: delay})
        end
    end
  end

  def watcher_down(ref, pid) do
    case state().watcher do
      {^pid, ^ref} ->
        s = state()
        token = make_ref()
        delay = s.bindings |> Map.values() |> Enum.map(& &1.delay) |> Enum.max(fn -> 250 end)
        timer = Process.send_after(self(), {:solve_lookup, :restart, token}, delay)
        bindings = Map.new(s.bindings, fn {app, b} -> {app, %{b | token: make_ref()}} end)
        store(%{s | watcher: nil, bindings: bindings, restart: {token, timer}})

      _ ->
        :ok
    end
  end

  def restart(token) do
    case state().restart do
      {^token, _timer} ->
        store(%{state() | restart: nil})
        sync()

      _ ->
        :ok
    end
  end

  def take_notifications do
    s = state()
    store(%{s | notifications: %{}})

    Enum.flat_map(s.notifications, fn {app, expected} ->
      current = status(app)
      if phase(current) == phase(expected), do: [{app, current}], else: []
    end)
  end

  # Live-name rebinding must not discard the old PID's subscription ownership.
  defp retain_previous(%{pid: old_pid, phase: :connected} = old, pid)
       when is_pid(pid) and old_pid != pid do
    retained = get_binding(old_pid) || fresh(old_pid, old.config)
    put(old_pid, %{retained | targets: Map.merge(retained.targets, old.targets)})
  end

  defp retain_previous(_, _), do: :ok
  defp binding_for(nil, pid, config), do: fresh(pid, config)
  defp binding_for(b, nil, _config), do: b
  defp binding_for(%{pid: pid} = b, pid, _config), do: b
  defp binding_for(_b, pid, config), do: fresh(pid, config)

  defp fresh(pid, config) do
    %{
      pid: pid,
      targets: %{},
      phase: :connected,
      reason: nil,
      token: make_ref(),
      config: config,
      delay: config.initial,
      candidate: nil
    }
  end

  defp after_down(app, b, reason) do
    next = disconnected(app, b, reason)
    if is_pid(app) and reason != :noconnection, do: %{next | phase: :unavailable}, else: next
  end

  defp disconnected(app, b, reason) do
    phase = if is_pid(app) and dead?(reason), do: :unavailable, else: :reconnecting
    %{b | phase: phase, reason: reason, token: make_ref(), candidate: nil}
  end

  defp dead?(:noconnection), do: false
  defp dead?({:noproc, _}), do: true
  defp dead?(:noproc), do: true
  defp dead?(reason) when is_atom(reason), do: reason not in [:timeout, :nodedown]
  defp dead?(_), do: false
  defp missing?({:noproc, _}), do: true
  defp missing?(_), do: false
  defp failure_reason({_kind, reason}), do: reason
  defp terminal_failure?(_app, {:error, _}), do: true
  defp terminal_failure?(app, {:exit, reason}), do: is_pid(app) and missing?(reason)
  defp terminal_failure?(_, _), do: false

  defp current(watcher, app, token) do
    case {state().watcher, get_binding(app)} do
      {{^watcher, _}, %{token: ^token, phase: :reconnecting} = b} -> b
      _ -> nil
    end
  end

  defp put(app, b) do
    previous = status(app)
    s = state()
    store(%{s | bindings: Map.put(s.bindings, app, b)})
    next = status(app)

    unless phase(previous) == phase(next) or (previous == :unknown and b.phase == :connected) do
      s = state()
      if map_size(s.notifications) == 0, do: send(self(), {:solve_lookup, :notify, nil})
      store(%{s | notifications: Map.put(s.notifications, app, next)})
    end
  end

  defp phase({:connected, pid}), do: {:connected, pid}
  defp phase({phase, _}), do: phase
  defp phase(:unknown), do: :unknown

  defp delete(app) do
    s = state()

    store(%{
      s
      | bindings: Map.delete(s.bindings, app),
        notifications: Map.delete(s.notifications, app)
    })
  end

  defp store(s) do
    if map_size(s.bindings) == 0 and s.watcher == nil and s.restart == nil,
      do: Process.delete(@key),
      else: Process.put(@key, s)

    :ok
  end

  defp sync do
    s = state()
    pending = Map.filter(s.bindings, fn {_, b} -> b.phase == :reconnecting end)

    cond do
      map_size(pending) == 0 -> stop_watcher(s)
      s.restart != nil -> :ok
      true -> sync_watcher(s, pending)
    end
  end

  defp sync_watcher(s, pending) do
    {pid, _ref} = watcher = s.watcher || start_watcher()
    store(%{s | watcher: watcher})

    entries =
      Map.new(pending, fn {app, b} ->
        {app,
         %{token: b.token, config: b.config, delay: b.delay, probe_address: b.candidate || app}}
      end)

    Watcher.sync(pid, entries)
  end

  defp start_watcher do
    {:ok, pid} = Watcher.start(self())
    {pid, Process.monitor(pid, tag: @watcher_tag)}
  end

  defp stop_watcher(s) do
    if s.restart, do: Process.cancel_timer(elem(s.restart, 1))

    if s.watcher do
      {pid, ref} = s.watcher
      Process.demonitor(ref, [:flush])
      # Asynchronous stop: no caller-side wait for discovery or shutdown.
      GenServer.cast(pid, :stop)
    end

    store(%{s | watcher: nil, restart: nil})
  end
end
