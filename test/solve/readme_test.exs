defmodule Solve.ReadmeTest do
  use ExUnit.Case, async: false

  test "complete README module examples compile" do
    readme = File.read!(Path.expand("../../README.md", __DIR__))
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      # The tutorial redefines modules as it progresses. Compile those examples
      # in order, ignoring prose, headings, IEx transcripts and partial snippets.
      for [code] <-
            Regex.scan(~r/^```elixir[ \t]*\r?\n(.*?)^```[ \t]*\r?$/ms, readme,
              capture: :all_but_first
            ),
          Regex.match?(~r/^\s*defmodule\b/m, code) do
        for {module, _bytecode} <- Code.compile_string(code, "README.md") do
          on_exit(module, fn ->
            :code.purge(module)
            :code.delete(module)
            :code.purge(module)
          end)
        end
      end
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end
end
