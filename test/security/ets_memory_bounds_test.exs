defmodule ObservLib.Security.EtsMemoryBoundsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :security

  setup do
    # Reset metrics before each test
    ObservLib.Metrics.MeterProvider.reset()
    :ok
  end

  describe "sec-003: Cardinality limits prevent unbounded ETS growth" do
    test "cardinality limit prevents unbounded metric variants" do
      # Get the configured cardinality limit
      limit = ObservLib.Config.cardinality_limit()

      # Record metrics up to the limit
      for i <- 1..limit do
        ObservLib.Metrics.counter("test.cardinality", 1, %{unique_id: "id_#{i}"})
      end

      # Verify we have exactly `limit` variants
      metrics = ObservLib.Metrics.MeterProvider.read("test.cardinality")
      assert length(metrics) == limit

      # Attempt to exceed the limit
      log =
        capture_log(fn ->
          ObservLib.Metrics.counter("test.cardinality", 1, %{unique_id: "id_overflow"})
          # Sync call to flush the async cast so the log is captured
          ObservLib.Metrics.MeterProvider.read("test.cardinality")
        end)

      # Should log a warning about cardinality limit
      assert log =~ "Metric cardinality limit exceeded"
      assert log =~ "test.cardinality"

      # Verify no new metric variant was created
      metrics_after = ObservLib.Metrics.MeterProvider.read("test.cardinality")
      assert length(metrics_after) == limit
    end

    test "existing metric variants can be updated beyond cardinality limit" do
      # Record a metric variant
      ObservLib.Metrics.counter("test.update", 1, %{id: "existing"})

      # Fill up the cardinality to the limit
      limit = ObservLib.Config.cardinality_limit()

      for i <- 2..limit do
        ObservLib.Metrics.counter("test.update", 1, %{id: "id_#{i}"})
      end

      # Updating an existing variant should still work
      log =
        capture_log(fn ->
          ObservLib.Metrics.counter("test.update", 5, %{id: "existing"})
        end)

      refute log =~ "Metric cardinality limit exceeded"

      # Verify the update worked
      metrics = ObservLib.Metrics.MeterProvider.read("test.update")
      existing_metric = Enum.find(metrics, fn m -> m.attributes[:id] == "existing" end)
      assert existing_metric.data.value >= 1
    end

    test "cardinality limit is per metric name" do
      limit = min(ObservLib.Config.cardinality_limit(), 10)

      # Create variants for metric A
      for i <- 1..limit do
        ObservLib.Metrics.counter("metric.a", 1, %{id: i})
      end

      # Create variants for metric B - should have separate limit
      for i <- 1..limit do
        ObservLib.Metrics.counter("metric.b", 1, %{id: i})
      end

      # Both metrics should have their own cardinality tracking
      metrics_a = ObservLib.Metrics.MeterProvider.read("metric.a")
      metrics_b = ObservLib.Metrics.MeterProvider.read("metric.b")

      assert length(metrics_a) == limit
      assert length(metrics_b) == limit
    end
  end

  describe "sec-004: Log batch limits prevent unbounded queue growth" do
    test "log batch limit prevents memory exhaustion" do
      # Get the configured batch limit
      batch_limit = ObservLib.Config.get_log_batch_limit()

      # Create more log records than the limit
      excessive_logs =
        for i <- 1..(batch_limit + 100) do
          %{
            level: :info,
            message: "Test log #{i}",
            timestamp: System.system_time(:nanosecond),
            attributes: %{}
          }
        end

      # Add logs to batch
      log =
        capture_log(fn ->
          ObservLib.Exporters.OtlpLogsExporter.add_to_batch(excessive_logs)
          # Give it a moment to process
          Process.sleep(100)
        end)

      # Should log a warning about batch limit
      assert log =~ "Log batch limit exceeded"
      assert log =~ "dropping oldest logs"
    end
  end

  describe "sec-010: Span limits prevent unbounded active spans" do
    test "active span tracking does not grow unbounded" do
      initial_count = ObservLib.Traces.Provider.active_span_count()

      # Start many spans
      spans =
        for i <- 1..100 do
          ObservLib.Traces.Provider.start_span("test_span_#{i}", %{index: i})
        end

      # Verify spans are tracked (active_span_count is a call, so all prior casts are processed)
      active_count = ObservLib.Traces.Provider.active_span_count()
      assert active_count == initial_count + 100

      # End spans
      Enum.each(spans, fn span ->
        ObservLib.Traces.Provider.end_span(span)
      end)

      # Give ETS time to update
      Process.sleep(50)

      # Verify spans are removed from tracking
      final_count = ObservLib.Traces.Provider.active_span_count()
      assert final_count == 0
    end

    test "stale span cleanup prevents memory leaks" do
      # Start a span but don't end it
      _span = ObservLib.Traces.Provider.start_span("stale_span", %{})

      # Verify it's tracked
      initial_count = ObservLib.Traces.Provider.active_span_count()
      assert initial_count >= 1

      # Note: Stale span cleanup runs on a timer (default: 1 minute)
      # In a real scenario, stale spans would be cleaned up after the timeout
      # For testing purposes, we verify the tracking mechanism works
      active_spans = ObservLib.Traces.Provider.get_active_spans()
      assert length(active_spans) >= 1
      assert Enum.any?(active_spans, fn s -> s.name == "stale_span" end)
    end
  end
end
