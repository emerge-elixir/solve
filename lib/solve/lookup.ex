defmodule Solve.Lookup do
  @moduledoc false

  defmacro __using__(opts) do

    quote do


    end
  end

  def subscribe(app \\ nil, controller) do
    app = get_app(app)
    Solve.subscribe(app, controller)
  end

  def solve(app \\ nil, controller, key) do
    app = get_app(app)
    Process.get({app, controller})
  end

  defp get_app(nil), do: Process.get(:solve_app)
  defp get_app(app), do: app


end
