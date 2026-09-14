defmodule Solve.ReadmeTest.Examples do
  @moduledoc false

  # Compile the README itself, not hand-maintained copies of its examples.
  def blocks(readme, title) do
    [_, section] = String.split(readme, "## #{title}\n", parts: 2)
    section = section |> String.split("\n## ", parts: 2) |> hd()

    Regex.scan(~r/```elixir\n(.*?)\n```/s, section, capture: :all_but_first)
    |> List.flatten()
  end

  def modules(readme, title) do
    blocks(readme, title)
    |> Enum.filter(&String.starts_with?(String.trim_leading(&1), "defmodule "))
  end

  def compile!(namespace, snippets) do
    definitions =
      Enum.flat_map(snippets, fn code ->
        code = String.replace(code, "MyApp.", "#{inspect(namespace)}.")

        case Code.string_to_quoted!(code) do
          {:__block__, _, forms} -> forms
          form -> [form]
        end
      end)

    # Later chapters replace earlier definitions of the same module.
    definitions =
      definitions
      |> Enum.reverse()
      |> Enum.uniq_by(fn {:defmodule, _, [name, _body]} -> Macro.to_string(name) end)
      |> Enum.reverse()

    Code.compile_quoted({:__block__, [], definitions}, "README.md")
  end

  def app(spec) do
    """
    defmodule MyApp.App do
      use Solve
      @impl Solve
      def controllers, do: [#{spec}]
    end
    """
  end
end

defmodule Solve.ReadmeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  alias Solve.ReadmeTest.Basic
  alias Solve.ReadmeTest.Callbacks
  alias Solve.ReadmeTest.Collections
  alias Solve.ReadmeTest.Counter
  alias Solve.ReadmeTest.Examples
  alias Solve.ReadmeTest.Exposed
  alias Solve.ReadmeTest.Greeting
  alias Solve.ReadmeTest.Negative
  alias Solve.ReadmeTest.Presenter
  alias Solve.ReadmeTest.Timers

  @readme_path Path.expand("../../README.md", __DIR__)
  @external_resource @readme_path
  @readme File.read!(@readme_path)

  basic = Examples.modules(@readme, "Writing an application")
  exposed = Examples.modules(@readme, "Exposing data")
  counter = Examples.modules(@readme, "Events I encounter change me")

  dependencies =
    Examples.modules(@readme, "There might be others and we may depend on each other")

  callbacks = Examples.modules(@readme, "By calling back I can reach anyone")
  timers = Examples.modules(@readme, "In a nutshell I am a GenServer")
  collections = Examples.modules(@readme, "In a collective I retain my identity")
  presenter = Examples.modules(@readme, "Looking up data inside of Solve application")

  for {namespace, snippets} <- [
        {__MODULE__.Basic, basic},
        {__MODULE__.Exposed, basic ++ exposed},
        {__MODULE__.Counter, counter},
        {__MODULE__.Greeting, counter ++ Enum.take(dependencies, 2)},
        {__MODULE__.Negative, counter ++ dependencies},
        {__MODULE__.Callbacks, callbacks},
        {__MODULE__.Timers, callbacks ++ timers},
        {__MODULE__.Collections, [Enum.at(callbacks, 1)] ++ collections},
        {__MODULE__.Presenter, [Enum.at(callbacks, 1)] ++ collections ++ presenter}
      ] do
    Examples.compile!(namespace, snippets)
  end

  for {spec, index} <-
        @readme |> Examples.blocks("I have params therefore I am") |> Enum.with_index() do
    Examples.compile!(Module.concat(__MODULE__, "Params#{index}"), basic ++ [Examples.app(spec)])
  end

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "installation dependency matches the current project version" do
    [code] = Examples.blocks(@readme, "Installation")
    [{_, _}] = Code.compile_string("defmodule #{__MODULE__}.Installation do\n#{code}\nend")
    assert [solve: requirement] = apply(__MODULE__.Installation, :deps, [])
    assert Version.match?(Mix.Project.config()[:version], requirement)
  end

  test "hello example starts under its module name and exposes state" do
    app = start_app(Basic.App)
    assert Process.whereis(Basic.App) == app
    assert Solve.subscribe(app, :hello) == %{hello: "Hello"}
  end

  test "expose customizes the public map" do
    app = start_app(Exposed.App)
    assert Solve.subscribe(app, :hello) == %{exposed: "Hello World"}
  end

  test "omitted and truthy params start hello; false params leave it off" do
    for {module, expected} <- [
          {__MODULE__.Params0.App, %{hello: "Hello"}},
          {__MODULE__.Params1.App, %{hello: "Hello"}},
          {__MODULE__.Params2.App, nil}
        ] do
      app = start_app(module)
      assert Solve.subscribe(app, :hello) == expected
      assert is_pid(Solve.controller_pid(app, :hello)) == (expected != nil)
    end
  end

  test "counter dispatch, nil payloads, exposed values and update envelopes" do
    app = start_app(Counter.App)
    assert Solve.subscribe(app, :counter) == %{count: 0}
    assert :ok = Solve.dispatch(app, :counter, :increment, nil)
    assert Solve.subscribe(app, :counter) == %{count: 1}
    assert_update(app, :counter, %{count: 1})
    Solve.dispatch(app, :counter, :increment, 25)
    assert Solve.subscribe(app, :counter) == %{count: 26}
    assert_update(app, :counter, %{count: 26})
    Solve.dispatch(app, :counter, :decrement, nil)
    assert Solve.subscribe(app, :counter) == %{count: 25}
    Solve.dispatch(app, :counter, :decrement, 25)
    assert Solve.subscribe(app, :counter) == %{count: 0}
  end

  @tag :capture_log
  test "invalid counter payload publishes nil and restarts with fresh state" do
    app = start_app(Counter.App)
    Solve.subscribe(app, :counter)
    Solve.dispatch(app, :counter, :increment, nil)
    assert_update(app, :counter, %{count: 1})
    Solve.dispatch(app, :counter, :increment, 25)
    assert_update(app, :counter, %{count: 26})
    previous = Solve.controller_pid(app, :counter)
    Solve.dispatch(app, :counter, :increment, "Invalid value")
    assert_update(app, :counter, nil)
    assert_update(app, :counter, %{count: 0})
    assert Solve.controller_pid(app, :counter) != previous
    assert Process.alive?(app)
  end

  test "greeting receives app params and direct dependency updates without restarting" do
    app = start_app(Greeting.App, params: %{name: "The greeted one"})
    hello = Solve.controller_pid(app, :hello)

    assert Solve.subscribe(app, :hello) == %{
             greeting: "Hello The greeted one, you have 0 credits"
           }

    Solve.dispatch(app, :credits, :increment, 100)
    assert_update(app, :hello, %{greeting: "Hello The greeted one, you have 100 credits"})
    assert Solve.controller_pid(app, :hello) == hello
    refute_receive %Solve.Message{payload: %Solve.Update{controller_name: :credits}}, 20
  end

  test "negative alert starts and stops as credits change" do
    app = start_app(Negative.App)
    assert Solve.subscribe(app, :negative) == nil
    assert Solve.subscribe(app, :hello) == %{greeting: "Hello Anon, you have 0 credits"}
    Solve.dispatch(app, :credits, :decrement, 100)
    assert_update(app, :hello, %{greeting: "Hello Anon, you have -100 credits"})
    assert_update(app, :negative, %{alert: "Negative credits"})
    alert = Solve.controller_pid(app, :negative)
    monitor = Process.monitor(alert)
    Solve.dispatch(app, :credits, :increment, 200)
    assert_update(app, :hello, %{greeting: "Hello Anon, you have 100 credits"})
    assert_update(app, :negative, nil)
    assert_receive {:DOWN, ^monitor, :process, ^alert, _}, 1_000
  end

  test "callbacks route credit changes to the notifications controller" do
    app = start_app(Callbacks.App)
    assert Solve.subscribe(app, :notifications) == %{notifications: []}
    Solve.dispatch(app, :credits, :increment, 300)
    assert_update(app, :notifications, %{notifications: ["Credits change: 300"]})
    Solve.dispatch(app, :credits, :decrement, 200)

    assert_update(app, :notifications, %{
      notifications: ["Credits change: -200", "Credits change: 300"]
    })

    assert Solve.subscribe(app, :credits) == %{count: 100}
  end

  test "both notification implementations dismiss by index, nil, and empty state" do
    for module <- [Callbacks.App, Timers.App] do
      app = start_app(module)

      for message <- ["first", "second", "third"],
          do: Solve.dispatch(app, :notifications, :notify, message)

      assert Solve.subscribe(app, :notifications) == %{
               notifications: ["third", "second", "first"]
             }

      Solve.dispatch(app, :notifications, :dismiss, 1)
      assert Solve.subscribe(app, :notifications) == %{notifications: ["third", "first"]}
      Solve.dispatch(app, :notifications, :dismiss, nil)
      assert Solve.subscribe(app, :notifications) == %{notifications: ["first"]}
      Solve.dispatch(app, :notifications, :dismiss, nil)
      Solve.dispatch(app, :notifications, :dismiss, nil)
      assert Solve.subscribe(app, :notifications) == %{notifications: []}
    end
  end

  test "notification timers invoke handle_info and remove the oldest messages" do
    app = start_app(Timers.App)
    assert Solve.subscribe(app, :notifications) == %{notifications: []}
    Solve.dispatch(app, :credits, :increment, 300)
    assert_update(app, :notifications, %{notifications: ["Credits change: 300"]})
    Solve.dispatch(app, :credits, :decrement, 200)

    assert_update(app, :notifications, %{
      notifications: ["Credits change: -200", "Credits change: 300"]
    })

    assert_update(app, :notifications, %{notifications: ["Credits change: -200"]}, 10_000)
    assert_update(app, :notifications, %{notifications: []}, 10_000)
  end

  test "collected counters retain state, disappear, and restart from zero" do
    app = start_app(Collections.App)
    assert Solve.subscribe(app, {:counter, 3}) == nil
    Solve.dispatch(app, :n_counters, :increment, 3)
    assert_update(app, {:counter, 3}, %{count: 0})
    kept = Solve.controller_pid(app, {:counter, 1})
    Solve.dispatch(app, {:counter, 1}, :increment, 7)
    assert Solve.subscribe(app, {:counter, 1}) == %{count: 7}
    first = Solve.controller_pid(app, {:counter, 3})
    monitor = Process.monitor(first)
    Solve.dispatch(app, {:counter, 3}, :increment, 100)
    assert_update(app, {:counter, 3}, %{count: 100})
    Solve.dispatch(app, :n_counters, :decrement, 1)
    assert_update(app, {:counter, 3}, nil)
    assert_receive {:DOWN, ^monitor, :process, ^first, _}, 1_000
    Solve.dispatch(app, :n_counters, :increment, 1)
    assert_update(app, {:counter, 3}, %{count: 0})
    assert Solve.controller_pid(app, {:counter, 3}) != first
    assert Solve.controller_pid(app, {:counter, 1}) == kept
    assert Solve.subscribe(app, {:counter, 1}) == %{count: 7}
  end

  test "presenter renders collections and dispatches direct item events" do
    app = start_app(Presenter.App)
    {:ok, presenter} = Presenter.Presenter.start_link(app)
    on_exit(fn -> stop(presenter) end)
    assert capture_io(fn -> Presenter.Presenter.show() end) == "Showing 0 counters\n"
    assert :ok = Presenter.Presenter.add_counter()
    await_scene(presenter, "Showing 1 counters\nCounter(1): 0")

    assert capture_io(fn -> Presenter.Presenter.show() end) ==
             "Showing 1 counters\nCounter(1): 0\n"

    # Transitive dispatch is asynchronous; wait for materialization, as between IEx interactions.
    Solve.subscribe(app, {:counter, 4})
    Solve.dispatch(app, :n_counters, :increment, 3)
    assert_update(app, {:counter, 4}, %{count: 0})
    Solve.dispatch(app, {:counter, 4}, :increment, 20)
    assert :ok = Presenter.Presenter.increment(3)
    expected = "Showing 4 counters\nCounter(1): 0\nCounter(2): 0\nCounter(3): 1\nCounter(4): 20"
    await_scene(presenter, expected)
    assert capture_io(fn -> Presenter.Presenter.show() end) == expected <> "\n"
  end

  defp start_app(module, opts \\ []) do
    {:ok, app} = module.start_link(opts)
    on_exit(fn -> stop(app) end)
    app
  end

  defp stop(pid) do
    GenServer.stop(pid, :shutdown)
  catch
    :exit, _ -> :ok
  end

  defp assert_update(app, target, value, timeout \\ 1_000) do
    assert_receive %Solve.Message{
                     type: :update,
                     payload: %Solve.Update{
                       app: ^app,
                       controller_name: ^target,
                       exposed_state: ^value
                     }
                   },
                   timeout
  end

  defp await_scene(pid, expected, attempts \\ 100)

  defp await_scene(pid, expected, 0),
    do: assert(IO.iodata_to_binary(GenServer.call(pid, :show)) == expected)

  defp await_scene(pid, expected, attempts) do
    if IO.iodata_to_binary(GenServer.call(pid, :show)) != expected do
      Process.sleep(10)
      await_scene(pid, expected, attempts - 1)
    end
  end
end
