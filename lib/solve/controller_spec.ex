defmodule Solve.ControllerSpec do
  @moduledoc """
  Controller specification used by `Solve` init and dependency validation.
  """

  @type name :: atom()
  @type variant :: :singleton | :collection
  @type collection_binding :: {:solve_collection_binding, atom(), nil | function()}
  @type dependency_binding :: %{
          key: atom(),
          source: atom(),
          kind: :single | :collection,
          filter: nil | (Solve.Collection.id(), map() -> boolean())
        }
  @type dependency_spec :: atom() | {atom(), atom() | collection_binding()}
  @type collect_context :: %{dependencies: map(), app_params: term()}
  @type collected_item_opts :: keyword()
  @type collect_result :: [{Solve.Collection.id(), collected_item_opts()}]
  @type collect_fun :: (collect_context() -> collect_result())

  @type t :: %__MODULE__{
          name: name(),
          module: module(),
          variant: variant(),
          params: term(),
          dependencies: [name()],
          dependency_bindings: [dependency_binding()],
          collect: collect_fun() | nil,
          callbacks: map()
        }

  @enforce_keys [:name, :module]
  defstruct [
    :name,
    :module,
    variant: :singleton,
    dependencies: [],
    dependency_bindings: [],
    params: &__MODULE__.default_params/1,
    collect: nil,
    callbacks: %{}
  ]

  @spec controller!(keyword()) :: t()
  def controller!(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  def controller!(opts) do
    raise ArgumentError, "controller!/1 expects a keyword list, got: #{inspect(opts)}"
  end

  @spec collection(atom()) :: collection_binding()
  def collection(source) when is_atom(source), do: {:solve_collection_binding, source, nil}

  @spec collection(atom(), (Solve.Collection.id(), map() -> boolean())) :: collection_binding()
  def collection(source, filter) when is_atom(source),
    do: {:solve_collection_binding, source, filter}

  @spec default_params(term()) :: true
  def default_params(%{dependencies: _dependencies, app_params: _app_params}), do: true

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
         :ok <- validate_variant(controller_spec.name, controller_spec.variant),
         {:ok, dependencies, dependency_bindings} <-
           validate_or_normalize_dependencies(controller_spec),
         :ok <- validate_params(controller_spec.name, controller_spec.params),
         :ok <-
           validate_collect(
             controller_spec.name,
             controller_spec.variant,
             controller_spec.collect
           ),
         :ok <- validate_callbacks(controller_spec.name, controller_spec.callbacks) do
      {:ok,
       %{
         controller_spec
         | dependencies: dependencies,
           dependency_bindings: dependency_bindings
       }}
    end
  end

  def validate(other), do: {:error, {:invalid_controller_spec, other}}

  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name(name), do: {:error, {:invalid_controller_name, name}}

  defp validate_module(_name, module) when is_atom(module), do: :ok
  defp validate_module(name, module), do: {:error, {:invalid_controller_module, name, module}}

  defp validate_variant(_name, variant) when variant in [:singleton, :collection], do: :ok
  defp validate_variant(name, variant), do: {:error, {:invalid_variant, name, variant}}

  defp validate_params(_name, params) when is_function(params, 1), do: :ok
  defp validate_params(_name, params) when not is_function(params), do: :ok
  defp validate_params(name, params), do: {:error, {:invalid_params, name, params}}

  defp validate_collect(_name, :collection, collect) when is_function(collect, 1), do: :ok
  defp validate_collect(name, :collection, nil), do: {:error, {:missing_collect, name}}

  defp validate_collect(name, :collection, collect),
    do: {:error, {:invalid_collect, name, collect}}

  defp validate_collect(_name, :singleton, nil), do: :ok
  defp validate_collect(name, :singleton, _collect), do: {:error, {:unexpected_collect, name}}

  defp validate_callbacks(_name, callbacks) when is_map(callbacks), do: :ok
  defp validate_callbacks(name, callbacks), do: {:error, {:invalid_callbacks, name, callbacks}}

  defp validate_or_normalize_dependencies(%__MODULE__{dependency_bindings: []} = controller_spec) do
    normalize_dependencies(controller_spec.name, controller_spec.dependencies)
  end

  defp validate_or_normalize_dependencies(%__MODULE__{} = controller_spec) do
    with :ok <- validate_dependency_sources(controller_spec.name, controller_spec.dependencies),
         :ok <-
           validate_existing_dependency_bindings(
             controller_spec.name,
             controller_spec.dependency_bindings
           ) do
      {:ok, controller_spec.dependencies, controller_spec.dependency_bindings}
    end
  end

  defp normalize_dependencies(_name, []), do: {:ok, [], []}

  defp normalize_dependencies(name, dependencies) when is_list(dependencies) do
    Enum.reduce_while(dependencies, {:ok, [], [], MapSet.new()}, fn dependency_spec,
                                                                    {:ok, sources, bindings,
                                                                     binding_keys} ->
      with {:ok, binding} <- normalize_dependency_spec(name, dependency_spec),
           :ok <- validate_binding_key(name, binding.key, binding_keys) do
        sources = if binding.source in sources, do: sources, else: sources ++ [binding.source]
        binding_keys = MapSet.put(binding_keys, binding.key)
        {:cont, {:ok, sources, bindings ++ [binding], binding_keys}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, sources, bindings, _binding_keys} -> {:ok, sources, bindings}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_dependencies(name, dependencies),
    do: {:error, {:invalid_dependencies, name, dependencies}}

  defp normalize_dependency_spec(_name, dependency_name) when is_atom(dependency_name) do
    {:ok, %{key: dependency_name, source: dependency_name, kind: :single, filter: nil}}
  end

  defp normalize_dependency_spec(_name, {key, dependency_name})
       when is_atom(key) and is_atom(dependency_name) do
    {:ok, %{key: key, source: dependency_name, kind: :single, filter: nil}}
  end

  defp normalize_dependency_spec(_name, {key, {:solve_collection_binding, source, nil}})
       when is_atom(key) and is_atom(source) do
    {:ok, %{key: key, source: source, kind: :collection, filter: nil}}
  end

  defp normalize_dependency_spec(_name, {key, {:solve_collection_binding, source, filter}})
       when is_atom(key) and is_atom(source) and is_function(filter, 2) do
    {:ok, %{key: key, source: source, kind: :collection, filter: filter}}
  end

  defp normalize_dependency_spec(_name, {key, {:solve_collection_binding, source, filter}})
       when is_atom(key) and is_atom(source) do
    {:error, {:invalid_collection_filter, key, source, filter}}
  end

  defp normalize_dependency_spec(name, dependency_spec) do
    {:error, {:invalid_dependencies, name, dependency_spec}}
  end

  defp validate_binding_key(name, key, seen) do
    if MapSet.member?(seen, key) do
      {:error, {:duplicate_dependency_key, name, key}}
    else
      :ok
    end
  end

  defp validate_dependency_sources(name, dependencies) when is_list(dependencies) do
    if Enum.all?(dependencies, &is_atom/1) do
      :ok
    else
      {:error, {:invalid_dependencies, name, dependencies}}
    end
  end

  defp validate_dependency_sources(name, dependencies) do
    {:error, {:invalid_dependencies, name, dependencies}}
  end

  defp validate_existing_dependency_bindings(_name, []) do
    :ok
  end

  defp validate_existing_dependency_bindings(name, bindings) when is_list(bindings) do
    Enum.reduce_while(bindings, {:ok, MapSet.new()}, fn binding, {:ok, seen_keys} ->
      with {:ok, key} <- validate_existing_binding(name, binding),
           :ok <- validate_binding_key(name, key, seen_keys) do
        {:cont, {:ok, MapSet.put(seen_keys, key)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _seen_keys} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_existing_dependency_bindings(name, bindings) do
    {:error, {:invalid_dependencies, name, bindings}}
  end

  defp validate_existing_binding(_name, %{key: key, source: source, kind: :single, filter: nil})
       when is_atom(key) and is_atom(source) do
    {:ok, key}
  end

  defp validate_existing_binding(_name, %{
         key: key,
         source: source,
         kind: :collection,
         filter: nil
       })
       when is_atom(key) and is_atom(source) do
    {:ok, key}
  end

  defp validate_existing_binding(
         _name,
         %{key: key, source: source, kind: :collection, filter: filter}
       )
       when is_atom(key) and is_atom(source) and is_function(filter, 2) do
    {:ok, key}
  end

  defp validate_existing_binding(_name, %{
         key: key,
         source: source,
         kind: :collection,
         filter: filter
       })
       when is_atom(key) and is_atom(source) do
    {:error, {:invalid_collection_filter, key, source, filter}}
  end

  defp validate_existing_binding(name, _binding) do
    {:error, {:invalid_dependencies, name, :invalid_binding}}
  end
end
