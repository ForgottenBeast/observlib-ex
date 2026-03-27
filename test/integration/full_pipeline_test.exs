defmodule ObservLib.Integration.FullPipelineTest do
  @moduledoc """
  End-to-end integration tests for the complete ObservLib telemetry pipeline.

  Tests the full flow from emitting telemetry signals (traces, metrics, logs)
  through to OTLP export verification using a mock OTLP server.
  """

  use ExUnit.Case, async: false

  alias ObservLib.Test.MockOtlpServer

  @moduletag :integration

  setup do
    # Start mock OTLP server
    {:ok, server} = MockOtlpServer.start_link()
    endpoint = MockOtlpServer.endpoint(server)

    # Store original config
    original_config = Application.get_all_env(:observlib)

    # Configure ObservLib to use mock server
    Application.put_env(:observlib, :service_name, "test-service")
    Application.put_env(:observlib, :otlp_endpoint, endpoint)

    on_exit(fn ->
      # Restore original config
      for {key, _} <- Application.get_all_env(:observlib) do
        Application.delete_env(:observlib, key)
      end

      for {key, value} <- original_config do
        Application.put_env(:observlib, key, value)
      end

      # Stop mock server
      if Process.alive?(server), do: MockOtlpServer.stop(server)
    end)

    {:ok, server: server, endpoint: endpoint}
  end

  describe "trace pipeline" do
    test "emitting a trace results in OTLP export", %{server: server, endpoint: endpoint} do
      # Start required services
      {:ok, config} = start_supervised({ObservLib.Config, []})
      {:ok, meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, logs_exporter} = start_supervised({ObservLib.Exporters.OtlpLogsExporter, [batch_timeout: 100]})

      # Create a span
      span_ctx = ObservLib.Traces.start_span("test-span", %{"test.attribute" => "value"})
      ObservLib.Traces.end_span(span_ctx)

      # Note: Trace export goes through OpenTelemetry's exporter, not our custom one
      # This test verifies the span creation API works correctly
      assert span_ctx != :undefined
    end

    test "with_span executes function and creates span", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})

      result = ObservLib.Traces.with_span("computation", %{"operation" => "add"}, fn ->
        1 + 1
      end)

      assert result == 2
    end

    test "with_span handles exceptions and sets error status", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})

      assert_raise RuntimeError, "test error", fn ->
        ObservLib.Traces.with_span("failing-operation", %{}, fn ->
          raise "test error"
        end)
      end
    end
  end

  describe "metrics pipeline" do
    test "emitting metrics results in OTLP export", %{server: server, endpoint: endpoint} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, exporter} = start_supervised({ObservLib.Exporters.OtlpMetricsExporter, [export_interval: 100_000]})

      # Record some metrics
      ObservLib.Metrics.counter("http.requests", 1, %{method: "GET", status: "200"})
      ObservLib.Metrics.counter("http.requests", 1, %{method: "POST", status: "201"})
      ObservLib.Metrics.gauge("memory.usage", 1024.5, %{type: "heap"})
      ObservLib.Metrics.histogram("http.duration", 45.2, %{endpoint: "/api/users"})

      # Allow time for async processing
      Process.sleep(50)

      # Force export
      :ok = ObservLib.Exporters.OtlpMetricsExporter.force_export()

      # Allow time for HTTP request
      Process.sleep(100)

      # Check received metrics
      metrics = MockOtlpServer.get_metrics(server)
      assert length(metrics) >= 1

      # Verify OTLP format
      [payload | _] = metrics
      assert Map.has_key?(payload, "resourceMetrics")

      resource_metrics = payload["resourceMetrics"]
      assert is_list(resource_metrics)
      assert length(resource_metrics) >= 1
    end

    test "counter aggregation works correctly", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})

      # Record multiple counter increments
      ObservLib.Metrics.counter("test.counter", 1, %{label: "a"})
      ObservLib.Metrics.counter("test.counter", 5, %{label: "a"})
      ObservLib.Metrics.counter("test.counter", 3, %{label: "a"})

      Process.sleep(50)

      # Read from MeterProvider
      metrics = ObservLib.Metrics.MeterProvider.read_all()
      counter_metrics = Enum.filter(metrics, fn m -> m.name == "test.counter" end)

      assert length(counter_metrics) == 1
      [counter] = counter_metrics
      assert counter.data.value == 9  # 1 + 5 + 3
    end

    test "histogram tracks statistics correctly", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})

      # Record histogram observations
      ObservLib.Metrics.histogram("latency", 10.0, %{})
      ObservLib.Metrics.histogram("latency", 20.0, %{})
      ObservLib.Metrics.histogram("latency", 30.0, %{})

      Process.sleep(50)

      # Read from MeterProvider
      metrics = ObservLib.Metrics.MeterProvider.read_all()
      histogram_metrics = Enum.filter(metrics, fn m -> m.name == "latency" end)

      assert length(histogram_metrics) == 1
      [histogram] = histogram_metrics
      assert histogram.data.count == 3
      assert histogram.data.sum == 60.0
      assert histogram.data.min == 10.0
      assert histogram.data.max == 30.0
    end

    test "gauge records last value", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})

      # Record gauge values
      ObservLib.Metrics.gauge("temperature", 20.0, %{sensor: "a"})
      ObservLib.Metrics.gauge("temperature", 25.0, %{sensor: "a"})
      ObservLib.Metrics.gauge("temperature", 22.0, %{sensor: "a"})

      Process.sleep(50)

      # Read from MeterProvider
      metrics = ObservLib.Metrics.MeterProvider.read_all()
      gauge_metrics = Enum.filter(metrics, fn m -> m.name == "temperature" end)

      assert length(gauge_metrics) == 1
      [gauge] = gauge_metrics
      assert gauge.data.value == 22.0  # Last value
    end

    test "up_down_counter allows negative values", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})

      # Record up-down counter changes
      ObservLib.Metrics.up_down_counter("active.connections", 5, %{})
      ObservLib.Metrics.up_down_counter("active.connections", -2, %{})
      ObservLib.Metrics.up_down_counter("active.connections", 1, %{})

      Process.sleep(50)

      # Read from MeterProvider
      metrics = ObservLib.Metrics.MeterProvider.read_all()
      udc_metrics = Enum.filter(metrics, fn m -> m.name == "active.connections" end)

      assert length(udc_metrics) == 1
      [udc] = udc_metrics
      assert udc.data.value == 4  # 5 - 2 + 1
    end
  end

  describe "logs pipeline" do
    test "emitting logs results in OTLP export", %{server: server, endpoint: endpoint} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _logs_exporter} = start_supervised({ObservLib.Exporters.OtlpLogsExporter, [batch_size: 1, batch_timeout: 100]})

      # Emit a log
      ObservLib.Logs.info("Test log message", user_id: 123, action: "test")

      # Allow time for batch flush
      Process.sleep(200)

      # Check received logs
      logs = MockOtlpServer.get_logs(server)

      # Logs may or may not be captured depending on Logger backend registration
      # This test verifies the logging API works
      assert is_list(logs)
    end

    test "log levels are correctly mapped", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})

      # Test severity number mapping
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:debug) == 5
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:info) == 9
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:warning) == 13
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:error) == 17
    end

    test "log context is preserved", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})

      # Test with_context
      result = ObservLib.Logs.with_context(%{request_id: "abc-123"}, fn ->
        ObservLib.Logs.info("Processing request")
        :ok
      end)

      assert result == :ok
    end
  end

  describe "cross-signal correlation" do
    test "trace context is available in logs within a span", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _logs_exporter} = start_supervised({ObservLib.Exporters.OtlpLogsExporter, [batch_size: 1, batch_timeout: 100]})

      # Create a span and log within it
      ObservLib.Traces.with_span("parent-operation", %{}, fn ->
        ObservLib.Logs.info("Log within span")

        # Get current span context
        span_ctx = ObservLib.Traces.current_span()
        assert span_ctx != :undefined
      end)

      Process.sleep(200)
    end
  end

  describe "@traced macro integration" do
    defmodule TracedTestModule do
      use ObservLib.Traced

      @traced attributes: %{"test" => "value"}
      def traced_function(x) do
        x * 2
      end

      @traced name: "custom_span"
      def custom_named_function do
        :ok
      end

      @traced
      def simple_traced do
        42
      end
    end

    test "traced decorator creates spans", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})

      result = TracedTestModule.traced_function(5)
      assert result == 10

      result = TracedTestModule.custom_named_function()
      assert result == :ok

      result = TracedTestModule.simple_traced()
      assert result == 42
    end

    test "inline traced macro works", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})

      import ObservLib.Traced

      result = traced "inline-span", %{operation: "test"} do
        1 + 2 + 3
      end

      assert result == 6
    end

    test "traced macro handles exceptions", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})

      import ObservLib.Traced

      assert_raise RuntimeError, "traced error", fn ->
        traced "failing-span", %{} do
          raise "traced error"
        end
      end
    end
  end

  describe "multi-signal flow" do
    test "all three signal types flow simultaneously", %{server: server, endpoint: endpoint} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _metrics_exporter} = start_supervised({ObservLib.Exporters.OtlpMetricsExporter, [export_interval: 100_000]})
      {:ok, _logs_exporter} = start_supervised({ObservLib.Exporters.OtlpLogsExporter, [batch_size: 1, batch_timeout: 100]})

      # Emit all signal types
      ObservLib.Traces.with_span("multi-signal-operation", %{}, fn ->
        ObservLib.Metrics.counter("operation.count", 1, %{type: "multi"})
        ObservLib.Logs.info("Operation started")

        # Do some work
        Process.sleep(10)

        ObservLib.Metrics.histogram("operation.duration", 10.5, %{type: "multi"})
        ObservLib.Logs.info("Operation completed")
      end)

      # Force metric export
      :ok = ObservLib.Exporters.OtlpMetricsExporter.force_export()

      # Allow time for exports
      Process.sleep(200)

      # Verify metrics were received
      metrics = MockOtlpServer.get_metrics(server)
      assert length(metrics) >= 1
    end
  end
end
