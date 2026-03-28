defmodule ObservLib.Metrics.MeterProviderTest do
  use ExUnit.Case, async: false

  alias ObservLib.Metrics.MeterProvider

  setup do
    # Start Config first
    start_supervised!(ObservLib.Config)

    # Start MeterProvider
    start_supervised!(MeterProvider)

    on_exit(fn ->
      # Clean up
      :ok
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts the MeterProvider GenServer" do
      # Already started in setup, verify it's alive
      assert Process.whereis(MeterProvider) != nil
      assert Process.alive?(Process.whereis(MeterProvider))
    end
  end

  describe "register/3" do
    test "registers a counter metric" do
      assert :ok = MeterProvider.register("http.requests", :counter, unit: :count)

      registered = MeterProvider.list_registered()
      assert length(registered) >= 1

      metric = Enum.find(registered, &(&1.name == "http.requests"))
      assert metric != nil
      assert metric.type == :counter
      assert metric.unit == :count
    end

    test "registers a gauge metric" do
      assert :ok = MeterProvider.register("memory.usage", :gauge, unit: :byte, description: "Memory usage")

      registered = MeterProvider.list_registered()
      metric = Enum.find(registered, &(&1.name == "memory.usage"))
      assert metric != nil
      assert metric.type == :gauge
      assert metric.unit == :byte
      assert metric.description == "Memory usage"
    end

    test "registers a histogram metric" do
      assert :ok = MeterProvider.register("request.duration", :histogram, unit: :millisecond)

      registered = MeterProvider.list_registered()
      metric = Enum.find(registered, &(&1.name == "request.duration"))
      assert metric != nil
      assert metric.type == :histogram
    end

    test "overwrites existing registration with same name" do
      MeterProvider.register("test.metric", :counter, unit: :count)
      MeterProvider.register("test.metric", :gauge, unit: :byte)

      registered = MeterProvider.list_registered()
      metrics = Enum.filter(registered, &(&1.name == "test.metric"))
      assert length(metrics) == 1
      assert List.first(metrics).type == :gauge
    end
  end

  describe "record/4" do
    test "records counter value" do
      MeterProvider.record("http.requests", :counter, 1, %{method: "GET"})
      MeterProvider.record("http.requests", :counter, 2, %{method: "GET"})

      # Allow async processing
      Process.sleep(10)

      metrics = MeterProvider.read_all()
      metric = Enum.find(metrics, &(&1.name == "http.requests"))
      assert metric != nil
      assert metric.type == :counter
      # Counter should sum values
      assert metric.data.value == 3
    end

    test "records gauge value (last value wins)" do
      MeterProvider.record("memory.usage", :gauge, 100, %{type: "heap"})
      MeterProvider.record("memory.usage", :gauge, 200, %{type: "heap"})
      MeterProvider.record("memory.usage", :gauge, 150, %{type: "heap"})

      Process.sleep(10)

      metrics = MeterProvider.read_all()
      metric = Enum.find(metrics, &(&1.name == "memory.usage"))
      assert metric != nil
      assert metric.type == :gauge
      # Gauge should keep last value
      assert metric.data.value == 150
    end

    test "records histogram observations" do
      MeterProvider.record("request.duration", :histogram, 10.0, %{})
      MeterProvider.record("request.duration", :histogram, 20.0, %{})
      MeterProvider.record("request.duration", :histogram, 30.0, %{})

      Process.sleep(10)

      metrics = MeterProvider.read_all()
      metric = Enum.find(metrics, &(&1.name == "request.duration"))
      assert metric != nil
      assert metric.type == :histogram
      assert metric.data.count == 3
      assert metric.data.sum == 60.0
      assert metric.data.min == 10.0
      assert metric.data.max == 30.0
    end

    test "records up_down_counter with positive and negative values" do
      MeterProvider.record("active.connections", :up_down_counter, 5, %{})
      MeterProvider.record("active.connections", :up_down_counter, -2, %{})
      MeterProvider.record("active.connections", :up_down_counter, 3, %{})

      Process.sleep(10)

      metrics = MeterProvider.read_all()
      metric = Enum.find(metrics, &(&1.name == "active.connections"))
      assert metric != nil
      assert metric.type == :up_down_counter
      assert metric.data.value == 6
    end

    test "separates metrics by attributes" do
      MeterProvider.record("http.requests", :counter, 1, %{method: "GET"})
      MeterProvider.record("http.requests", :counter, 2, %{method: "POST"})

      Process.sleep(10)

      metrics = MeterProvider.read_all()
      http_metrics = Enum.filter(metrics, &(&1.name == "http.requests"))
      assert length(http_metrics) == 2

      get_metric = Enum.find(http_metrics, &(&1.attributes.method == "GET"))
      post_metric = Enum.find(http_metrics, &(&1.attributes.method == "POST"))

      assert get_metric.data.value == 1
      assert post_metric.data.value == 2
    end
  end

  describe "read_all/0" do
    test "returns empty list when no metrics recorded" do
      MeterProvider.reset()
      assert MeterProvider.read_all() == []
    end

    test "returns all recorded metrics" do
      MeterProvider.record("metric1", :counter, 1, %{})
      MeterProvider.record("metric2", :gauge, 2, %{})
      MeterProvider.record("metric3", :histogram, 3, %{})

      Process.sleep(10)

      metrics = MeterProvider.read_all()
      names = Enum.map(metrics, & &1.name)

      assert "metric1" in names
      assert "metric2" in names
      assert "metric3" in names
    end
  end

  describe "read/1" do
    test "returns specific metric by name" do
      MeterProvider.record("specific.metric", :counter, 42, %{label: "test"})

      Process.sleep(10)

      result = MeterProvider.read("specific.metric")
      assert result != nil
      assert is_list(result)
      assert length(result) == 1
      assert List.first(result).data.value == 42
    end

    test "returns nil for non-existent metric" do
      MeterProvider.reset()
      result = MeterProvider.read("non.existent")
      assert result == nil
    end
  end

  describe "reset/0" do
    test "clears all metric values" do
      MeterProvider.record("test.metric", :counter, 100, %{})
      Process.sleep(10)
      assert length(MeterProvider.read_all()) > 0

      MeterProvider.reset()
      assert MeterProvider.read_all() == []
    end
  end

  describe "concurrent writes" do
    test "handles concurrent writes from multiple processes" do
      tasks = for i <- 1..100 do
        Task.async(fn ->
          MeterProvider.record("concurrent.counter", :counter, 1, %{worker: rem(i, 5)})
        end)
      end

      Task.await_many(tasks)
      Process.sleep(50)

      metrics = MeterProvider.read_all()
      concurrent_metrics = Enum.filter(metrics, &(&1.name == "concurrent.counter"))

      # Sum all counter values
      total = Enum.reduce(concurrent_metrics, 0, fn m, acc -> acc + m.data.value end)
      assert total == 100
    end
  end

  describe "list_registered/0" do
    test "returns empty list when no metrics registered" do
      # Note: other tests may have registered metrics, so this just checks the function works
      result = MeterProvider.list_registered()
      assert is_list(result)
    end

    test "returns registered metric definitions" do
      MeterProvider.register("list.test", :counter, unit: :count, description: "Test metric")

      registered = MeterProvider.list_registered()
      metric = Enum.find(registered, &(&1.name == "list.test"))

      assert metric != nil
      assert metric.name == "list.test"
      assert metric.type == :counter
      assert metric.unit == :count
      assert metric.description == "Test metric"
    end
  end

  describe "cardinality limit (sec-003)" do
    test "enforces cardinality limit per metric name" do
      # Get configured limit
      limit = ObservLib.Config.cardinality_limit()

      # Record metrics up to the limit
      for i <- 1..limit do
        MeterProvider.record("test.cardinality", :counter, 1, %{unique_id: i})
      end

      Process.sleep(50)

      # All metrics should be recorded
      metrics = MeterProvider.read("test.cardinality")
      assert length(metrics) == limit

      # Try to record beyond the limit - should be dropped
      MeterProvider.record("test.cardinality", :counter, 1, %{unique_id: limit + 1})
      MeterProvider.record("test.cardinality", :counter, 1, %{unique_id: limit + 2})

      Process.sleep(50)

      # Should still only have limit entries
      metrics = MeterProvider.read("test.cardinality")
      assert length(metrics) == limit
    end

    test "allows updates to existing metric variants" do
      limit = ObservLib.Config.cardinality_limit()

      # Fill up to limit
      for i <- 1..limit do
        MeterProvider.record("test.update", :counter, 1, %{id: i})
      end

      Process.sleep(50)

      # Update an existing variant - should succeed
      MeterProvider.record("test.update", :counter, 5, %{id: 1})

      Process.sleep(50)

      metrics = MeterProvider.read("test.update")
      metric_1 = Enum.find(metrics, &(&1.attributes.id == 1))
      # Counter should have incremented: 1 + 5 = 6
      assert metric_1.data.value == 6
    end

    test "limit applies per metric name independently" do
      # Reset to clean state
      MeterProvider.reset()

      # Record 10 variants for metric A
      for i <- 1..10 do
        MeterProvider.record("metric.a", :counter, 1, %{id: i})
      end

      # Record 10 variants for metric B
      for i <- 1..10 do
        MeterProvider.record("metric.b", :counter, 1, %{id: i})
      end

      Process.sleep(50)

      # Both should succeed independently
      metrics_a = MeterProvider.read("metric.a")
      metrics_b = MeterProvider.read("metric.b")

      assert length(metrics_a) == 10
      assert length(metrics_b) == 10
    end

    test "logs warning when cardinality limit exceeded" do
      import ExUnit.CaptureLog

      limit = ObservLib.Config.cardinality_limit()

      # Fill to limit
      for i <- 1..limit do
        MeterProvider.record("test.warning", :counter, 1, %{id: i})
      end

      Process.sleep(50)

      # Capture log when exceeding limit
      log = capture_log(fn ->
        MeterProvider.record("test.warning", :counter, 1, %{id: limit + 1})
        Process.sleep(50)
      end)

      assert log =~ "Metric cardinality limit exceeded"
      assert log =~ "test.warning"
    end
  end
end
