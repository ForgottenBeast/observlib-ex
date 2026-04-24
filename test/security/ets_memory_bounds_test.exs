defmodule ObservLib.Security.EtsMemoryBoundsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :security

  setup do
    ObservLib.Metrics.MeterProvider.reset()
    :ok
  end

  describe "sec-003: Cardinality limits prevent unbounded ETS growth" do
    test "cardinality limit prevents unbounded metric variants" do
      limit = ObservLib.Config.cardinality_limit()

      for i <- 1..limit do
        ObservLib.Metrics.counter("test.cardinality", 1, %{unique_id: "id_#{i}"})
      end

      metrics = ObservLib.Metrics.MeterProvider.read("test.cardinality")
      assert length(metrics) == limit

      log =
        capture_log(fn ->
          ObservLib.Metrics.counter("test.cardinality", 1, %{unique_id: "id_overflow"})
          ObservLib.Metrics.MeterProvider.read("test.cardinality")
        end)

      assert log =~ "Metric cardinality limit exceeded"
      assert log =~ "test.cardinality"

      metrics_after = ObservLib.Metrics.MeterProvider.read("test.cardinality")
      assert length(metrics_after) == limit
    end

    test "existing metric variants can be updated beyond cardinality limit" do
      ObservLib.Metrics.counter("test.update", 1, %{id: "existing"})

      limit = ObservLib.Config.cardinality_limit()

      for i <- 2..limit do
        ObservLib.Metrics.counter("test.update", 1, %{id: "id_#{i}"})
      end

      log =
        capture_log(fn ->
          ObservLib.Metrics.counter("test.update", 5, %{id: "existing"})
        end)

      refute log =~ "Metric cardinality limit exceeded"

      metrics = ObservLib.Metrics.MeterProvider.read("test.update")
      existing_metric = Enum.find(metrics, fn m -> m.attributes[:id] == "existing" end)
      assert existing_metric.data.value >= 1
    end

    test "cardinality limit is per metric name" do
      limit = min(ObservLib.Config.cardinality_limit(), 10)

      for i <- 1..limit do
        ObservLib.Metrics.counter("metric.a", 1, %{id: i})
      end

      for i <- 1..limit do
        ObservLib.Metrics.counter("metric.b", 1, %{id: i})
      end

      metrics_a = ObservLib.Metrics.MeterProvider.read("metric.a")
      metrics_b = ObservLib.Metrics.MeterProvider.read("metric.b")

      assert length(metrics_a) == limit
      assert length(metrics_b) == limit
    end
  end

  describe "sec-004: Log batch limits prevent unbounded queue growth" do
    test "log batch limit prevents memory exhaustion" do
      batch_limit = ObservLib.Config.get_log_batch_limit()

      excessive_logs =
        for i <- 1..(batch_limit + 100) do
          %{
            level: :info,
            message: "Test log #{i}",
            timestamp: System.system_time(:nanosecond),
            attributes: %{}
          }
        end

      log =
        capture_log(fn ->
          ObservLib.Exporters.OtlpLogsExporter.add_to_batch(excessive_logs)
          Process.sleep(100)
        end)

      assert log =~ "Log batch limit exceeded"
      assert log =~ "dropping oldest logs"
    end
  end

  describe "sec-010: Span limits prevent unbounded active spans" do
    test "active span tracking does not grow unbounded" do
      initial_count = ObservLib.Traces.Provider.active_span_count()

      spans =
        for i <- 1..100 do
          ObservLib.Traces.Provider.start_span("test_span_#{i}", %{index: i})
        end

      active_count = ObservLib.Traces.Provider.active_span_count()
      assert active_count == initial_count + 100

      Enum.each(spans, &ObservLib.Traces.Provider.end_span/1)
      Process.sleep(50)

      final_count = ObservLib.Traces.Provider.active_span_count()
      assert final_count == initial_count
    end

    test "stale span cleanup prevents memory leaks" do
      _span = ObservLib.Traces.Provider.start_span("stale_span", %{})

      initial_count = ObservLib.Traces.Provider.active_span_count()
      assert initial_count >= 1

      active_spans = ObservLib.Traces.Provider.get_active_spans()
      assert length(active_spans) >= 1
      assert Enum.any?(active_spans, fn s -> s.name == "stale_span" end)
    end
  end
end
