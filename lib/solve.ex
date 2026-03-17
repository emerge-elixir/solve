defmodule Solve do
  @moduledoc """
  Coordinates controller graph validation and initialization.
  """

  alias Solve.ControllerSpec
  alias Solve.DependencyGraph

  @type controller_name :: ControllerSpec.name()
  @type graph :: [ControllerSpec.t()]

  @callback controllers() :: graph()

  defmacro __using__(_opts) do
    quote do
      @behaviour GenServer
      @behaviour Solve
      @after_compile Solve
      import Solve.ControllerSpec, only: [controller!: 1]

      def start_link(opts \\ []) do
        name = Keyword.get(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      @impl true
      def init(opts), do: Solve.init_runtime(__MODULE__, opts)
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    DependencyGraph.resolve_module!(env.module, file: env.file, line: 1)
    :ok
  end

  @doc false
  def init_runtime(solve_module, opts) do
    app_params = Keyword.get(opts, :params, %{})

    dependency_graph = DependencyGraph.resolve_module!(solve_module)
    {:ok, Map.put(dependency_graph, :app_params, app_params)}
  end
end
