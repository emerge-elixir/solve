defmodule Solve.LookupRecoveryFixture.Value do
  use Solve.Controller, events: [:set]
  @impl true
  def init(value, _dependencies), do: %{value: value}
  def set(value), do: %{value: value}
end

defmodule Solve.LookupRecoveryFixture.App do
  use Solve
  @impl true
  def controllers do
    [
      controller!(name: :source, module: Solve.LookupRecoveryFixture.Value, params: 1),
      controller!(name: :other, module: Solve.LookupRecoveryFixture.Value, params: 2),
      controller!(name: :off, module: Solve.LookupRecoveryFixture.Value, params: false),
      controller!(
        name: :catalog,
        module: Solve.LookupRecoveryFixture.Value,
        params: [{1, :int}, {1.0, :float}]
      ),
      controller!(
        name: :items,
        module: Solve.LookupRecoveryFixture.Value,
        variant: :collection,
        dependencies: [:catalog],
        collect: fn %{dependencies: %{catalog: %{value: items}}} -> items end
      )
    ]
  end

  def boot(name \\ :lookup_recovery_app) do
    {:ok, pid} = start_link(name: name)
    Process.unlink(pid)
    pid
  end
end
