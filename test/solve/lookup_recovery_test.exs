Code.require_file("../support/lookup_recovery_helper.exs", __DIR__)

defmodule Solve.LookupRecoveryTest do
  use ExUnit.Case, async: false

  alias Solve.Lookup
  alias Solve.LookupRecoveryFixture.App

  defmodule SlowRegistry do
    def whereis_name(pid) do
      Process.sleep(30)
      pid
    end
  end

  setup do
    previous =
      Map.new([:lookup_timeout, :lookup_recovery], &{&1, Application.get_env(:solve, &1)})

    Application.put_env(:solve, :lookup_timeout, 60)
    Application.put_env(:solve, :lookup_recovery, initial_delay: 10, max_delay: 40, jitter: 0)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:solve, key)
        {key, value} -> Application.put_env(:solve, key, value)
      end)
    end)

    :ok
  end

  test "cold name resolution and snapshot share a deadline" do
    app = App.boot(nil)
    on_exit(fn -> stop(app) end)
    :sys.suspend(app)

    assert {:timeout, {GenServer, :call, [^app, _, remaining]}} =
             catch_exit(Lookup.solve({:via, SlowRegistry, app}, :source))

    assert remaining <= 30
    :sys.resume(app)
    assert :ok = Lookup.unsubscribe({:via, SlowRegistry, app}, :source)
  end

  test "unknown targets allocate no intent and malformed budgets leave warm reads intact" do
    app = App.boot(nil)
    on_exit(fn -> stop(app) end)
    assert Lookup.solve(app, :unknown) == nil
    assert cache() == %{apps: %{}, aliases: %{}}
    assert Lookup.solve(app, :source).value == 1

    for invalid <- [0, -1, :infinity, nil] do
      Application.put_env(:solve, :lookup_timeout, invalid)
      assert Lookup.solve(app, :source).value == 1
      assert_raise ArgumentError, fn -> Lookup.solve(app, :other) end
    end
  end

  defp cache, do: Process.get({Lookup, :cache}, %{apps: %{}, aliases: %{}})

  defp stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end
end
