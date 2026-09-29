defmodule Solve.ChildSpecTest do
  use ExUnit.Case, async: true

  defmodule App do
    use Solve

    @impl Solve
    def controllers, do: []
  end

  defmodule CustomApp do
    use Solve

    def child_spec(opts) do
      super(opts)
      |> Map.merge(%{id: :custom_app, restart: :temporary})
    end

    @impl Solve
    def controllers, do: []
  end

  test "uses the app module as the default name" do
    assert App.child_spec([]) == %{
             id: {App, App},
             start: {App, :start_link, [[]]},
             type: :worker,
             restart: :permanent
           }
  end

  test "uses the configured name and preserves all start options" do
    for name <- [__MODULE__.NamedApp, {:global, {__MODULE__, :app}}, nil] do
      opts = [name: name, params: %{value: 42}, controller_start_timeout: 100]

      assert App.child_spec(opts) == %{
               id: {App, name},
               start: {App, :start_link, [opts]},
               type: :worker,
               restart: :permanent
             }
    end
  end

  test "can start an app from its module in a supervision tree" do
    pid = start_supervised!(App)

    assert Process.whereis(App) == pid
    assert Solve.controller_pid(pid, :missing) == nil
  end

  test "can supervise multiple named instances of the same app" do
    first_name = __MODULE__.FirstApp
    second_name = __MODULE__.SecondApp

    first = start_supervised!({App, name: first_name})
    second = start_supervised!({App, name: second_name})

    assert first != second
    assert Process.whereis(first_name) == first
    assert Process.whereis(second_name) == second
  end

  test "can override the generated child spec" do
    opts = [name: __MODULE__.CustomName]

    assert CustomApp.child_spec(opts) == %{
             id: :custom_app,
             start: {CustomApp, :start_link, [opts]},
             type: :worker,
             restart: :temporary
           }

    pid = start_supervised!({CustomApp, opts})
    assert Process.whereis(opts[:name]) == pid
  end
end
