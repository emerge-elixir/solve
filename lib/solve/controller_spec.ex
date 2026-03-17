defmodule Solve.ControllerSpec do
  @moduledoc """
  Controller specification used by `Solve` init and dependency validation.
  """

  @type name :: atom()

  @type t :: %__MODULE__{
          name: name(),
          module: module(),
          params: term(),
          dependencies: [name()],
          callbacks: term()
        }

  @enforce_keys [:name, :module]
  defstruct [
    :name,
    :module,
    dependencies: [],
    params: &__MODULE__.default_params/1,
    callbacks: []
  ]

  @spec controller!(keyword()) :: t()
  def controller!(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  def controller!(opts) do
    raise ArgumentError, "controller!/1 expects a keyword list, got: #{inspect(opts)}"
  end

  @spec default_params(term()) :: true
  def default_params(_dependencies), do: true

  @spec validate_many(term()) :: {:ok, [t()]} | {:error, term()}
  def validate_many(controller_specs) when is_list(controller_specs) do
    controller_specs
    |> Enum.reduce_while({:ok, []}, fn controller_spec, {:ok, validated_specs} ->
      case validate(controller_spec) do
        {:ok, validated_spec} -> {:cont, {:ok, [validated_spec | validated_specs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated_specs} -> {:ok, Enum.reverse(validated_specs)}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_many(other), do: {:error, {:invalid_controllers_return, other}}

  @spec validate(term()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = controller_spec) do
    with :ok <- validate_name(controller_spec.name),
         :ok <- validate_module(controller_spec.name, controller_spec.module),
         :ok <- validate_dependencies(controller_spec.name, controller_spec.dependencies) do
      {:ok, controller_spec}
    end
  end

  def validate(other), do: {:error, {:invalid_controller_spec, other}}

  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name(name), do: {:error, {:invalid_controller_name, name}}

  defp validate_module(_name, module) when is_atom(module), do: :ok
  defp validate_module(name, module), do: {:error, {:invalid_controller_module, name, module}}

  defp validate_dependencies(_name, []), do: :ok

  defp validate_dependencies(name, dependencies) when is_list(dependencies) do
    cond do
      not Enum.all?(dependencies, &is_atom/1) ->
        {:error, {:invalid_dependencies, name, dependencies}}

      length(dependencies) != MapSet.size(MapSet.new(dependencies)) ->
        {:error, {:duplicate_dependency, name, find_first_duplicate(dependencies)}}

      true ->
        :ok
    end
  end

  defp validate_dependencies(name, dependencies) do
    {:error, {:invalid_dependencies, name, dependencies}}
  end

  defp find_first_duplicate(values) do
    Enum.reduce_while(values, MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value) do
        {:halt, value}
      else
        {:cont, MapSet.put(seen, value)}
      end
    end)
  end
end
