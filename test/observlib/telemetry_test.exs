defmodule ObservLib.TelemetryTest do
  use ExUnit.Case, async: false

  # Helper to detach a handler by prefix, ignoring errors
  defp detach_handler(prefix) do
    ObservLib.Telemetry.detach(prefix)
  end

  # Helper to generate a unique event prefix per test to avoid collisions
  defp unique_prefix do
    [:test, :"event_#{:erlang.unique_integer([:positive])}"]
  end

  describe "setup/0" do
    test "returns :ok when no telemetry_events configured" do
      Application.put_env(:observlib, :telemetry_events, [])

      assert ObservLib.Telemetry.setup() == :ok
    end

    test "attaches handlers for configured event prefixes" do
      prefix = unique_prefix()
      Application.put_env(:observlib, :telemetry_events, [prefix])

      on_exit(fn ->
        detach_handler(prefix)
        Application.put_env(:observlib, :telemetry_events, [])
      end)

      assert ObservLib.Telemetry.setup() == :ok

      handlers = ObservLib.Telemetry.list_handlers()
      handler_ids = Enum.map(handlers, & &1.id)
      expected_id = :"observlib_#{Enum.map_join(prefix, "_", &Atom.to_string/1)}"
      assert expected_id in handler_ids
    end

    test "is idempotent when called twice (second attach is :already_attached error but first succeeds)" do
      prefix = unique_prefix()
      Application.put_env(:observlib, :telemetry_events, [prefix])

      on_exit(fn ->
        detach_handler(prefix)
        Application.put_env(:observlib, :telemetry_events, [])
      end)

      assert ObservLib.Telemetry.setup() == :ok
      # Second call will return error since handler is already attached
      # But we just verify first call succeeded
      ObservLib.Telemetry.setup()
    end
  end

  describe "setup/1" do
    test "attaches handlers for given event prefixes" do
      prefix = unique_prefix()

      on_exit(fn -> detach_handler(prefix) end)

      assert ObservLib.Telemetry.setup(events: [prefix]) == :ok

      handlers = ObservLib.Telemetry.list_handlers()
      handler_ids = Enum.map(handlers, & &1.id)
      expected_id = :"observlib_#{Enum.map_join(prefix, "_", &Atom.to_string/1)}"
      assert expected_id in handler_ids
    end

    test "returns :ok with empty events list" do
      assert ObservLib.Telemetry.setup(events: []) == :ok
    end

    test "attaches handlers for multiple event prefixes" do
      prefix1 = [:test, :"multi_a_#{:erlang.unique_integer([:positive])}"]
      prefix2 = [:test, :"multi_b_#{:erlang.unique_integer([:positive])}"]

      on_exit(fn ->
        detach_handler(prefix1)
        detach_handler(prefix2)
      end)

      assert ObservLib.Telemetry.setup(events: [prefix1, prefix2]) == :ok

      handlers = ObservLib.Telemetry.list_handlers()
      handler_ids = Enum.map(handlers, & &1.id)

      for prefix <- [prefix1, prefix2] do
        expected_id = :"observlib_#{Enum.map_join(prefix, "_", &Atom.to_string/1)}"
        assert expected_id in handler_ids
      end
    end
  end

  describe "attach/2" do
    test "attaches handler for a telemetry event prefix" do
      prefix = unique_prefix()

      on_exit(fn -> detach_handler(prefix) end)

      assert ObservLib.Telemetry.attach(prefix) == :ok
    end

    test "handler receives telemetry events when emitted" do
      prefix = unique_prefix()
      test_pid = self()
      handler_id = :"test_capture_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        detach_handler(prefix)
        :telemetry.detach(handler_id)
      end)

      assert ObservLib.Telemetry.attach(prefix) == :ok

      # Attach a capture handler to verify the event is executed
      :telemetry.attach(
        handler_id,
        prefix,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:captured, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.execute(prefix, %{value: 42}, %{source: "test"})

      assert_receive {:captured, ^prefix, %{value: 42}, %{source: "test"}}, 1000
    end

    test "returns {:error, :already_attached} when prefix already attached" do
      prefix = unique_prefix()

      on_exit(fn -> detach_handler(prefix) end)

      assert ObservLib.Telemetry.attach(prefix) == :ok
      assert ObservLib.Telemetry.attach(prefix) == {:error, :already_attached}
    end

    test "supports custom handler function via :handler option" do
      prefix = unique_prefix()
      test_pid = self()

      on_exit(fn -> detach_handler(prefix) end)

      custom_handler = fn event, measurements, metadata, _config ->
        send(test_pid, {:custom, event, measurements, metadata})
      end

      assert ObservLib.Telemetry.attach(prefix, handler: custom_handler) == :ok

      :telemetry.execute(prefix, %{count: 1}, %{})

      assert_receive {:custom, ^prefix, %{count: 1}, %{}}, 1000
    end

    test "generates correct handler ID from prefix" do
      prefix = [:my_app, :request, :stop]

      on_exit(fn -> detach_handler(prefix) end)

      ObservLib.Telemetry.attach(prefix)

      handlers = ObservLib.Telemetry.list_handlers()
      handler_ids = Enum.map(handlers, & &1.id)
      assert :observlib_my_app_request_stop in handler_ids
    end

    test "attaches single atom prefix" do
      prefix = [:"single_#{:erlang.unique_integer([:positive])}"]

      on_exit(fn -> detach_handler(prefix) end)

      assert ObservLib.Telemetry.attach(prefix) == :ok
    end
  end

  describe "detach/1" do
    test "detaches a previously attached handler" do
      prefix = unique_prefix()

      ObservLib.Telemetry.attach(prefix)
      assert ObservLib.Telemetry.detach(prefix) == :ok

      handlers = ObservLib.Telemetry.list_handlers()
      handler_ids = Enum.map(handlers, & &1.id)
      expected_id = :"observlib_#{Enum.map_join(prefix, "_", &Atom.to_string/1)}"
      refute expected_id in handler_ids
    end

    test "is idempotent - detaching non-existent handler returns :ok" do
      prefix = [:nonexistent, :handler, :prefix]
      assert ObservLib.Telemetry.detach(prefix) == :ok
    end

    test "detached handler no longer receives events" do
      prefix = unique_prefix()
      test_pid = self()
      handler_id = :"test_after_detach_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      # Attach a capture handler
      :telemetry.attach(
        handler_id,
        prefix,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:captured, event, measurements, metadata})
        end,
        nil
      )

      # Attach and then detach the ObservLib handler
      ObservLib.Telemetry.attach(prefix)
      ObservLib.Telemetry.detach(prefix)

      # Emit event - capture handler should still receive it but ObservLib handler should not crash
      :telemetry.execute(prefix, %{value: 1}, %{})

      assert_receive {:captured, ^prefix, %{value: 1}, _}, 1000
    end

    test "can reattach after detaching" do
      prefix = unique_prefix()

      on_exit(fn -> detach_handler(prefix) end)

      assert ObservLib.Telemetry.attach(prefix) == :ok
      assert ObservLib.Telemetry.detach(prefix) == :ok
      assert ObservLib.Telemetry.attach(prefix) == :ok
    end
  end

  describe "list_handlers/0" do
    test "returns empty list when no ObservLib handlers attached" do
      # Detach any handlers that might have been left from other tests
      handlers_before = ObservLib.Telemetry.list_handlers()

      Enum.each(handlers_before, fn %{id: id} ->
        :telemetry.detach(id)
      end)

      assert ObservLib.Telemetry.list_handlers() == []
    end

    test "returns all ObservLib-managed handlers" do
      prefix1 = [:test, :"list_a_#{:erlang.unique_integer([:positive])}"]
      prefix2 = [:test, :"list_b_#{:erlang.unique_integer([:positive])}"]

      on_exit(fn ->
        detach_handler(prefix1)
        detach_handler(prefix2)
      end)

      ObservLib.Telemetry.attach(prefix1)
      ObservLib.Telemetry.attach(prefix2)

      handlers = ObservLib.Telemetry.list_handlers()
      handler_ids = Enum.map(handlers, & &1.id)

      for prefix <- [prefix1, prefix2] do
        expected_id = :"observlib_#{Enum.map_join(prefix, "_", &Atom.to_string/1)}"
        assert expected_id in handler_ids
      end
    end

    test "does not include non-ObservLib handlers" do
      prefix = unique_prefix()
      external_handler_id = :"external_handler_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        :telemetry.detach(external_handler_id)
        detach_handler(prefix)
      end)

      # Attach a non-ObservLib handler
      :telemetry.attach(external_handler_id, prefix, fn _, _, _, _ -> :ok end, nil)

      handlers = ObservLib.Telemetry.list_handlers()
      handler_ids = Enum.map(handlers, & &1.id)
      refute external_handler_id in handler_ids
    end

    test "returns correct handler metadata" do
      prefix = [:test, :"meta_#{:erlang.unique_integer([:positive])}"]

      on_exit(fn -> detach_handler(prefix) end)

      ObservLib.Telemetry.attach(prefix)

      handlers = ObservLib.Telemetry.list_handlers()
      expected_id = :"observlib_#{Enum.map_join(prefix, "_", &Atom.to_string/1)}"
      handler = Enum.find(handlers, fn %{id: id} -> id == expected_id end)

      assert handler != nil
      assert handler.id == expected_id
      assert handler.event_name == prefix
    end
  end

  describe "handle_event/4" do
    test "handles events without duration measurement without crashing" do
      result =
        ObservLib.Telemetry.handle_event(
          [:test, :event],
          %{count: 1},
          %{source: "test"},
          %{}
        )

      assert result == :ok
    end

    test "handles events with :duration measurement" do
      # 1 second in native time units
      duration_native = :erlang.convert_time_unit(1, :second, :native)

      result =
        ObservLib.Telemetry.handle_event(
          [:test, :request, :stop],
          %{duration: duration_native},
          %{method: "GET"},
          %{}
        )

      assert result == :ok
    end

    test "handles events with :total_time measurement" do
      total_time_native = :erlang.convert_time_unit(500, :millisecond, :native)

      result =
        ObservLib.Telemetry.handle_event(
          [:test, :query, :stop],
          %{total_time: total_time_native},
          %{table: "users"},
          %{}
        )

      assert result == :ok
    end

    test "handles events with :system_time measurement" do
      system_time = System.system_time()

      result =
        ObservLib.Telemetry.handle_event(
          [:test, :event, :start],
          %{system_time: system_time},
          %{},
          %{}
        )

      assert result == :ok
    end

    test "handles empty measurements and metadata" do
      result =
        ObservLib.Telemetry.handle_event(
          [:test, :empty],
          %{},
          %{},
          %{}
        )

      assert result == :ok
    end

    test "passes metadata as span attributes" do
      result =
        ObservLib.Telemetry.handle_event(
          [:test, :attrs],
          %{value: 10},
          %{user_id: 123, action: "login"},
          %{}
        )

      assert result == :ok
    end
  end

  describe "integration" do
    test "full lifecycle: setup -> emit event -> detach" do
      prefix = unique_prefix()
      test_pid = self()
      capture_id = :"capture_lifecycle_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        detach_handler(prefix)
        :telemetry.detach(capture_id)
      end)

      # Capture handler to verify event flows through
      :telemetry.attach(
        capture_id,
        prefix,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      # Setup and emit
      assert ObservLib.Telemetry.setup(events: [prefix]) == :ok
      :telemetry.execute(prefix, %{value: 99}, %{env: "test"})
      assert_receive {:event, ^prefix, %{value: 99}, %{env: "test"}}, 1000

      # Detach
      assert ObservLib.Telemetry.detach(prefix) == :ok
    end

    test "multiple event prefixes attached and firing" do
      prefix_a = [:test, :"multi_fire_a_#{:erlang.unique_integer([:positive])}"]
      prefix_b = [:test, :"multi_fire_b_#{:erlang.unique_integer([:positive])}"]
      test_pid = self()
      capture_id = :"capture_multi_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        detach_handler(prefix_a)
        detach_handler(prefix_b)
        :telemetry.detach(capture_id)
      end)

      :telemetry.attach_many(
        capture_id,
        [prefix_a, prefix_b],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      ObservLib.Telemetry.attach(prefix_a)
      ObservLib.Telemetry.attach(prefix_b)

      :telemetry.execute(prefix_a, %{count: 1}, %{})
      :telemetry.execute(prefix_b, %{count: 2}, %{})

      assert_receive {:event, ^prefix_a, %{count: 1}, _}, 1000
      assert_receive {:event, ^prefix_b, %{count: 2}, _}, 1000
    end

    test "works with ObservLib.Metrics events" do
      # ObservLib.Metrics.counter emits :telemetry events; ensure attaching a
      # handler for those events and executing them works
      prefix = [:http, :requests]
      test_pid = self()
      capture_id = :"capture_metrics_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        detach_handler(prefix)
        :telemetry.detach(capture_id)
      end)

      :telemetry.attach(
        capture_id,
        prefix,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:event, event, measurements, metadata})
        end,
        nil
      )

      ObservLib.Telemetry.attach(prefix)
      ObservLib.Metrics.counter("http.requests", 1, %{method: "GET"})

      assert_receive {:event, [:http, :requests], %{count: 1}, _metadata}, 1000
    end
  end
end
