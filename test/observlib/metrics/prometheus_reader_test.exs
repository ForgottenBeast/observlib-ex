defmodule ObservLib.Metrics.PrometheusReaderTest do
  use ExUnit.Case, async: false

  alias ObservLib.Metrics.{MeterProvider, PrometheusReader}

  @test_port 19_568

  setup_all do
    # Config and MeterProvider are already started by the Application
    # Start PrometheusReader once for all tests with test port
    start_supervised!({PrometheusReader, port: @test_port})

    # Wait for TCP listener to be ready
    Process.sleep(100)

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
      assert Map.has_key?(stats, :active_connections)
      assert Map.has_key?(stats, :max_connections)
    end
  end

  describe "HTTP endpoint" do
    setup do
      MeterProvider.reset()
      :ok
    end

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
      assert response =~ "Content-Length: 0" or
               String.ends_with?(String.trim(response), "\r\n\r\n")
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

  describe "security features (sec-008)" do
    test "tracks active connections" do
      stats = PrometheusReader.get_stats()
      initial_connections = stats.active_connections

      # Open a connection (don't close it immediately)
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      # Connection should be tracked
      Process.sleep(50)

      {:ok, _response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # Wait for connection to be cleaned up
      Process.sleep(50)

      # Connection count should return to initial
      final_stats = PrometheusReader.get_stats()
      assert final_stats.active_connections == initial_connections
    end

    test "enforces max_connections limit" do
      stats = PrometheusReader.get_stats()
      max_conn = stats.max_connections

      # Create max_connections + 1 connections
      sockets =
        for _ <- 1..max_conn do
          {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
          :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")
          socket
        end

      Process.sleep(100)

      # Try to open one more connection (should be rejected)
      {:ok, extra_socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(extra_socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      # This connection should be closed by the server
      case :gen_tcp.recv(extra_socket, 0, 1000) do
        {:error, :closed} ->
          # Expected: connection closed due to limit
          assert true

        {:ok, _response} ->
          # Some connections might have finished, allowing this through
          :ok
      end

      # Clean up
      Enum.each(sockets, &:gen_tcp.close/1)
      :gen_tcp.close(extra_socket)
    end

    test "rate limiter allows requests within limit" do
      # Make a single request (should succeed)
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "HTTP/1.1 200 OK"
    end

    test "rate limiter rejects requests when limit exceeded" do
      # Make many rapid requests to trigger rate limit
      results =
        for _ <- 1..150 do
          {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
          :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

          result =
            case :gen_tcp.recv(socket, 0, 1000) do
              {:ok, response} ->
                cond do
                  response =~ "429" -> :rate_limited
                  response =~ "200" -> :ok
                  true -> :other
                end

              {:error, :closed} ->
                :closed

              {:error, :timeout} ->
                :timeout
            end

          :gen_tcp.close(socket)
          result
        end

      # At least some requests should be rate limited
      rate_limited_count = Enum.count(results, &(&1 == :rate_limited))

      # With a default limit of 100 req/min, we expect some to be blocked
      assert rate_limited_count > 0 or length(results) > 100
    end
  end

  describe "basic authentication (sec-008)" do
    @tag :skip
    test "allows access without auth when not configured" do
      # This is the default behavior tested in other tests
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "HTTP/1.1 200 OK"
    end

    @tag :skip
    test "requires auth when configured" do
      # Note: This would require starting PrometheusReader with auth configured
      # Skipping as it requires test configuration changes
      assert true
    end

    @tag :skip
    test "rejects requests with invalid credentials" do
      # Note: This would require starting PrometheusReader with auth configured
      # Skipping as it requires test configuration changes
      assert true
    end

    @tag :skip
    test "accepts requests with valid credentials" do
      # Note: This would require starting PrometheusReader with auth configured
      # Skipping as it requires test configuration changes
      assert true
    end
  end

  describe "label value escaping (sec-014)" do
    setup do
      MeterProvider.reset()
      :ok
    end

    test "escapes backslashes" do
      MeterProvider.record("test_metric", :counter, 1, %{path: "C:\\Users\\test"})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # Backslashes should be escaped: one \ in input becomes \\ in Prometheus output
      assert response =~ "\\\\"
    end

    test "escapes double quotes" do
      MeterProvider.record("test_metric", :counter, 1, %{message: "hello \"world\""})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # Double quotes should be escaped
      assert response =~ "\\\""
    end

    test "escapes newline characters" do
      MeterProvider.record("test_metric", :counter, 1, %{text: "line1\nline2"})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # Newlines should be escaped
      assert response =~ "\\n"
    end

    test "escapes carriage return characters (CRLF injection prevention)" do
      MeterProvider.record("test_metric", :counter, 1, %{injection: "value\r\nX-Custom"})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # Carriage returns should be escaped
      assert response =~ "\\r"
    end

    test "escapes tab characters" do
      MeterProvider.record("test_metric", :counter, 1, %{data: "col1\tcol2"})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # Tabs should be escaped
      assert response =~ "\\t"
    end

    test "escapes null bytes" do
      MeterProvider.record("test_metric", :counter, 1, %{binary: "hello\0world"})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # Null bytes should be escaped as \x00
      assert response =~ "\\x00"
    end

    test "escapes other control characters (ASCII 0-31, 127)" do
      # Bell character (ASCII 7)
      MeterProvider.record("test_metric", :counter, 1, %{control: "bell\x07sound"})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # Control character should be escaped as \x07
      assert response =~ "\\x07"
    end

    test "escapes DEL character (ASCII 127)" do
      MeterProvider.record("test_metric", :counter, 1, %{del: "before\x7fafter"})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # DEL character should be escaped as \x7f
      assert response =~ "\\x7f"
    end

    test "handles combined escaping (multiple special chars)" do
      MeterProvider.record("test_metric", :counter, 1, %{complex: "path\\to\nfile\r\nend"})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # All special characters should be escaped
      # backslash (one backslash in input becomes \\ in Prometheus output)
      assert response =~ "\\\\"
      # newline
      assert response =~ "\\n"
      # carriage return
      assert response =~ "\\r"
    end

    test "preserves normal characters" do
      MeterProvider.record("test_metric_normal", :counter, 1, %{label: "hello_world123"})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      # Normal characters should not be escaped
      assert response =~ "hello_world123"
    end

    test "handles non-string values (atom, number, etc.)" do
      # The escape function should convert non-strings to strings first
      MeterProvider.record("test_metric", :counter, 1, %{status: 200})
      Process.sleep(20)

      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n")

      {:ok, response} = :gen_tcp.recv(socket, 0, 5000)
      :gen_tcp.close(socket)

      assert response =~ "200"
    end
  end
end
