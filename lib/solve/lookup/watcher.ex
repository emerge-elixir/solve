defmodule Solve.Lookup.Watcher do
  @moduledoc false
  use GenServer

  alias Solve.Lookup.Transport

  def start(owner), do: GenServer.start(__MODULE__, owner)
  def sync(pid, entries), do: GenServer.cast(pid, {:sync, entries})
  def retry(pid, app, token, reason), do: GenServer.cast(pid, {:retry, app, token, reason})

  def config! do
    opts = Application.get_env(:solve, :lookup_recovery, [])

    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "lookup_recovery must be a keyword list")

    initial = Keyword.get(opts, :initial_delay, 250)
    max_delay = Keyword.get(opts, :max_delay, 30_000)
    jitter = Keyword.get(opts, :jitter, 0.2)

    unless is_integer(initial) and initial > 0 and is_integer(max_delay) and
             max_delay >= initial and is_number(jitter) and jitter >= 0 and jitter < 1 do
      raise ArgumentError, "invalid lookup_recovery delays or jitter: #{inspect(opts)}"
    end

    %{initial: initial, max: max_delay, jitter: jitter, timeout: Transport.timeout!()}
  end

  def next_delay(delay, max_delay), do: min(delay * 2, max_delay)
  def delay(base, jitter), do: max(1, round(base * (1 - jitter * :rand.uniform())))

  @impl true
  def init(owner) do
    Process.flag(:trap_exit, true)
    :net_kernel.monitor_nodes(true)
    {:ok, %{owner: owner, monitor: Process.monitor(owner), entries: %{}, probe: nil}}
  end

  @impl true
  def handle_cast(:stop, state), do: {:stop, :normal, state}

  def handle_cast({:sync, wanted}, state) do
    state = prune(state, wanted)

    entries =
      Map.new(wanted, fn {app, entry} ->
        case state.entries[app] do
          %{token: token} = old when token == entry.token ->
            {app, %{old | probe_address: entry.probe_address}}

          _ ->
            {app,
             schedule(
               app,
               Map.merge(entry, %{
                 timer: nil,
                 timer_token: nil,
                 phase: :waiting,
                 last_started: nil,
                 expedited: false
               })
             )}
        end
      end)

    {:noreply, launch(%{state | entries: entries})}
  end

  def handle_cast({:retry, app, token, reason}, state) do
    case state.entries[app] do
      %{token: ^token, phase: :handshake} -> {:noreply, failed(state, app, reason)}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:retry, app, token, timer_token}, state) do
    case state.entries[app] do
      %{token: ^token, timer_token: ^timer_token, phase: :waiting} = entry ->
        entries =
          Map.put(state.entries, app, %{entry | timer: nil, timer_token: nil, phase: :ready})

        {:noreply, launch(%{state | entries: entries})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:probe_result, token, result}, %{probe: %{token: token} = probe} = state) do
    state = release_probe(state)

    state =
      case result do
        {:ok, pid} ->
          entry = state.entries[probe.app]
          send(state.owner, {:solve_lookup, :recover, {self(), probe.app, entry.token, pid}})
          put_in(state, [:entries, probe.app, :phase], :handshake)

        {:error, reason} ->
          failed(state, probe.app, reason)
      end

    {:noreply, launch(state)}
  end

  def handle_info({:probe_result, _, _}, state), do: {:noreply, state}

  def handle_info({:probe_timeout, token}, %{probe: %{token: token} = probe} = state) do
    state = release_probe(state)
    {:noreply, state |> failed(probe.app, {:exit, :timeout}) |> launch()}
  end

  def handle_info({:probe_timeout, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, reason}, %{probe: %{monitor: ref} = probe} = state) do
    state = release_probe(state)
    {:noreply, state |> failed(probe.app, {:exit, reason}) |> launch()}
  end

  def handle_info({:nodeup, host}, state) do
    # Only accelerate waiting entries. A nodeup caused by our own in-flight probe
    # must not schedule a second attempt, or reset exponential pacing.
    entries =
      Map.new(state.entries, fn {app, entry} ->
        if entry.phase == :waiting and not entry.expedited and
             host_for(entry.probe_address) == host do
          cancel_timer(entry.timer)

          {app, expedite(app, entry)}
        else
          {app, entry}
        end
      end)

    {:noreply, launch(%{state | entries: entries})}
  end

  def handle_info({:nodedown, _}, state), do: {:noreply, state}
  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.entries, fn {_, entry} -> cancel_timer(entry.timer) end)
    release_probe(state)
    :ok
  end

  defp expedite(app, entry) do
    elapsed =
      if entry.last_started,
        do: System.monotonic_time(:millisecond) - entry.last_started,
        else: entry.config.initial

    wait = max(1, entry.config.initial - elapsed)
    schedule(app, %{entry | expedited: true}, wait)
  end

  defp launch(%{probe: nil} = state) do
    case Enum.find(state.entries, fn {_, entry} -> entry.phase == :ready end) do
      nil -> state
      {app, entry} -> launch_probe(state, app, entry)
    end
  end

  defp launch(state), do: state

  defp launch_probe(state, app, entry) do
    watcher = self()
    token = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> send(watcher, {:probe_result, token, probe(entry)}) end,
        [:link, :monitor]
      )

    timer = Process.send_after(self(), {:probe_timeout, token}, entry.config.timeout)
    probe = %{pid: pid, monitor: monitor, timer: timer, token: token, app: app}

    entry = %{
      entry
      | phase: :probing,
        last_started: System.monotonic_time(:millisecond),
        expedited: false
    }

    state = put_in(state, [:entries, app], entry)
    %{state | probe: probe}
  end

  defp probe(entry) do
    deadline = Transport.deadline(entry.config.timeout)
    {:ok, Transport.probe!(entry.probe_address, deadline)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp failed(state, app, reason) do
    entry = state.entries[app]
    next = next_delay(entry.delay, entry.config.max)
    send(state.owner, {:solve_lookup, :failed, {self(), app, entry.token, reason, next}})
    entry = schedule(app, %{entry | delay: next})
    put_in(state, [:entries, app], entry)
  end

  defp schedule(app, entry), do: schedule(app, entry, delay(entry.delay, entry.config.jitter))

  defp schedule(app, entry, wait) do
    token = make_ref()
    timer = Process.send_after(self(), {:retry, app, entry.token, token}, wait)
    %{entry | timer: timer, timer_token: token, phase: :waiting}
  end

  defp prune(state, wanted) do
    state =
      case state.probe do
        nil ->
          state

        probe ->
          if same_token?(state.entries[probe.app], wanted[probe.app]),
            do: state,
            else: release_probe(state)
      end

    Enum.each(state.entries, fn {app, entry} ->
      unless same_token?(entry, wanted[app]), do: cancel_timer(entry.timer)
    end)

    state
  end

  defp same_token?(%{token: token}, %{token: token}), do: true
  defp same_token?(_, _), do: false

  defp release_probe(%{probe: nil} = state), do: state

  defp release_probe(%{probe: probe} = state) do
    cancel_timer(probe.timer)
    Process.unlink(probe.pid)
    Process.exit(probe.pid, :kill)
    Process.demonitor(probe.monitor, [:flush])
    %{state | probe: nil}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
  defp host_for(pid) when is_pid(pid), do: node(pid)
  defp host_for({:global, _}), do: nil
  defp host_for({_name, host}) when is_atom(host), do: host
  defp host_for(_), do: nil
end
