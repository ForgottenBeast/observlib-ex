defmodule ObservLib.MetricsTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ObservLib.Metrics.MeterProvider

  setup do
    MeterProvider.reset()
    :ok
  end

  defp read(name) do
    metrics = MeterProvider.read_all()
    Enum.find(metrics, &(&1.name == name))
  end

  describe "counter/3" do
    test "increments counter with value" do
      ObservLib.Metrics.counter("http.requests", 1, %{method: "GET"})

      metric = read("http.requests")
      assert metric != nil
      assert metric.type == :counter
      assert metric.data.value == 1
    end

    test "accepts atom as metric name" do
      ObservLib.Metrics.counter(:api_calls, 5, %{endpoint: "/users"})

      metric = read("api_calls")
      assert metric != nil
      assert metric.type == :counter
      assert metric.data.value == 5
    end

    test "works with empty attributes" do
      ObservLib.Metrics.counter("http.requests", 1)

      metric = read("http.requests")
      assert metric != nil
      assert metric.data.value == 1
    end

    test "accepts float values" do
      ObservLib.Metrics.counter("http.requests", 1.5, %{method: "POST"})

      metric = read("http.requests")
      assert metric != nil
      assert_in_delta metric.data.value, 1.5, 0.001
    end

    test "requires non-negative value" do
      assert_raise FunctionClauseError, fn ->
        ObservLib.Metrics.counter("http.requests", -1, %{})
      end
    end

    test "accumulates multiple increments" do
      ObservLib.Metrics.counter("http.requests", 1, %{method: "GET"})
      ObservLib.Metrics.counter("http.requests", 2, %{method: "GET"})

      metric = read("http.requests")
      assert metric.data.value == 3
    end
  end

  describe "gauge/3" do
    test "sets gauge value" do
      ObservLib.Metrics.gauge("memory.usage", 1024.5, %{type: "heap"})

      metric = read("memory.usage")
      assert metric != nil
      assert metric.type == :gauge
      assert_in_delta metric.data.value, 1024.5, 0.001
    end

    test "accepts atom as metric name" do
      ObservLib.Metrics.gauge(:queue_depth, 42, %{queue: "default"})

      metric = read("queue_depth")
      assert metric != nil
      assert metric.type == :gauge
      assert metric.data.value == 42
    end

    test "works with empty attributes" do
      ObservLib.Metrics.gauge("memory.usage", 2048)

      metric = read("memory.usage")
      assert metric != nil
      assert metric.data.value == 2048
    end

    test "accepts negative values" do
      ObservLib.Metrics.gauge("temperature", -10.5, %{location: "outside"})

      metric = read("temperature")
      assert metric != nil
      assert_in_delta metric.data.value, -10.5, 0.001
    end

    test "accepts zero value" do
      ObservLib.Metrics.gauge("memory.usage", 0, %{})

      metric = read("memory.usage")
      assert metric != nil
      assert metric.data.value == 0
    end

    test "last write wins" do
      ObservLib.Metrics.gauge("memory.usage", 100)
      ObservLib.Metrics.gauge("memory.usage", 200)

      metric = read("memory.usage")
      assert metric.data.value == 200
    end
  end

  describe "histogram/3" do
    test "records histogram observation" do
      ObservLib.Metrics.histogram("http.request.duration", 45.2, %{method: "GET"})

      metric = read("http.request.duration")
      assert metric != nil
      assert metric.type == :histogram
      assert metric.data.count == 1
      assert_in_delta metric.data.sum, 45.2, 0.001
    end

    test "accepts atom as metric name" do
      ObservLib.Metrics.histogram(:db_query_time, 123.4, %{table: "users"})

      metric = read("db_query_time")
      assert metric != nil
      assert metric.type == :histogram
      assert metric.data.count == 1
    end

    test "works with empty attributes" do
      ObservLib.Metrics.histogram("http.request.duration", 100.0)

      metric = read("http.request.duration")
      assert metric != nil
      assert_in_delta metric.data.sum, 100.0, 0.001
    end

    test "accepts integer values" do
      ObservLib.Metrics.histogram("http.request.duration", 50, %{})

      metric = read("http.request.duration")
      assert metric.data.sum == 50
    end

    test "accumulates multiple observations" do
      ObservLib.Metrics.histogram("http.request.duration", 10.0)
      ObservLib.Metrics.histogram("http.request.duration", 20.0)
      ObservLib.Metrics.histogram("http.request.duration", 30.0)

      metric = read("http.request.duration")
      assert metric.data.count == 3
      assert_in_delta metric.data.sum, 60.0, 0.001
      assert_in_delta metric.data.min, 10.0, 0.001
      assert_in_delta metric.data.max, 30.0, 0.001
    end
  end

  describe "up_down_counter/3" do
    test "increments up-down counter" do
      ObservLib.Metrics.up_down_counter("active.connections", 1, %{protocol: "http"})

      metric = read("active.connections")
      assert metric != nil
      assert metric.type == :up_down_counter
      assert metric.data.value == 1
    end

    test "decrements up-down counter" do
      ObservLib.Metrics.up_down_counter("active.connections", 5)
      ObservLib.Metrics.up_down_counter("active.connections", -2)

      metric = read("active.connections")
      assert metric.data.value == 3
    end

    test "accepts atom as metric name" do
      ObservLib.Metrics.up_down_counter(:api_calls, 3, %{})

      metric = read("api_calls")
      assert metric != nil
      assert metric.data.value == 3
    end

    test "works with empty attributes" do
      ObservLib.Metrics.up_down_counter("active.connections", 5)

      metric = read("active.connections")
      assert metric.data.value == 5
    end

    test "accepts zero value" do
      ObservLib.Metrics.up_down_counter("active.connections", 0, %{})

      metric = read("active.connections")
      assert metric != nil
      assert metric.data.value == 0
    end
  end

  describe "re-entry safety (regression: normatix-cjsdh.60)" do
    test "counter called from a telemetry handler does not recurse" do
      call_count = :counters.new(1, [])
      test_pid = self()

      :telemetry.attach(
        :reentry_regression_test,
        [:oban, :job, :exception],
        fn _event, _m, _meta, _cfg ->
          :counters.add(call_count, 1, 1)
          # metric name maps to the same event name — used to cause infinite recursion
          ObservLib.Metrics.counter("oban.job.exception", 1, %{})
          send(test_pid, :handler_called)
        end,
        nil
      )

      :telemetry.execute([:oban, :job, :exception], %{}, %{})

      assert_receive :handler_called, 1000
      assert :counters.get(call_count, 1) == 1

      :telemetry.detach(:reentry_regression_test)
    end

    test "counter does not emit a telemetry event" do
      test_pid = self()

      :telemetry.attach(
        :no_reemit_test,
        [:http, :requests],
        fn _event, _m, _meta, _cfg ->
          send(test_pid, :unexpected_event)
        end,
        nil
      )

      ObservLib.Metrics.counter("http.requests", 1)

      refute_receive :unexpected_event, 100

      :telemetry.detach(:no_reemit_test)
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
      assert List.first(matching).opts[:unit] == :byte
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
    test "returns a list" do
      assert is_list(ObservLib.Metrics.list_registered_metrics())
    end

    test "returns all registered metrics" do
      ObservLib.Metrics.register_counter("http.requests", unit: :count)
      ObservLib.Metrics.register_gauge("memory.usage", unit: :byte)
      ObservLib.Metrics.register_histogram("http.request.duration", unit: :millisecond)

      names = ObservLib.Metrics.list_registered_metrics() |> Enum.map(& &1.name)
      assert "http.requests" in names
      assert "memory.usage" in names
      assert "http.request.duration" in names
    end

    test "shows most recent registration when metric re-registered" do
      ObservLib.Metrics.register_counter("http.requests", unit: :count)
      ObservLib.Metrics.register_counter("http.requests", unit: :byte)

      matching =
        ObservLib.Metrics.list_registered_metrics()
        |> Enum.filter(&(&1.name == "http.requests"))

      assert length(matching) == 1
      assert List.first(matching).opts[:unit] == :byte
    end
  end

  describe "property-based tests" do
    property "counter stores positive values in ETS" do
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
        name = "prop.counter.#{:erlang.unique_integer([:positive])}"
        ObservLib.Metrics.counter(name, value, attrs)

        metric = read(name)
        assert metric != nil
        assert metric.type == :counter
        assert metric.data.value == value
      end
    end

    property "gauge stores any numeric value in ETS" do
      check all(
              value <- float(min: -1000.0, max: 1000.0),
              attrs <- map_of(string(:alphanumeric, min_length: 1), string(:printable))
            ) do
        name = "prop.gauge.#{:erlang.unique_integer([:positive])}"
        ObservLib.Metrics.gauge(name, value, attrs)

        metric = read(name)
        assert metric != nil
        assert metric.type == :gauge
        assert_in_delta metric.data.value, value, 0.001
      end
    end

    property "histogram stores any numeric value in ETS" do
      check all(value <- float(min: 0.0, max: 10_000.0)) do
        name = "prop.histogram.#{:erlang.unique_integer([:positive])}"
        ObservLib.Metrics.histogram(name, value)

        metric = read(name)
        assert metric != nil
        assert metric.type == :histogram
        assert_in_delta metric.data.sum, value, 0.001
      end
    end

    property "up_down_counter accepts positive and negative values" do
      check all(value <- integer(-100..100)) do
        name = "prop.updown.#{:erlang.unique_integer([:positive])}"
        ObservLib.Metrics.up_down_counter(name, value)

        metric = read(name)
        assert metric != nil
        assert metric.type == :up_down_counter
        assert metric.data.value == value
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
      for i <- 1..1000 do
        ObservLib.Metrics.counter("test.metric.security.#{i}.#{:erlang.unique_integer([:positive])}", 1, %{test: "security"})
      end

      # VM still functional; a fixed name records correctly
      ObservLib.Metrics.counter("http.requests", 1, %{test: "after_stress"})
      metric = read("http.requests")
      assert metric != nil
    end

    @tag :security
    test "reuses metric without errors on repeated calls" do
      ObservLib.Metrics.counter("http.requests", 1)
      ObservLib.Metrics.counter("http.requests", 1)

      metric = read("http.requests")
      assert metric.data.value == 2
    end

    @tag :security
    test "validates handler_id input is atoms only" do
      valid_prefix = [:my, :app, :event]
      assert :ok = ObservLib.Telemetry.attach(valid_prefix)
      ObservLib.Telemetry.detach(valid_prefix)
    end
  end
end
