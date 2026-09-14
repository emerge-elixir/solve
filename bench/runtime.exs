# Run with: mix run bench/runtime.exs
# Timings are diagnostics, not CI thresholds. No benchmark dependencies required.

defmodule SolveBench.Item do
  use Solve.Controller, events: [:set]
  @impl true
  def init(_params, _dependencies), do: %{value: 0}
  def set(value), do: %{value: value}
end

defmodule SolveBench.Sum do
  use Solve.Controller
  @impl true
  def init(_params, _dependencies), do: nil
  @impl true
  def expose(_state, %{items: items}, _params) do
    %{sum: Enum.reduce(items, 0, fn {_, item}, acc -> acc + item.value end)}
  end
end

defmodule SolveBench.App do
  use Solve
  @impl true
  def controllers do
    items =
      controller!(
        name: :items,
        module: SolveBench.Item,
        variant: :collection,
        collect: fn %{app_params: %{size: size}} -> Enum.map(1..size, &{&1, true}) end
      )

    sums =
      [:sum1, :sum2, :sum3, :sum4]
      |> Enum.with_index(1)
      |> Enum.map(fn {name, index} ->
        controller!(
          name: name,
          module: SolveBench.Sum,
          params: fn %{app_params: %{fanout: fanout}} -> index <= fanout end,
          dependencies: [items: collection(:items)]
        )
      end)

    [items | sums]
  end
end

defmodule SolveBench do
  def run do
    IO.puts("Collection.new/1: median of five samples (microseconds)")

    for size <- [1_000, 2_000, 4_000] do
      entries = Enum.map(1..size, &{&1, %{value: 0}})
      samples = for _ <- 1..5, do: elem(:timer.tc(fn -> Solve.Collection.new(entries) end), 0)
      IO.inspect({size, Enum.at(Enum.sort(samples), 2)}, label: "bulk build")
    end

    IO.puts("Runtime: one accepted child update, including collection snapshot fan-out")
    for size <- [1_000, 2_000, 4_000], fanout <- [1, 4], do: measure(size, fanout)
  end

  defp measure(size, fanout) do
    {startup_us, {:ok, app}} =
      :timer.tc(fn ->
        SolveBench.App.start_link(
          name: nil,
          params: %{size: size, fanout: fanout}
        )
      end)

    try do
      Solve.Lookup.collection(app, :items)
      :sys.statistics(app, true)

      {warm_us, _} =
        :timer.tc(fn -> for _ <- 1..100, do: Solve.Lookup.collection(app, :items) end)

      {:ok, warm_stats} = :sys.statistics(app, :get)

      child = Solve.controller_pid(app, {:items, 1})

      sums =
        [:sum1, :sum2, :sum3, :sum4]
        |> Enum.take(fanout)
        |> Enum.map(&Solve.controller_pid(app, &1))

      :sys.statistics(app, false)
      :sys.statistics(app, true)

      {update_us, _} =
        :timer.tc(fn ->
          Solve.Controller.dispatch(child, :set, 1)
          deadline = System.monotonic_time(:millisecond) + 10_000
          await_sums(sums, deadline)
        end)

      {:ok, stats} = :sys.statistics(app, :get)

      IO.inspect(
        %{
          items: size,
          dependents: fanout,
          startup_us: startup_us,
          warm_100_reads_us: warm_us,
          warm_coordinator_calls: warm_stats[:messages_in],
          update_us: update_us,
          coordinator_reductions: stats[:reductions],
          coordinator_messages: stats[:messages_in]
        },
        label: "runtime"
      )
    after
      GenServer.stop(app)
      Solve.Lookup.cleanup()
    end
  end

  defp await_sums(pids, deadline) do
    cond do
      Enum.all?(pids, &(Solve.Controller.subscribe(&1).sum == 1)) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "fan-out did not converge"

      true ->
        Process.sleep(1)
        await_sums(pids, deadline)
    end
  end
end

SolveBench.run()
