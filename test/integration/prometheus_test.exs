defmodule ObservLib.Integration.PrometheusTest do
  @moduledoc """
  Integration tests for the Prometheus scrape endpoint.

  Verifies that metrics recorded via ObservLib.Metrics are correctly
  exposed in Prometheus text format via the PrometheusReader HTTP endpoint.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  setup do
    # Use a unique port for each test to avoid conflicts
    port = Enum.random(19000..19999)

    # Store original config
    original_config = Application.get_all_env(:observlib)

    # Configure ObservLib
    Application.put_env(:observlib, :service_name, "prometheus-test-service")
    Application.put_env(:observlib, :prometheus_port, port)

    on_exit(fn ->
      # Restore original config
      for {key, _} <- Application.get_all_env(:observlib) do
        Application.delete_env(:observlib, key)
      end

      for {key, value} <- original_config do
        Application.put_env(:observlib, key, value)
      end
    end)

    {:ok, port: port}
  end

  describe "prometheus scrape endpoint" do
    test "responds with 200 OK to GET /metrics", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      # Allow time for TCP listener to start
      Process.sleep(50)

      # Make HTTP request
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "HTTP/1.1 200 OK"
      assert response =~ "Content-Type: text/plain"
    end

    test "returns 404 for non-metrics paths", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      Process.sleep(50)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /invalid HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "HTTP/1.1 404 Not Found"
    end

    test "returns 405 for non-GET methods", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      Process.sleep(50)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "POST /metrics HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "HTTP/1.1 405 Method Not Allowed"
    end
  end

  describe "prometheus text format" do
    test "counter metrics are formatted correctly", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      # Record counter metrics
      ObservLib.Metrics.counter("http_requests_total", 42, %{method: "GET", status: "200"})
      Process.sleep(50)

      # Scrape metrics
      body = scrape_metrics(port)

      # Verify format
      assert body =~ "# TYPE http_requests_total counter"
      assert body =~ ~r/http_requests_total\{.*method="GET".*\} 42/
      assert body =~ ~r/http_requests_total\{.*status="200".*\} 42/
    end

    test "gauge metrics are formatted correctly", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      # Record gauge metric
      ObservLib.Metrics.gauge("memory_usage_bytes", 1048576.0, %{type: "heap"})
      Process.sleep(50)

      body = scrape_metrics(port)

      assert body =~ "# TYPE memory_usage_bytes gauge"
      assert body =~ ~r/memory_usage_bytes\{type="heap"\} \d+/
    end

    test "histogram metrics are formatted correctly", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      # Record histogram observations
      ObservLib.Metrics.histogram("http_request_duration", 10.5, %{endpoint: "/api"})
      ObservLib.Metrics.histogram("http_request_duration", 25.0, %{endpoint: "/api"})
      ObservLib.Metrics.histogram("http_request_duration", 100.0, %{endpoint: "/api"})
      Process.sleep(50)

      body = scrape_metrics(port)

      # Verify histogram format
      assert body =~ "# TYPE http_request_duration histogram"
      assert body =~ ~r/http_request_duration_bucket\{.*le="/
      assert body =~ ~r/http_request_duration_sum/
      assert body =~ ~r/http_request_duration_count/
      # Should have +Inf bucket
      assert body =~ ~r/le="\+Inf"/
    end

    test "up_down_counter is formatted as gauge", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      # Record up-down counter
      ObservLib.Metrics.up_down_counter("active_connections", 10, %{protocol: "http"})
      Process.sleep(50)

      body = scrape_metrics(port)

      # Prometheus doesn't have up_down_counter, should be gauge
      assert body =~ "# TYPE active_connections gauge"
      assert body =~ ~r/active_connections\{protocol="http"\} 10/
    end

    test "metric names are sanitized", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      # Record metric with special characters in name
      ObservLib.Metrics.counter("http.requests-total", 1, %{})
      Process.sleep(50)

      body = scrape_metrics(port)

      # Dots and dashes should be replaced with underscores
      assert body =~ "http_requests_total"
      refute body =~ "http.requests-total"
    end

    test "label values are escaped", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      # Record metric with special characters in label value
      ObservLib.Metrics.counter("test_metric", 1, %{path: "/api/users?id=1"})
      Process.sleep(50)

      body = scrape_metrics(port)

      # Label value should be properly quoted
      assert body =~ ~r/path="/
    end

    test "empty metrics returns empty response", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      Process.sleep(50)

      body = scrape_metrics(port)

      # Should be empty or just whitespace
      assert String.trim(body) == ""
    end

    test "metrics with no labels work correctly", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      ObservLib.Metrics.counter("simple_counter", 5, %{})
      Process.sleep(50)

      body = scrape_metrics(port)

      assert body =~ "# TYPE simple_counter counter"
      # No labels means no curly braces
      assert body =~ ~r/simple_counter 5/
    end
  end

  describe "metric values" do
    test "counter values match recorded amounts", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      # Record multiple increments
      ObservLib.Metrics.counter("request_count", 10, %{})
      ObservLib.Metrics.counter("request_count", 15, %{})
      ObservLib.Metrics.counter("request_count", 25, %{})
      Process.sleep(50)

      body = scrape_metrics(port)

      # Total should be 50
      assert body =~ ~r/request_count 50/
    end

    test "histogram statistics are accurate", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      # Record specific values
      ObservLib.Metrics.histogram("latency", 10.0, %{})
      ObservLib.Metrics.histogram("latency", 20.0, %{})
      ObservLib.Metrics.histogram("latency", 30.0, %{})
      Process.sleep(50)

      body = scrape_metrics(port)

      # Count should be 3
      assert body =~ ~r/latency_count 3/
      # Sum should be 60
      assert body =~ ~r/latency_sum 60/
    end

    test "different label combinations create separate series", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      ObservLib.Metrics.counter("api_calls", 5, %{method: "GET"})
      ObservLib.Metrics.counter("api_calls", 3, %{method: "POST"})
      Process.sleep(50)

      body = scrape_metrics(port)

      # Should have two separate series
      assert body =~ ~r/api_calls\{method="GET"\} 5/
      assert body =~ ~r/api_calls\{method="POST"\} 3/
    end
  end

  describe "reader statistics" do
    test "tracks scrape count", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      Process.sleep(50)

      # Initial stats
      stats = ObservLib.Metrics.PrometheusReader.get_stats()
      assert stats.scrape_count == 0

      # Scrape a few times
      _body1 = scrape_metrics(port)
      Process.sleep(50)
      _body2 = scrape_metrics(port)
      Process.sleep(50)

      # Check updated stats
      stats = ObservLib.Metrics.PrometheusReader.get_stats()
      assert stats.scrape_count == 2
    end

    test "reports correct port", %{port: port} do
      {:ok, _config} = start_supervised({ObservLib.Config, []})
      {:ok, _meter_provider} = start_supervised({ObservLib.Metrics.MeterProvider, []})
      {:ok, _reader} = start_supervised({ObservLib.Metrics.PrometheusReader, [port: port]})

      Process.sleep(50)

      actual_port = ObservLib.Metrics.PrometheusReader.get_port()
      assert actual_port == port
    end
  end

  # Helper function to scrape metrics from the endpoint
  defp scrape_metrics(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

    {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
    :gen_tcp.close(socket)

    # Extract body from HTTP response
    [_headers, body] = String.split(response, "\r\n\r\n", parts: 2)
    body
  end
end
