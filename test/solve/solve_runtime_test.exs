defmodule Solve.RuntimeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule LifecycleSourceController do
    use Solve.Controller, events: [:set]

    @impl true
    def init(%{value: value, test_pid: test_pid} = params, dependencies) do
      send(test_pid, {:source_init, value, dependencies, params})
      %{value: value}
    end

    def set(value, _state, _dependencies, _callbacks, _init_params), do: %{value: value}
  end

  defmodule LifecycleDerivedController do
    use Solve.Controller, events: []

    @impl true
    def init(%{label: label, test_pid: test_pid} = params, dependencies) do
      send(test_pid, {:derived_init, label, dependencies, params})
      {:derived_state, label}
    end

    @impl true
    def expose(state, dependencies, %{label: label}) do
      %{label: label, source: Map.get(dependencies, :source), state: state}
    end
  end

  defmodule StableDerivedController do
    use Solve.Controller, events: []

    @impl true
    def init(%{mode: mode, test_pid: test_pid} = params, dependencies) do
      send(test_pid, {:stable_init, mode, dependencies, params})
      :stable
    end

    @impl true
    def expose(state, dependencies, %{mode: mode}) do
      %{mode: mode, source: Map.get(dependencies, :source), state: state}
    end
  end

  defmodule CrashyController do
    use Solve.Controller, events: [:crash]

    @impl true
    def init(%{value: value, test_pid: test_pid}, _dependencies) do
      send(test_pid, {:crashy_init, value})
      %{value: value}
    end

    def crash(reason, _state, _dependencies, _callbacks, _init_params) do
      raise "crash: #{inspect(reason)}"
    end
  end

  defmodule BootRetryController do
    use Solve.Controller, events: []

    @impl true
    def init(%{counter: counter, fail_until: fail_until, test_pid: test_pid}, _dependencies) do
      attempt =
        Agent.get_and_update(counter, fn count ->
          next = count + 1
          {next, next}
        end)

      send(test_pid, {:boot_retry_attempt, attempt})

      if attempt <= fail_until do
        raise "boot failure #{attempt}"
      end

      %{attempt: attempt}
    end
  end

  defmodule LifecycleSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :source,
          module: Solve.RuntimeTest.LifecycleSourceController,
          params: fn %{app_params: app_params} ->
            %{value: app_params.source_initial, test_pid: app_params.test_pid}
          end
        ),
        controller!(
          name: :derived,
          module: Solve.RuntimeTest.LifecycleDerivedController,
          dependencies: [:source],
          params: fn %{dependencies: dependencies, app_params: app_params} ->
            case dependencies[:source] do
              nil -> false
              %{value: 0} -> false
              %{value: value} -> %{label: value, test_pid: app_params.test_pid}
            end
          end
        )
      ]
    end
  end

  defmodule StableParamsSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :source,
          module: Solve.RuntimeTest.LifecycleSourceController,
          params: fn %{app_params: app_params} ->
            %{value: app_params.source_initial, test_pid: app_params.test_pid}
          end
        ),
        controller!(
          name: :stable,
          module: Solve.RuntimeTest.StableDerivedController,
          dependencies: [:source],
          params: fn %{dependencies: dependencies, app_params: app_params} ->
            case dependencies[:source] do
              nil -> false
              %{value: 0} -> false
              _value -> %{mode: :positive, test_pid: app_params.test_pid}
            end
          end
        )
      ]
    end
  end

  defmodule CrashySolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :crashy,
          module: Solve.RuntimeTest.CrashyController,
          params: fn %{app_params: app_params} ->
            %{value: app_params.initial, test_pid: app_params.test_pid}
          end
        )
      ]
    end
  end

  defmodule BootRetrySolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :boot,
          module: Solve.RuntimeTest.BootRetryController,
          params: fn %{app_params: app_params} -> app_params end
        )
      ]
    end
  end

  defmodule CatalogController do
    use Solve.Controller, events: [:set_columns]

    @impl true
    def init(%{columns: columns, test_pid: test_pid}, _dependencies) do
      send(test_pid, {:catalog_init, columns})
      %{columns: columns}
    end

    def set_columns(columns, _state, _dependencies, _callbacks, _init_params) do
      %{columns: columns}
    end

    @impl true
    def expose(state, _dependencies, _init_params), do: %{columns: state.columns}
  end

  defmodule ColumnItemController do
    use Solve.Controller, events: [:rename, :set_visible]

    @impl true
    def init(%{id: id, title: title, visible?: visible?, test_pid: test_pid}, dependencies) do
      send(test_pid, {:column_init, id, dependencies})
      %{title: title, visible?: visible?}
    end

    def rename(title, state, _dependencies, _callbacks, _init_params) do
      %{state | title: title}
    end

    def set_visible(visible?, state, _dependencies, _callbacks, _init_params) do
      %{state | visible?: visible?}
    end

    @impl true
    def expose(state, _dependencies, %{id: id}) do
      %{id: id, title: state.title, visible?: state.visible?}
    end
  end

  defmodule CollectionProjectionController do
    use Solve.Controller, events: []

    @impl true
    def init(%{label: label, test_pid: test_pid}, dependencies) do
      send(test_pid, {:collection_projection_init, label, dependencies})
      %{label: label}
    end

    @impl true
    def expose(state, %{columns: columns}, _init_params) do
      %{label: state.label, titles: Enum.map(columns, fn {_id, item} -> item.title end)}
    end
  end

  defmodule VisibleProjectionController do
    use Solve.Controller, events: []

    @impl true
    def init(%{test_pid: test_pid}, dependencies) do
      send(test_pid, {:visible_projection_init, dependencies})
      :visible
    end

    @impl true
    def expose(_state, %{visible_columns: columns}, _init_params) do
      %{visible_ids: Enum.map(columns, fn {id, _item} -> id end)}
    end
  end

  defmodule CallbackCatalogController do
    use Solve.Controller, events: [:set_callback_tag, :rename_item]

    @impl true
    def init(%{items: items, callback_tag: callback_tag, test_pid: test_pid}, _dependencies) do
      send(test_pid, {:callback_catalog_init, items, callback_tag})
      %{items: items, callback_tag: callback_tag}
    end

    def set_callback_tag(callback_tag, state, _dependencies, _callbacks, _init_params) do
      %{state | callback_tag: callback_tag}
    end

    def rename_item(%{id: id, title: title}, state, _dependencies, _callbacks, _init_params) do
      items =
        Enum.map(state.items, fn item ->
          if item.id == id do
            %{item | title: title}
          else
            item
          end
        end)

      %{state | items: items}
    end

    @impl true
    def expose(state, _dependencies, _init_params) do
      %{items: state.items, callback_tag: state.callback_tag}
    end
  end

  defmodule CallbackItemController do
    use Solve.Controller, events: [:report]

    @impl true
    def init(%{id: id, title: title, test_pid: test_pid}, _dependencies) do
      send(test_pid, {:callback_item_init, id, title})
      %{id: id, title: title, test_pid: test_pid}
    end

    def report(payload, state, _dependencies, callbacks, _init_params) do
      send(state.test_pid, {:callback_item_report, state.id, payload, callbacks})
      state
    end

    @impl true
    def expose(state, _dependencies, _init_params) do
      %{id: state.id, title: state.title}
    end
  end

  defmodule CallbackCollectionSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :callback_catalog,
          module: Solve.RuntimeTest.CallbackCatalogController,
          params: fn %{app_params: app_params} ->
            %{
              items: app_params.items,
              callback_tag: app_params.callback_tag,
              test_pid: app_params.test_pid
            }
          end
        ),
        controller!(
          name: :callback_item,
          module: Solve.RuntimeTest.CallbackItemController,
          variant: :collection,
          dependencies: [:callback_catalog],
          collect: fn %{
                        dependencies: %{callback_catalog: %{items: items, callback_tag: tag}},
                        app_params: app_params
                      } ->
            Enum.map(items, fn %{id: id, title: title} ->
              {id,
               [
                 params: %{id: id, title: title, test_pid: app_params.test_pid},
                 callbacks: %{tag: tag}
               ]}
            end)
          end
        )
      ]
    end
  end

  defmodule CollectionSolve do
    use Solve

    @impl true
    def controllers do
      [
        controller!(
          name: :catalog,
          module: Solve.RuntimeTest.CatalogController,
          params: fn %{app_params: app_params} ->
            %{columns: app_params.columns, test_pid: app_params.test_pid}
          end
        ),
        controller!(
          name: :column,
          module: Solve.RuntimeTest.ColumnItemController,
          variant: :collection,
          dependencies: [:catalog],
          collect: fn %{dependencies: %{catalog: %{columns: columns}}, app_params: app_params} ->
            Enum.map(columns, fn %{id: id, title: title, visible?: visible?} ->
              {id,
               [
                 params: %{
                   id: id,
                   title: title,
                   visible?: visible?,
                   test_pid: app_params.test_pid
                 }
               ]}
            end)
          end
        ),
        controller!(
          name: :projection,
          module: Solve.RuntimeTest.CollectionProjectionController,
          dependencies: [columns: collection(:column)],
          params: fn %{app_params: app_params} ->
            %{label: :all, test_pid: app_params.test_pid}
          end
        ),
        controller!(
          name: :visible_projection,
          module: Solve.RuntimeTest.VisibleProjectionController,
          dependencies: [
            visible_columns:
              collection(:column, fn _id, item ->
                item.visible?
              end)
          ],
          params: fn %{app_params: app_params} ->
            %{test_pid: app_params.test_pid}
          end
        )
      ]
    end
  end

  test "starts controllers in topological order and caches exposed state" do
    app = start_app(LifecycleSolve, %{source_initial: 1, test_pid: self()})

    assert_receive {:source_init, 1, %{}, %{value: 1, test_pid: test_pid}}
    assert test_pid == self()

    assert_receive {:derived_init, 1, %{source: %{value: 1}}, %{label: 1, test_pid: test_pid}}
    assert test_pid == self()

    assert Solve.subscribe(app, :source) == %{value: 1}

    assert Solve.subscribe(app, :derived) == %{
             label: 1,
             source: %{value: 1},
             state: {:derived_state, 1}
           }

    state = :sys.get_state(app)

    assert state.controller_status_by_name == %{derived: :started, source: :started}
    assert is_pid(state.controller_pids_by_name.source)
    assert is_pid(state.controller_pids_by_name.derived)
  end

  test "controllers start, replace, stop, and restart from params changes" do
    app = start_app(LifecycleSolve, %{source_initial: 0, test_pid: self()})

    assert_receive {:source_init, 0, %{}, %{value: 0, test_pid: test_pid}}
    assert test_pid == self()
    refute_receive {:derived_init, _, _, _}

    assert Solve.subscribe(app, :derived) == nil
    assert Solve.controller_pid(app, :derived) == nil

    assert :ok = Solve.dispatch(app, :derived, :ignored, :payload)
    assert :ok = Solve.dispatch(app, :missing, :ignored, :payload)

    refute_receive %Solve.Message{
                     type: :update,
                     payload: %Solve.Update{
                       app: ^app,
                       controller_name: :derived,
                       exposed_state: _
                     }
                   },
                   50

    assert :ok = Solve.dispatch(app, :source, :set, 1)

    assert_receive {:derived_init, 1, %{source: %{value: 1}}, %{label: 1, test_pid: test_pid}}
    assert test_pid == self()

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: ^app,
        controller_name: :derived,
        exposed_state: %{label: 1, source: %{value: 1}, state: {:derived_state, 1}}
      }
    }

    derived_pid = await_controller_pid(app, :derived)

    assert :ok = Solve.dispatch(app, :source, :set, 2)

    assert_receive {:derived_init, 2, %{source: %{value: 2}}, %{label: 2, test_pid: test_pid}}
    assert test_pid == self()

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: ^app,
        controller_name: :derived,
        exposed_state: %{label: 2, source: %{value: 2}, state: {:derived_state, 2}}
      }
    }

    refute_receive %Solve.Message{
                     type: :update,
                     payload: %Solve.Update{
                       app: ^app,
                       controller_name: :derived,
                       exposed_state: nil
                     }
                   },
                   50

    refute await_pid_change(app, :derived, derived_pid) == derived_pid

    assert :ok = Solve.dispatch(app, :source, :set, 0)

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{app: ^app, controller_name: :derived, exposed_state: nil}
    }

    assert await_controller_stop(app, :derived) == nil

    assert :ok = Solve.dispatch(app, :derived, :ignored, :payload)
    assert :ok = Solve.dispatch(app, :source, :set, 1)

    assert_receive {:derived_init, 1, %{source: %{value: 1}}, %{label: 1, test_pid: test_pid}}
    assert test_pid == self()

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: ^app,
        controller_name: :derived,
        exposed_state: %{label: 1, source: %{value: 1}, state: {:derived_state, 1}}
      }
    }
  end

  test "truthy params that stay equal keep the current controller instance" do
    app = start_app(StableParamsSolve, %{source_initial: 1, test_pid: self()})

    assert_receive {:source_init, 1, %{}, %{value: 1, test_pid: test_pid}}
    assert test_pid == self()

    assert_receive {:stable_init, :positive, %{source: %{value: 1}},
                    %{mode: :positive, test_pid: test_pid}}

    assert test_pid == self()

    assert Solve.subscribe(app, :stable) == %{
             mode: :positive,
             source: %{value: 1},
             state: :stable
           }

    stable_pid = Solve.controller_pid(app, :stable)

    assert :ok = Solve.dispatch(app, :source, :set, 2)

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: ^app,
        controller_name: :stable,
        exposed_state: %{mode: :positive, source: %{value: 2}, state: :stable}
      }
    }

    refute_receive {:stable_init, _, _, _}, 50
    assert Solve.controller_pid(app, :stable) == stable_pid
  end

  test "runtime crashes restart the controller within budget" do
    app = start_app(CrashySolve, %{initial: 1, test_pid: self()})

    assert_receive {:crashy_init, 1}
    assert Solve.subscribe(app, :crashy) == %{value: 1}

    pid = Solve.controller_pid(app, :crashy)

    capture_log(fn ->
      assert :ok = Solve.dispatch(app, :crashy, :crash, :boom)

      assert_receive %Solve.Message{
        type: :update,
        payload: %Solve.Update{app: ^app, controller_name: :crashy, exposed_state: nil}
      }

      assert_receive {:crashy_init, 1}

      assert_receive %Solve.Message{
        type: :update,
        payload: %Solve.Update{app: ^app, controller_name: :crashy, exposed_state: %{value: 1}}
      }
    end)

    refute await_pid_change(app, :crashy, pid) == pid
    assert Process.alive?(app)
  end

  test "exceeding restart budget stops the solve app" do
    original = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, original) end)

    app = start_app(CrashySolve, %{initial: 1, test_pid: self()})

    assert_receive {:crashy_init, 1}
    assert Solve.subscribe(app, :crashy) == %{value: 1}

    capture_log(fn ->
      Enum.each(1..3, fn attempt ->
        assert :ok = Solve.dispatch(app, :crashy, :crash, attempt)

        assert_receive %Solve.Message{
          type: :update,
          payload: %Solve.Update{app: ^app, controller_name: :crashy, exposed_state: nil}
        }

        assert_receive {:crashy_init, 1}

        assert_receive %Solve.Message{
          type: :update,
          payload: %Solve.Update{app: ^app, controller_name: :crashy, exposed_state: %{value: 1}}
        }
      end)

      assert :ok = Solve.dispatch(app, :crashy, :crash, :final)

      assert_receive %Solve.Message{
        type: :update,
        payload: %Solve.Update{app: ^app, controller_name: :crashy, exposed_state: nil}
      }

      assert_receive {:EXIT, ^app, {:controller_restart_limit_exceeded, :crashy, _reason}}, 1_000
    end)
  end

  test "boot-time failures use the same retry budget and can recover" do
    counter = start_supervised!({Agent, fn -> 0 end})

    app =
      start_app(BootRetrySolve, %{counter: counter, fail_until: 2, test_pid: self()})

    assert_receive {:boot_retry_attempt, 1}
    assert_receive {:boot_retry_attempt, 2}
    assert_receive {:boot_retry_attempt, 3}

    assert Solve.subscribe(app, :boot) == %{attempt: 3}
  end

  test "boot-time restart budget exhaustion returns an error" do
    original = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, original) end)

    counter = start_supervised!({Agent, fn -> 0 end})

    assert {:error, {:controller_restart_limit_exceeded, :boot, _reason}} =
             BootRetrySolve.start_link(
               name: unique_name("boot_failure"),
               params: %{counter: counter, fail_until: 4, test_pid: self()}
             )

    assert_receive {:boot_retry_attempt, 1}
    assert_receive {:boot_retry_attempt, 2}
    assert_receive {:boot_retry_attempt, 3}
    assert_receive {:boot_retry_attempt, 4}
  end

  test "subscribe returns the materialized collection for a collection source" do
    app =
      start_app(CollectionSolve, %{columns: initial_columns(), test_pid: self()})

    assert_receive {:catalog_init, columns}
    assert columns == initial_columns()

    assert_receive {:column_init, 1, %{catalog: %{columns: columns}}}
    assert columns == initial_columns()
    assert_receive {:column_init, 2, %{catalog: %{columns: columns}}}
    assert columns == initial_columns()

    assert Solve.subscribe(app, :column) == %Solve.Collection{
             ids: [1, 2],
             items: %{
               1 => %{id: 1, title: "Todo", visible?: true},
               2 => %{id: 2, title: "Doing", visible?: false}
             }
           }

    assert Solve.controller_pid(app, :column) == nil
    assert is_pid(Solve.controller_pid(app, {:column, 1}))
    assert Solve.subscribe(app, {:column, 1}) == %{id: 1, title: "Todo", visible?: true}
  end

  test "raw collection dependencies receive direct item updates without restarting the dependent" do
    app = start_app(CollectionSolve, %{columns: initial_columns(), test_pid: self()})

    assert_receive {:catalog_init, _}
    assert_receive {:column_init, 1, _}
    assert_receive {:column_init, 2, _}
    assert_receive {:collection_projection_init, :all, %{columns: %Solve.Collection{ids: [1, 2]}}}
    assert_receive {:visible_projection_init, %{visible_columns: %Solve.Collection{ids: [1]}}}

    assert Solve.subscribe(app, :projection) == %{label: :all, titles: ["Todo", "Doing"]}

    projection_pid = Solve.controller_pid(app, :projection)

    assert :ok = Solve.dispatch(app, {:column, 1}, :rename, "Backlog")

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: ^app,
        controller_name: :projection,
        exposed_state: %{label: :all, titles: ["Backlog", "Doing"]}
      }
    }

    assert Solve.controller_pid(app, :projection) == projection_pid
    refute_receive {:collection_projection_init, _, _}, 50
  end

  test "filtered collection dependencies keep only matching items" do
    app = start_app(CollectionSolve, %{columns: initial_columns(), test_pid: self()})

    assert_receive {:catalog_init, _}
    assert_receive {:column_init, 1, _}
    assert_receive {:column_init, 2, _}
    assert_receive {:collection_projection_init, :all, _}
    assert_receive {:visible_projection_init, %{visible_columns: %Solve.Collection{ids: [1]}}}

    assert Solve.subscribe(app, :visible_projection) == %{visible_ids: [1]}

    assert :ok = Solve.dispatch(app, {:column, 1}, :set_visible, false)

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: ^app,
        controller_name: :visible_projection,
        exposed_state: %{visible_ids: []}
      }
    }

    assert :ok = Solve.dispatch(app, {:column, 2}, :set_visible, true)

    assert_receive %Solve.Message{
      type: :update,
      payload: %Solve.Update{
        app: ^app,
        controller_name: :visible_projection,
        exposed_state: %{visible_ids: [2]}
      }
    }
  end

  test "collection callback changes update the running item without replacement" do
    app =
      start_app(CallbackCollectionSolve, %{
        items: callback_items(),
        callback_tag: :initial,
        test_pid: self()
      })

    assert_receive {:callback_catalog_init, [%{id: 1, title: "Todo"}], :initial}
    assert_receive {:callback_item_init, 1, "Todo"}

    item_pid = await_controller_pid(app, {:callback_item, 1})

    assert :ok = Solve.dispatch(app, {:callback_item, 1}, :report, :before)
    assert_receive {:callback_item_report, 1, :before, %{tag: :initial}}

    assert :ok = Solve.dispatch(app, :callback_catalog, :set_callback_tag, :updated)
    assert await_target_callbacks(app, {:callback_item, 1}, %{tag: :updated}) == %{tag: :updated}
    assert :ok = Solve.dispatch(app, {:callback_item, 1}, :report, :after)

    assert_receive {:callback_item_report, 1, :after, %{tag: :updated}}
    assert Solve.controller_pid(app, {:callback_item, 1}) == item_pid
    refute_receive {:callback_item_init, 1, _title}, 50
  end

  test "collection params changes replace the running item" do
    app =
      start_app(CallbackCollectionSolve, %{
        items: callback_items(),
        callback_tag: :initial,
        test_pid: self()
      })

    assert_receive {:callback_catalog_init, [%{id: 1, title: "Todo"}], :initial}
    assert_receive {:callback_item_init, 1, "Todo"}

    item_pid = await_controller_pid(app, {:callback_item, 1})

    assert :ok =
             Solve.dispatch(app, :callback_catalog, :rename_item, %{id: 1, title: "Backlog"})

    assert_receive {:callback_item_init, 1, "Backlog"}
    refute await_pid_change(app, {:callback_item, 1}, item_pid) == item_pid

    assert Solve.subscribe(app, {:callback_item, 1}) == %{id: 1, title: "Backlog"}
    assert :ok = Solve.dispatch(app, {:callback_item, 1}, :report, :after)
    assert_receive {:callback_item_report, 1, :after, %{tag: :initial}}
  end

  defp initial_columns do
    [
      %{id: 1, title: "Todo", visible?: true},
      %{id: 2, title: "Doing", visible?: false}
    ]
  end

  defp callback_items do
    [%{id: 1, title: "Todo"}]
  end

  defp start_app(module, app_params) do
    name = unique_name(module)
    assert {:ok, pid} = module.start_link(name: name, params: app_params)

    on_exit(fn ->
      if Process.alive?(pid) do
        stop_process(pid)
      end
    end)

    pid
  end

  defp await_controller_pid(app, controller_name, attempts \\ 50)

  defp await_controller_pid(_app, controller_name, 0) do
    flunk("controller #{inspect(controller_name)} did not start in time")
  end

  defp await_controller_pid(app, controller_name, attempts) do
    case Solve.controller_pid(app, controller_name) do
      pid when is_pid(pid) ->
        pid

      _ ->
        Process.sleep(10)
        await_controller_pid(app, controller_name, attempts - 1)
    end
  end

  defp await_controller_stop(app, controller_name, attempts \\ 50)

  defp await_controller_stop(_app, controller_name, 0) do
    flunk("controller #{inspect(controller_name)} did not stop in time")
  end

  defp await_controller_stop(app, controller_name, attempts) do
    case Solve.controller_pid(app, controller_name) do
      nil ->
        nil

      _pid ->
        Process.sleep(10)
        await_controller_stop(app, controller_name, attempts - 1)
    end
  end

  defp await_pid_change(app, controller_name, old_pid, attempts \\ 50)

  defp await_pid_change(_app, controller_name, old_pid, 0) do
    flunk("controller #{inspect(controller_name)} pid did not change from #{inspect(old_pid)}")
  end

  defp await_pid_change(app, controller_name, old_pid, attempts) do
    case Solve.controller_pid(app, controller_name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _pid ->
        Process.sleep(10)
        await_pid_change(app, controller_name, old_pid, attempts - 1)
    end
  end

  defp await_target_callbacks(app, target, expected, attempts \\ 50)

  defp await_target_callbacks(_app, target, expected, 0) do
    flunk("target #{inspect(target)} callbacks did not change to #{inspect(expected)} in time")
  end

  defp await_target_callbacks(app, target, expected, attempts) do
    callbacks = :sys.get_state(app).controller_callbacks_by_target |> Map.get(target)

    if callbacks == expected do
      callbacks
    else
      Process.sleep(10)
      await_target_callbacks(app, target, expected, attempts - 1)
    end
  end

  defp unique_name(prefix) do
    Module.concat(__MODULE__, String.to_atom("#{prefix}_#{System.unique_integer([:positive])}"))
  end

  defp stop_process(pid) do
    GenServer.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
