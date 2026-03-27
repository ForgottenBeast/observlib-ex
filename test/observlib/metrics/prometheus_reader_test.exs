defmodule ObservLib.Metrics.PrometheusReaderTest do
  use ExUnit.Case, async: false

  alias ObservLib.Metrics.{PrometheusReader, MeterProvider}

  @test_port 19568

  setup do
    # Start Config first
    start_supervised!(ObservLib.Config)

    # Start MeterProvider (required for PrometheusReader)
    start_supervised!(MeterProvider)

    # Start PrometheusReader with test port
    start_supervised!({PrometheusReader, port: @test_port})

    # Wait for TCP listener to be ready
    Process.sleep(100)

    on_exit(fn ->
      :ok
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts the PrometheusReader GenServer" do
      assert Process.whereis(PrometheusReader) != nil
      assert Process.alive?(Process.whereis(PrometheusReader))
    end

    test "listens on configured port" do
      assert PrometheusReader.get_port() == @test_port
    end
  end

  describe "get_stats/0" do
    test "returns statistics" do
      stats = PrometheusReader.get_stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :port)
      assert Map.has_key?(stats, :scrape_count)
      assert Map.has_key?(stats, :error_count)
      assert Map.has_key?(stats, :last_scrape_time)
    end
  end

  describe "HTTP endpoint" do
    test "responds to GET /metrics with 200" do
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "HTTP/1.1 200 OK"
      assert response =~ "Content-Type: text/plain"
    end

    test "returns 404 for non-metrics paths" do
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /other HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "HTTP/1.1 404 Not Found"
    end

    test "returns empty response when no metrics" do
      MeterProvider.reset()

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "HTTP/1.1 200 OK"
      # Content-Length should be 0 or body should be empty
      assert response =~ "Content-Length: 0" or String.ends_with?(String.trim(response), "\r\n\r\n")
    end

    test "formats counter metrics in Prometheus format" do
      MeterProvider.record("http_requests_total", :counter, 42, %{method: "GET", status: "200"})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "# TYPE http_requests_total counter"
      assert response =~ "http_requests_total{"
      assert response =~ "method=\"GET\""
      assert response =~ "status=\"200\""
      assert response =~ "} 42"
    end

    test "formats gauge metrics in Prometheus format" do
      MeterProvider.record("memory_usage_bytes", :gauge, 1024.5, %{type: "heap"})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "# TYPE memory_usage_bytes gauge"
      assert response =~ "memory_usage_bytes{type=\"heap\"}"
    end

    test "formats histogram metrics in Prometheus format" do
      MeterProvider.record("request_duration_seconds", :histogram, 0.5, %{})
      MeterProvider.record("request_duration_seconds", :histogram, 1.5, %{})
      MeterProvider.record("request_duration_seconds", :histogram, 2.5, %{})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "# TYPE request_duration_seconds histogram"
      assert response =~ "request_duration_seconds_bucket"
      assert response =~ "le="
      assert response =~ "request_duration_seconds_sum"
      assert response =~ "request_duration_seconds_count"
    end

    test "handles metrics without labels" do
      MeterProvider.record("simple_counter", :counter, 10, %{})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "simple_counter 10"
    end

    test "escapes special characters in label values" do
      MeterProvider.record("test_metric", :counter, 1, %{path: "/api/users\"test"})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # Double quotes should be escaped
      assert response =~ "\\\""
    end

    test "increments scrape count on successful scrape" do
      initial_stats = PrometheusReader.get_stats()

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")
      {:ok, _response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # Wait for stats update
      Process.sleep(100)

      final_stats = PrometheusReader.get_stats()
      assert final_stats.scrape_count > initial_stats.scrape_count
    end
  end

  describe "metric name sanitization" do
    test "replaces invalid characters with underscores" do
      MeterProvider.record("http.request-duration", :counter, 1, %{})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # Dots and dashes should be replaced with underscores
      assert response =~ "http_request_duration"
    end
  end
end
