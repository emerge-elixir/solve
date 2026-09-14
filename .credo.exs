%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["{mix,.formatter,.credo}.exs", "lib/**/*.ex", "test/**/*.exs"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      checks: [
        {Credo.Check.Refactor.Apply, false},
        {Credo.Check.Refactor.CondStatements, false},
        {Credo.Check.Refactor.NegatedConditionsWithElse, false}
      ]
    }
  ]
}
