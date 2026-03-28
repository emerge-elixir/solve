defmodule Solve.ControllerSpecTest do
  use ExUnit.Case, async: true

  alias Solve.ControllerSpec

  import Solve.ControllerSpec, only: [controller!: 1, collection: 1, collection: 2]

  defmodule UserController do
  end

  defmodule ColumnController do
  end

  defmodule SummaryController do
  end

  defmodule CounterController do
  end

  test "validate/1 accepts collection controllers with collect/1" do
    spec =
      controller!(
        name: :column,
        module: ColumnController,
        variant: :collection,
        collect: fn _ctx -> [{1, [params: %{id: 1}]}] end
      )

    assert {:ok,
            %ControllerSpec{
              name: :column,
              module: ColumnController,
              variant: :collection,
              collect: collect,
              dependencies: [],
              dependency_bindings: []
            }} = ControllerSpec.validate(spec)

    assert is_function(collect, 1)
  end

  test "validate/1 rejects collection controllers without collect/1" do
    spec =
      controller!(
        name: :column,
        module: ColumnController,
        variant: :collection
      )

    assert {:error, {:missing_collect, :column}} = ControllerSpec.validate(spec)
  end

  test "validate/1 rejects collect/1 on non-collection controllers" do
    spec =
      controller!(
        name: :counter,
        module: CounterController,
        collect: fn _ctx -> [] end
      )

    assert {:error, {:unexpected_collect, :counter}} = ControllerSpec.validate(spec)
  end

  test "validate/1 rejects collection filters with arity other than 2" do
    filter = fn _id -> true end

    spec =
      controller!(
        name: :summary,
        module: SummaryController,
        dependencies: [
          visible_columns: collection(:column, filter)
        ]
      )

    assert {:error, {:invalid_collection_filter, :visible_columns, :column, ^filter}} =
             ControllerSpec.validate(spec)
  end

  test "validate/1 normalizes atom, aliased atom, unfiltered collection, and filtered collection bindings" do
    filter = fn _id, item -> item.visible? end

    spec =
      controller!(
        name: :summary,
        module: SummaryController,
        dependencies: [
          :user,
          columns: collection(:column),
          visible_columns: collection(:column, filter)
        ]
      )

    assert {:ok,
            %ControllerSpec{
              dependencies: [:user, :column],
              dependency_bindings: bindings
            }} = ControllerSpec.validate(spec)

    assert [
             %{key: :user, source: :user, kind: :single, filter: nil},
             %{key: :columns, source: :column, kind: :collection, filter: nil},
             %{key: :visible_columns, source: :column, kind: :collection, filter: ^filter}
           ] = bindings
  end

  test "use Solve injects dispatch helpers for callback definitions" do
    module = unique_module_name("DispatchHelpers")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Solve

      @impl true
      def controllers do
        [
          controller!(
            name: :create_todo,
            module: #{inspect(CounterController)},
            callbacks: %{
              submit: fn payload -> dispatch(:todo_list, :create_todo, payload) end
            }
          )
        ]
      end
    end
    """)

    assert [%ControllerSpec{callbacks: %{submit: submit}} = spec] = module.controllers()
    assert is_function(submit, 1)
    assert {:ok, %ControllerSpec{callbacks: %{submit: ^submit}}} = ControllerSpec.validate(spec)
  end

  defp unique_module_name(prefix) do
    Module.concat(
      __MODULE__,
      String.to_atom(prefix <> Integer.to_string(System.unique_integer([:positive])))
    )
  end
end
