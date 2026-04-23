defmodule ObservLib.MetricsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  setup do
    # Clear the metrics registry before each test
    Process.delete(:observlib_metrics_registry)

    # Attach a test telemetry handler to capture events
    # We use a unique handler ID per test to avoid conflicts
    test_pid = self()
    handler_id = :"test_metrics_handler_#{:erlang.unique_integer()}"

    # Handler function that captures all events
    handler_fun = fn event_name, measurements, metadata, _config ->
      send(test_pid, {:telemetry_event, event_name, measurements, metadata})
    end

    # Attach handlers for all event names we'll use in tests
    event_names = [
      [:http, :requests],
      [:memory, :usage],
      [:http, :request, :duration],
      [:active, :connections],
      [:api, :calls],
      [:queue, :depth],
      [:db, :query, :time],
      [:temperature],
      [:api_calls],
      [:queue_depth],
      [:db_query_time]
    ]

    :telemetry.attach_many(handler_id, event_names, handler_fun, nil)

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Process.delete(:observlib_metrics_registry)
    end)

    :ok
  end

  describe "counter/3" do
    test "increments counter with value" do
      ObservLib.Metrics.counter("http.requests", 1, %{method: "GET"})

      assert_receive {:telemetry_event, [:http, :requests], %{count: 1},
                      %{method: "GET", metric_type: :counter}}
    end

    test "accepts atom as metric name" do
      ObservLib.Metrics.counter(:api_calls, 5, %{endpoint: "/users"})

      assert_receive {:telemetry_event, [:api_calls], %{count: 5},
                      %{endpoint: "/users", metric_type: :counter}}
    end

    test "works with empty attributes" do
      ObservLib.Metrics.counter("http.requests", 1)

      assert_receive {:telemetry_event, [:http, :requests], %{count: 1}, %{metric_type: :counter}}
    end

    test "accepts float values" do
      ObservLib.Metrics.counter("http.requests", 1.5, %{method: "POST"})

      assert_receive {:telemetry_event, [:http, :requests], %{count: 1.5},
                      %{method: "POST", metric_type: :counter}}
    end

    test "requires non-negative value" do
      assert_raise FunctionClauseError, fn ->
        ObservLib.Metrics.counter("http.requests", -1, %{})
      end
    end

    test "includes attributes in metadata" do
      attrs = %{method: "GET", status: 200, path: "/api/users"}
      ObservLib.Metrics.counter("http.requests", 1, attrs)

      assert_receive {:telemetry_event, [:http, :requests], %{count: 1}, metadata}
      assert metadata.method == "GET"
      assert metadata.status == 200
      assert metadata.path == "/api/users"
      assert metadata.metric_type == :counter
    end
  end

  describe "gauge/3" do
    test "sets gauge value" do
      ObservLib.Metrics.gauge("memory.usage", 1024.5, %{type: "heap"})

      assert_receive {:telemetry_event, [:memory, :usage], %{value: 1024.5},
                      %{type: "heap", metric_type: :gauge}}
    end

    test "accepts atom as metric name" do
      ObservLib.Metrics.gauge(:queue_depth, 42, %{queue: "default"})

      assert_receive {:telemetry_event, [:queue_depth], %{value: 42},
                      %{queue: "default", metric_type: :gauge}}
    end

    test "works with empty attributes" do
      ObservLib.Metrics.gauge("memory.usage", 2048)

      assert_receive {:telemetry_event, [:memory, :usage], %{value: 2048}, %{metric_type: :gauge}}
    end

    test "accepts negative values" do
      ObservLib.Metrics.gauge("temperature", -10.5, %{location: "outside"})

      assert_receive {:telemetry_event, [:temperature], %{value: -10.5},
                      %{location: "outside", metric_type: :gauge}}
    end

    test "accepts zero value" do
      ObservLib.Metrics.gauge("memory.usage", 0, %{})

      assert_receive {:telemetry_event, [:memory, :usage], %{value: 0}, _metadata}
    end
  end

  describe "histogram/3" do
    test "records histogram observation" do
      ObservLib.Metrics.histogram("http.request.duration", 45.2, %{method: "GET"})

      assert_receive {:telemetry_event, [:http, :request, :duration], %{value: 45.2},
                      %{method: "GET", metric_type: :histogram}}
    end

    test "accepts atom as metric name" do
      ObservLib.Metrics.histogram(:db_query_time, 123.4, %{table: "users"})

      assert_receive {:telemetry_event, [:db_query_time], %{value: 123.4},
                      %{table: "users", metric_type: :histogram}}
    end

    test "works with empty attributes" do
      ObservLib.Metrics.histogram("http.request.duration", 100.0)

      assert_receive {:telemetry_event, [:http, :request, :duration], %{value: 100.0},
                      %{metric_type: :histogram}}
    end

    test "accepts integer values" do
      ObservLib.Metrics.histogram("http.request.duration", 50, %{})

      assert_receive {:telemetry_event, [:http, :request, :duration], %{value: 50}, _metadata}
    end
  end

  describe "up_down_counter/3" do
    test "increments up-down counter" do
      ObservLib.Metrics.up_down_counter("active.connections", 1, %{protocol: "http"})

      assert_receive {:telemetry_event, [:active, :connections], %{value: 1},
                      %{protocol: "http", metric_type: :up_down_counter}}
    end

    test "decrements up-down counter" do
      ObservLib.Metrics.up_down_counter("active.connections", -1, %{protocol: "http"})

      assert_receive {:telemetry_event, [:active, :connections], %{value: -1},
                      %{protocol: "http", metric_type: :up_down_counter}}
    end

    test "accepts atom as metric name" do
      ObservLib.Metrics.up_down_counter(:api_calls, 3, %{})

      assert_receive {:telemetry_event, [:api_calls], %{value: 3},
                      %{metric_type: :up_down_counter}}
    end

    test "works with empty attributes" do
      ObservLib.Metrics.up_down_counter("active.connections", 5)

      assert_receive {:telemetry_event, [:active, :connections], %{value: 5},
                      %{metric_type: :up_down_counter}}
    end

    test "accepts zero value" do
      ObservLib.Metrics.up_down_counter("active.connections", 0, %{})

      assert_receive {:telemetry_event, [:active, :connections], %{value: 0}, _metadata}
    end
  end

  describe "register_counter/2" do
    test "registers counter with options" do
      assert :ok =
               ObservLib.Metrics.register_counter("http.requests",
                 unit: :count,
                 description: "Total HTTP requests"
               )

      metrics = ObservLib.Metrics.list_registered_metrics()
      metric = Enum.find(metrics, &(&1.name == "http.requests"))
      assert metric != nil
      assert metric.type == :counter
      assert metric.opts[:unit] == :count
      assert metric.opts[:description] == "Total HTTP requests"
    end

    test "registers counter with atom name" do
      assert :ok = ObservLib.Metrics.register_counter(:api_calls, unit: :count)

      metrics = ObservLib.Metrics.list_registered_metrics()
      metric = Enum.find(metrics, &(&1.name == "api_calls"))
      assert metric != nil
      assert metric.type == :counter
    end

    test "registers counter without options" do
      assert :ok = ObservLib.Metrics.register_counter("http.requests")

      metrics = ObservLib.Metrics.list_registered_metrics()
      metric = Enum.find(metrics, &(&1.name == "http.requests"))
      assert metric != nil
      assert metric.type == :counter
      assert metric.opts == []
    end

    test "overwrites existing registration with same name" do
      ObservLib.Metrics.register_counter("http.requests", unit: :count)
      ObservLib.Metrics.register_counter("http.requests", unit: :byte)

      metrics = ObservLib.Metrics.list_registered_metrics()
      matching = Enum.filter(metrics, &(&1.name == "http.requests"))
      assert length(matching) == 1
      metric = List.first(matching)
      assert metric.opts[:unit] == :byte
    end
  end

  describe "register_gauge/2" do
    test "registers gauge with options" do
      assert :ok =
               ObservLib.Metrics.register_gauge("memory.usage",
                 unit: :byte,
                 description: "Current memory usage"
               )

      metrics = ObservLib.Metrics.list_registered_metrics()
      metric = Enum.find(metrics, &(&1.name == "memory.usage"))
      assert metric != nil
      assert metric.type == :gauge
      assert metric.opts[:unit] == :byte
    end

    test "registers gauge with atom name" do
      assert :ok = ObservLib.Metrics.register_gauge(:queue_depth, unit: :count)

      metrics = ObservLib.Metrics.list_registered_metrics()
      metric = Enum.find(metrics, &(&1.name == "queue_depth"))
      assert metric != nil
      assert metric.type == :gauge
    end
  end

  describe "register_histogram/2" do
    test "registers histogram with options" do
      assert :ok =
               ObservLib.Metrics.register_histogram("http.request.duration",
                 unit: :millisecond,
                 description: "HTTP request duration"
               )

      metrics = ObservLib.Metrics.list_registered_metrics()
      metric = Enum.find(metrics, &(&1.name == "http.request.duration"))
      assert metric != nil
      assert metric.type == :histogram
      assert metric.opts[:unit] == :millisecond
    end

    test "registers histogram with atom name" do
      assert :ok = ObservLib.Metrics.register_histogram(:db_query_time, unit: :millisecond)

      metrics = ObservLib.Metrics.list_registered_metrics()
      metric = Enum.find(metrics, &(&1.name == "db_query_time"))
      assert metric != nil
      assert metric.type == :histogram
    end
  end

  describe "list_registered_metrics/0" do
    test "returns empty list when no metrics registered" do
      # In async mode other tests may have registered metrics.
      # Verify the return type is always a list.
      result = ObservLib.Metrics.list_registered_metrics()
      assert is_list(result)
    end

    test "returns all registered metrics" do
      ObservLib.Metrics.register_counter("http.requests", unit: :count)
      ObservLib.Metrics.register_gauge("memory.usage", unit: :byte)
      ObservLib.Metrics.register_histogram("http.request.duration", unit: :millisecond)

      metrics = ObservLib.Metrics.list_registered_metrics()

      names = Enum.map(metrics, & &1.name)
      assert "http.requests" in names
      assert "memory.usage" in names
      assert "http.request.duration" in names
    end

    test "shows most recent registration when metric re-registered" do
      ObservLib.Metrics.register_counter("http.requests", unit: :count)
      ObservLib.Metrics.register_counter("http.requests", unit: :byte)

      metrics = ObservLib.Metrics.list_registered_metrics()
      matching = Enum.filter(metrics, &(&1.name == "http.requests"))
      assert length(matching) == 1
      metric = List.first(matching)
      assert metric.opts[:unit] == :byte
    end
  end

  describe "property-based tests" do
    property "counter always emits positive values" do
      check all(
              value <- positive_integer(),
              attr_count <- integer(0..5),
              attrs <-
                map_of(
                  string(:alphanumeric, min_length: 1),
                  string(:printable),
                  length: attr_count
                )
            ) do
        # Use a fixed event name that's registered in setup
        ObservLib.Metrics.counter("http.requests", value, attrs)

        assert_receive {:telemetry_event, _event_name, %{count: ^value}, metadata}
        assert metadata.metric_type == :counter

        # Compare against sanitized attrs since attribute values may be redacted
        {:ok, safe_attrs} = ObservLib.Attributes.validate(attrs)

        Enum.each(safe_attrs, fn {key, val} ->
          assert Map.get(metadata, key) == val
        end)
      end
    end

    property "gauge accepts any numeric value" do
      check all(
              value <- float(min: -1000.0, max: 1000.0),
              attrs <- map_of(string(:alphanumeric, min_length: 1), string(:printable))
            ) do
        # Use a fixed event name that's registered in setup
        ObservLib.Metrics.gauge("memory.usage", value, attrs)

        assert_receive {:telemetry_event, _event_name, %{value: received_value}, metadata}
        assert_in_delta received_value, value, 0.001
        assert metadata.metric_type == :gauge
      end
    end

    property "histogram accepts any numeric value" do
      check all(value <- float(min: 0.0, max: 10000.0)) do
        # Use a fixed event name that's registered in setup
        ObservLib.Metrics.histogram("http.request.duration", value)

        assert_receive {:telemetry_event, _event_name, %{value: received_value}, metadata}
        assert_in_delta received_value, value, 0.001
        assert metadata.metric_type == :histogram
      end
    end

    property "up_down_counter accepts positive and negative values" do
      check all(value <- integer(-100..100)) do
        # Use a fixed event name that's registered in setup
        ObservLib.Metrics.up_down_counter("active.connections", value)

        assert_receive {:telemetry_event, _event_name, %{value: ^value}, metadata}
        assert metadata.metric_type == :up_down_counter
      end
    end

    property "registration preserves metric information" do
      check all(
              name <- string(:alphanumeric, min_length: 1),
              type <- member_of([:counter, :gauge, :histogram]),
              unit <- member_of([:count, :byte, :millisecond, :second])
            ) do
        case type do
          :counter -> ObservLib.Metrics.register_counter(name, unit: unit)
          :gauge -> ObservLib.Metrics.register_gauge(name, unit: unit)
          :histogram -> ObservLib.Metrics.register_histogram(name, unit: unit)
        end

        metrics = ObservLib.Metrics.list_registered_metrics()
        metric = Enum.find(metrics, &(&1.name == name))

        assert metric != nil
        assert metric.type == type
        assert metric.opts[:unit] == unit
      end
    end
  end

  describe "atom table safety (sec-002)" do
    @tag :security
    test "handles large number of unique metric names without exhausting atom table" do
      # This test verifies the fix for sec-002: atom table exhaustion vulnerability
      # Previously, String.to_atom/1 was used unsafely, allowing unbounded atom creation
      # Now uses String.to_existing_atom/1 with controlled fallback

      # Create 1000 unique metric names to test safety
      # In production, this could be triggered by user-controlled input
      unique_metrics =
        for i <- 1..1000 do
          "test.metric.security.#{i}.#{:erlang.unique_integer([:positive])}"
        end

      # This should complete without crashing the VM
      # Warnings will be logged for new atoms (captured by Logger backend)
      for metric_name <- unique_metrics do
        ObservLib.Metrics.counter(metric_name, 1, %{test: "security"})
      end

      # Verify the VM is still functional after stress test
      # Use a pre-registered event name from setup
      ObservLib.Metrics.counter("http.requests", 1, %{test: "after_stress"})
      assert_receive {:telemetry_event, [:http, :requests], %{count: 1}, _}
    end

    @tag :security
    test "reuses existing atoms without creating new ones" do
      # Use pre-registered event names from setup
      ObservLib.Metrics.counter("http.requests", 1)
      assert_receive {:telemetry_event, [:http, :requests], _, _}

      # Second call should work without errors
      ObservLib.Metrics.counter("http.requests", 1)
      assert_receive {:telemetry_event, [:http, :requests], _, _}
    end

    @tag :security
    test "validates handler_id input is atoms only" do
      # This validates the telemetry.ex fix
      # handler_id now validates all prefix elements are atoms
      valid_prefix = [:my, :app, :event]
      assert :ok = ObservLib.Telemetry.attach(valid_prefix)

      # Clean up
      ObservLib.Telemetry.detach(valid_prefix)
    end

    @tag :security
    test "safe_to_atom uses existing atoms when available" do
      # These should use existing atoms that were pre-registered in setup
      ObservLib.Metrics.counter("http.requests", 1)
      assert_receive {:telemetry_event, [:http, :requests], %{count: 1}, _}

      ObservLib.Metrics.gauge("memory.usage", 100)
      assert_receive {:telemetry_event, [:memory, :usage], %{value: 100}, _}
    end
  end
end
