defmodule ObservLib.Security.ResourceLimitsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  @moduletag :security

  describe "sec-009: Attribute value size truncation" do
    test "truncates oversized string attributes" do
      # Create a 10KB string (exceeds default 4KB limit)
      large_value = String.duplicate("x", 10_000)
      attrs = %{"large_data" => large_value}

      {:ok, result} = ObservLib.Attributes.validate(attrs)

      # Should be truncated with suffix
      assert String.ends_with?(result["large_data"], "...[TRUNC]")
      assert byte_size(result["large_data"]) <= 4096
    end

    test "logs warning when truncating values" do
      large_value = String.duplicate("y", 10_000)

      log =
        capture_log(fn ->
          ObservLib.Attributes.validate(%{"data" => large_value})
        end)

      assert log =~ "Attribute value truncated"
      assert log =~ "original_size: 10000"
      assert log =~ "truncated_size: 4096"
    end

    test "preserves values under size limit" do
      small_value = String.duplicate("z", 100)
      attrs = %{"small" => small_value}

      {:ok, result} = ObservLib.Attributes.validate(attrs)

      assert result["small"] == small_value
      refute String.contains?(result["small"], "[TRUNC]")
    end

    test "does not truncate non-string values" do
      attrs = %{
        "int" => 42,
        "float" => 3.14,
        "bool" => true,
        "list" => [1, 2, 3]
      }

      {:ok, result} = ObservLib.Attributes.validate(attrs)

      assert result == attrs
    end

    @tag timeout: 60_000
    property "handles arbitrary size strings without crashing" do
      check all(
              size <- StreamData.integer(0..50_000),
              max_runs: 50
            ) do
        value = String.duplicate("a", size)
        {:ok, result} = ObservLib.Attributes.validate(%{"key" => value})

        # Result should be valid and not exceed limit
        assert is_map(result)
        assert byte_size(result["key"]) <= 4096
      end
    end
  end

  describe "sec-011: Attribute count limits" do
    test "limits number of attributes to configured maximum" do
      # Create 200 attributes (exceeds default 128 limit)
      attrs = Map.new(1..200, fn i -> {"key_#{i}", "value_#{i}"} end)

      log =
        capture_log(fn ->
          {:ok, result} = ObservLib.Attributes.validate(attrs)

          # Should be limited to 128
          assert map_size(result) <= 128
        end)

      assert log =~ "Attribute count exceeded"
      assert log =~ "limit: 128"
      assert log =~ "count: 200"
    end

    test "preserves attributes under count limit" do
      attrs = Map.new(1..50, fn i -> {"key_#{i}", "value_#{i}"} end)

      {:ok, result} = ObservLib.Attributes.validate(attrs)

      assert map_size(result) == 50
      assert result == attrs
    end

    test "truncates to first N attributes when limit exceeded" do
      attrs = Map.new(1..150, fn i -> {"key_#{i}", "value_#{i}"} end)

      {:ok, result} = ObservLib.Attributes.validate(attrs)

      # Should keep only first 128 attributes
      assert map_size(result) == 128
    end

    @tag timeout: 60_000
    property "handles arbitrary attribute counts without crashing" do
      check all(
              count <- StreamData.integer(0..500),
              max_runs: 20
            ) do
        attrs = Map.new(1..count, fn i -> {"k#{i}", "v#{i}"} end)
        {:ok, result} = ObservLib.Attributes.validate(attrs)

        # Should not exceed limit
        assert map_size(result) <= 128
      end
    end
  end

  describe "sec-003: Cardinality limits per metric" do
    setup do
      ObservLib.Metrics.MeterProvider.reset()
      :ok
    end

    test "enforces cardinality limit per metric name" do
      limit = min(ObservLib.Config.cardinality_limit(), 10)

      # Fill up to limit
      for i <- 1..limit do
        ObservLib.Metrics.counter("test.metric", 1, %{id: i})
      end

      # Flush all for-loop casts before entering capture_log window
      ObservLib.Metrics.MeterProvider.read("test.metric")

      # Exceeding should be rejected with warning
      log =
        capture_log(fn ->
          ObservLib.Metrics.counter("test.metric", 1, %{id: 9999})
          # Sync call to flush the async cast so the log is captured
          ObservLib.Metrics.MeterProvider.read("test.metric")
        end)

      assert log =~ "Metric cardinality limit exceeded"

      # Verify count stayed at limit
      metrics = ObservLib.Metrics.MeterProvider.read("test.metric")
      assert length(metrics) == limit
    end

    @tag timeout: 60_000
    property "cardinality limit prevents unbounded growth" do
      check all(
              unique_id <- StreamData.integer(1..5000),
              max_runs: 100
            ) do
        ObservLib.Metrics.counter("prop.test", 1, %{id: unique_id})

        # Verify we never exceed the limit
        metrics = ObservLib.Metrics.MeterProvider.read("prop.test")
        limit = ObservLib.Config.cardinality_limit()
        assert metrics == nil or length(metrics) <= limit
      end
    end
  end

  describe "sec-004: Log batch queue limits" do
    test "enforces maximum log batch size" do
      batch_limit = ObservLib.Config.get_log_batch_limit()

      excessive_logs =
        for i <- 1..(batch_limit + 500) do
          %{
            level: :info,
            message: "Log #{i}",
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
      assert log =~ "dropped"
    end
  end

  describe "sec-010: Span count limits" do
    test "span tracking has bounded memory usage" do
      # Create many spans
      spans =
        for i <- 1..1000 do
          ObservLib.Traces.Provider.start_span("span_#{i}", %{})
        end

      # Verify tracking
      count = ObservLib.Traces.Provider.active_span_count()
      assert count == 1000

      # Clean up - end all spans
      Enum.each(spans, &ObservLib.Traces.Provider.end_span/1)
      Process.sleep(50)

      # Verify cleanup
      final_count = ObservLib.Traces.Provider.active_span_count()
      assert final_count == 0
    end
  end
end
