defmodule ObservLib.Integration.OtlpExportTest do
  @moduledoc """
  Integration tests for OTLP HTTP export functionality.

  Verifies correct OTLP protocol format, retry logic, and batch processing
  for metrics and logs exporters.
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

    # Configure ObservLib
    Application.put_env(:observlib, :service_name, "otlp-test-service")
    Application.put_env(:observlib, :otlp_endpoint, endpoint)

    on_exit(fn ->
      # Restore original config
      for {key, _} <- Application.get_all_env(:observlib) do
        Application.delete_env(:observlib, key)
      end

      for {key, value} <- original_config do
        Application.put_env(:observlib, key, value)
      end

      if Process.alive?(server), do: MockOtlpServer.stop(server)
    end)

    {:ok, server: server, endpoint: endpoint}
  end

  describe "OTLP metrics export format" do
    test "produces valid OTLP JSON structure", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpMetricsExporter, [export_interval: 100_000]})

      # Record a metric
      ObservLib.Metrics.counter("test.metric", 1, %{label: "value"})
      Process.sleep(50)

      # Force export
      :ok = ObservLib.Exporters.OtlpMetricsExporter.force_export()
      Process.sleep(100)

      # Verify OTLP structure
      metrics = MockOtlpServer.get_metrics(server)
      assert length(metrics) >= 1

      [payload | _] = metrics

      # Top-level structure
      assert Map.has_key?(payload, "resourceMetrics")
      assert is_list(payload["resourceMetrics"])

      [resource_metrics | _] = payload["resourceMetrics"]

      # Resource structure
      assert Map.has_key?(resource_metrics, "resource")
      assert Map.has_key?(resource_metrics["resource"], "attributes")

      # ScopeMetrics structure
      assert Map.has_key?(resource_metrics, "scopeMetrics")
      [scope_metrics | _] = resource_metrics["scopeMetrics"]

      assert Map.has_key?(scope_metrics, "scope")
      assert Map.has_key?(scope_metrics, "metrics")
    end

    test "counter metrics have correct OTLP format", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpMetricsExporter, [export_interval: 100_000]})

      ObservLib.Metrics.counter("http.requests", 42, %{method: "GET"})
      Process.sleep(50)

      :ok = ObservLib.Exporters.OtlpMetricsExporter.force_export()
      Process.sleep(100)

      metrics = MockOtlpServer.get_metrics(server)
      [payload | _] = metrics

      scope_metrics = get_in(payload, ["resourceMetrics", Access.at(0), "scopeMetrics", Access.at(0), "metrics"])
      assert is_list(scope_metrics)

      counter_metric = Enum.find(scope_metrics, fn m -> m["name"] == "http.requests" end)
      assert counter_metric != nil

      # Counter should have "sum" field
      assert Map.has_key?(counter_metric, "sum")
      sum_data = counter_metric["sum"]

      # Sum should have dataPoints
      assert Map.has_key?(sum_data, "dataPoints")
      assert is_list(sum_data["dataPoints"])

      # Should be monotonic
      assert sum_data["isMonotonic"] == true

      # Aggregation temporality should be cumulative (2)
      assert sum_data["aggregationTemporality"] == 2
    end

    test "gauge metrics have correct OTLP format", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpMetricsExporter, [export_interval: 100_000]})

      ObservLib.Metrics.gauge("memory.usage", 1024.5, %{type: "heap"})
      Process.sleep(50)

      :ok = ObservLib.Exporters.OtlpMetricsExporter.force_export()
      Process.sleep(100)

      metrics = MockOtlpServer.get_metrics(server)
      [payload | _] = metrics

      scope_metrics = get_in(payload, ["resourceMetrics", Access.at(0), "scopeMetrics", Access.at(0), "metrics"])
      gauge_metric = Enum.find(scope_metrics, fn m -> m["name"] == "memory.usage" end)
      assert gauge_metric != nil

      # Gauge should have "gauge" field
      assert Map.has_key?(gauge_metric, "gauge")
      gauge_data = gauge_metric["gauge"]

      assert Map.has_key?(gauge_data, "dataPoints")
      [data_point | _] = gauge_data["dataPoints"]

      # Should have asDouble for float value
      assert Map.has_key?(data_point, "asDouble")
    end

    test "histogram metrics have correct OTLP format", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpMetricsExporter, [export_interval: 100_000]})

      ObservLib.Metrics.histogram("request.duration", 50.0, %{})
      ObservLib.Metrics.histogram("request.duration", 150.0, %{})
      Process.sleep(50)

      :ok = ObservLib.Exporters.OtlpMetricsExporter.force_export()
      Process.sleep(100)

      metrics = MockOtlpServer.get_metrics(server)
      [payload | _] = metrics

      scope_metrics = get_in(payload, ["resourceMetrics", Access.at(0), "scopeMetrics", Access.at(0), "metrics"])
      histogram_metric = Enum.find(scope_metrics, fn m -> m["name"] == "request.duration" end)
      assert histogram_metric != nil

      # Histogram should have "histogram" field
      assert Map.has_key?(histogram_metric, "histogram")
      histogram_data = histogram_metric["histogram"]

      assert Map.has_key?(histogram_data, "dataPoints")
      [data_point | _] = histogram_data["dataPoints"]

      # Should have count, sum, bucketCounts, explicitBounds
      assert Map.has_key?(data_point, "count")
      assert Map.has_key?(data_point, "sum")
      assert Map.has_key?(data_point, "bucketCounts")
      assert Map.has_key?(data_point, "explicitBounds")
    end

    test "attributes are correctly formatted", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpMetricsExporter, [export_interval: 100_000]})

      ObservLib.Metrics.counter("test.attrs", 1, %{
        string_attr: "value",
        int_attr: 42
      })
      Process.sleep(50)

      :ok = ObservLib.Exporters.OtlpMetricsExporter.force_export()
      Process.sleep(100)

      metrics = MockOtlpServer.get_metrics(server)
      [payload | _] = metrics

      scope_metrics = get_in(payload, ["resourceMetrics", Access.at(0), "scopeMetrics", Access.at(0), "metrics"])
      metric = Enum.find(scope_metrics, fn m -> m["name"] == "test.attrs" end)
      [data_point | _] = metric["sum"]["dataPoints"]

      attributes = data_point["attributes"]
      assert is_list(attributes)

      # Find string attribute
      string_attr = Enum.find(attributes, fn a -> a["key"] == "string_attr" end)
      assert string_attr != nil
      assert Map.has_key?(string_attr["value"], "stringValue")

      # Find int attribute
      int_attr = Enum.find(attributes, fn a -> a["key"] == "int_attr" end)
      assert int_attr != nil
      # Int values are encoded as strings in OTLP JSON
      assert Map.has_key?(int_attr["value"], "intValue") or Map.has_key?(int_attr["value"], "stringValue")
    end

    test "resource attributes are included", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpMetricsExporter, [export_interval: 100_000]})

      ObservLib.Metrics.counter("resource.test", 1, %{})
      Process.sleep(50)

      :ok = ObservLib.Exporters.OtlpMetricsExporter.force_export()
      Process.sleep(100)

      metrics = MockOtlpServer.get_metrics(server)
      [payload | _] = metrics

      resource_attrs = get_in(payload, ["resourceMetrics", Access.at(0), "resource", "attributes"])
      assert is_list(resource_attrs)

      # Should have service.name
      service_name_attr = Enum.find(resource_attrs, fn a -> a["key"] == "service.name" end)
      assert service_name_attr != nil
      assert service_name_attr["value"]["stringValue"] == "otlp-test-service"
    end
  end

  describe "OTLP logs export format" do
    test "produces valid OTLP JSON structure", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpLogsExporter, [batch_size: 1, batch_timeout: 50]})

      # Directly add log to exporter (bypassing Logger)
      log_record = %{
        level: :info,
        message: "Test log message",
        timestamp: System.system_time(:nanosecond),
        attributes: %{test_attr: "value"}
      }
      ObservLib.Exporters.OtlpLogsExporter.add_to_batch([log_record])

      Process.sleep(200)

      logs = MockOtlpServer.get_logs(server)
      assert length(logs) >= 1

      [payload | _] = logs

      # Top-level structure
      assert Map.has_key?(payload, "resource_logs")
      assert is_list(payload["resource_logs"])

      [resource_logs | _] = payload["resource_logs"]
      assert Map.has_key?(resource_logs, "resource")
      assert Map.has_key?(resource_logs, "scope_logs")
    end

    test "log records have correct OTLP format", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpLogsExporter, [batch_size: 1, batch_timeout: 50]})

      log_record = %{
        level: :error,
        message: "Error occurred",
        timestamp: System.system_time(:nanosecond),
        attributes: %{error_code: "E001"}
      }
      ObservLib.Exporters.OtlpLogsExporter.add_to_batch([log_record])

      Process.sleep(200)

      logs = MockOtlpServer.get_logs(server)
      [payload | _] = logs

      scope_logs = get_in(payload, ["resource_logs", Access.at(0), "scope_logs", Access.at(0)])
      log_records = scope_logs["log_records"]
      assert is_list(log_records)

      [record | _] = log_records

      # Should have required fields
      assert Map.has_key?(record, "time_unix_nano")
      assert Map.has_key?(record, "severity_number")
      assert Map.has_key?(record, "severity_text")
      assert Map.has_key?(record, "body")

      # Severity should match error level
      assert record["severity_number"] == 17  # Error severity
      assert record["severity_text"] == "ERROR"
    end

    test "severity numbers are correctly mapped", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})

      # Test all severity mappings
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:debug) == 5
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:info) == 9
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:notice) == 10
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:warning) == 13
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:warn) == 13
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:error) == 17
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:critical) == 21
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:alert) == 22
      assert ObservLib.Exporters.OtlpLogsExporter.severity_number(:emergency) == 24
    end
  end

  describe "retry logic" do
    test "metrics exporter retries on 503 errors", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpMetricsExporter, [
        export_interval: 100_000,
        max_retries: 3,
        retry_delay: 50
      ]})

      # Set server to return error then success
      MockOtlpServer.set_response_mode(server, :error_then_success)

      ObservLib.Metrics.counter("retry.test", 1, %{})
      Process.sleep(50)

      # Force export - should retry and eventually succeed
      result = ObservLib.Exporters.OtlpMetricsExporter.force_export()
      Process.sleep(200)

      # Should have received the metric after retry
      metrics = MockOtlpServer.get_metrics(server)
      assert length(metrics) >= 1
    end

    test "logs exporter retries on transient failures", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpLogsExporter, [
        batch_size: 1,
        batch_timeout: 50,
        max_retries: 3
      ]})

      # Set server to return error then success
      MockOtlpServer.set_response_mode(server, :error_then_success)

      log_record = %{
        level: :info,
        message: "Retry test",
        timestamp: System.system_time(:nanosecond),
        attributes: %{}
      }
      ObservLib.Exporters.OtlpLogsExporter.add_to_batch([log_record])

      Process.sleep(500)

      # Should have received the log after retry
      logs = MockOtlpServer.get_logs(server)
      assert length(logs) >= 1
    end
  end

  describe "batch processing" do
    test "metrics are batched before export", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpMetricsExporter, [export_interval: 100_000]})

      # Record multiple metrics
      ObservLib.Metrics.counter("batch.metric1", 1, %{})
      ObservLib.Metrics.counter("batch.metric2", 2, %{})
      ObservLib.Metrics.gauge("batch.metric3", 3.0, %{})
      Process.sleep(50)

      # Force single export
      :ok = ObservLib.Exporters.OtlpMetricsExporter.force_export()
      Process.sleep(100)

      # Should receive all metrics in one payload
      metrics = MockOtlpServer.get_metrics(server)
      assert length(metrics) == 1

      [payload | _] = metrics
      scope_metrics = get_in(payload, ["resourceMetrics", Access.at(0), "scopeMetrics", Access.at(0), "metrics"])

      # All three metrics should be in the batch
      assert length(scope_metrics) == 3
    end

    test "logs batch on size threshold", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpLogsExporter, [
        batch_size: 3,
        batch_timeout: 10_000  # Long timeout to ensure size-based flush
      ]})

      # Add logs up to batch size
      for i <- 1..3 do
        log_record = %{
          level: :info,
          message: "Log #{i}",
          timestamp: System.system_time(:nanosecond),
          attributes: %{index: i}
        }
        ObservLib.Exporters.OtlpLogsExporter.add_to_batch([log_record])
      end

      # Wait for batch flush
      Process.sleep(200)

      logs = MockOtlpServer.get_logs(server)
      assert length(logs) >= 1

      # All logs should be in one batch
      [payload | _] = logs
      scope_logs = get_in(payload, ["resource_logs", Access.at(0), "scope_logs", Access.at(0)])
      log_records = scope_logs["log_records"]
      assert length(log_records) == 3
    end

    test "logs batch on timeout", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpLogsExporter, [
        batch_size: 100,  # High threshold
        batch_timeout: 100  # Short timeout
      ]})

      # Add single log (won't hit size threshold)
      log_record = %{
        level: :info,
        message: "Timeout test",
        timestamp: System.system_time(:nanosecond),
        attributes: %{}
      }
      ObservLib.Exporters.OtlpLogsExporter.add_to_batch([log_record])

      # Wait for timeout flush
      Process.sleep(300)

      logs = MockOtlpServer.get_logs(server)
      assert length(logs) >= 1
    end

    test "flush forces immediate export", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpLogsExporter, [
        batch_size: 100,
        batch_timeout: 60_000  # Very long timeout
      ]})

      log_record = %{
        level: :info,
        message: "Flush test",
        timestamp: System.system_time(:nanosecond),
        attributes: %{}
      }
      ObservLib.Exporters.OtlpLogsExporter.add_to_batch([log_record])

      # Flush immediately
      :ok = ObservLib.Exporters.OtlpLogsExporter.flush()
      Process.sleep(100)

      logs = MockOtlpServer.get_logs(server)
      assert length(logs) >= 1
    end
  end

  describe "exporter statistics" do
    test "metrics exporter tracks export counts", %{server: server} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _exporter} = start_supervised({ObservLib.Exporters.OtlpMetricsExporter, [export_interval: 100_000]})

      # Initial stats
      stats = ObservLib.Exporters.OtlpMetricsExporter.get_stats()
      assert stats.export_count == 0

      ObservLib.Metrics.counter("stats.test", 1, %{})
      Process.sleep(50)

      :ok = ObservLib.Exporters.OtlpMetricsExporter.force_export()
      Process.sleep(100)

      # Updated stats
      stats = ObservLib.Exporters.OtlpMetricsExporter.get_stats()
      assert stats.export_count == 1
      assert stats.last_export_time != nil
    end
  end
end
