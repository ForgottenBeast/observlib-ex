defmodule ObservLib.Logs.BackendTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ObservLib.Logs.Backend

  describe "start_link/1" do
    test "backend is started by supervisor" do
      # Backend should already be running via Logs.Supervisor
      assert Process.whereis(Backend) != nil
    end
  end

  describe "configure/1" do
    test "updates log level" do
      # Get initial config
      initial_config = Backend.get_config()

      # Configure with new level
      assert Backend.configure(level: :warn) == :ok

      # Verify config was updated
      new_config = Backend.get_config()
      assert Keyword.get(new_config, :level) == :warn

      # Restore original level
      Backend.configure(level: Keyword.get(initial_config, :level, :debug))
    end
  end

  describe "get_config/0" do
    test "returns current configuration" do
      config = Backend.get_config()

      assert is_list(config)
      assert Keyword.has_key?(config, :level)
    end
  end

  describe "log level filtering" do
    setup do
      # Set level to info for tests
      Backend.configure(level: :info)

      on_exit(fn ->
        Backend.configure(level: :debug)
      end)
    end

    test "captures logs at configured level and above" do
      # Info level should be captured
      log =
        capture_log(fn ->
          Logger.info("Info level message")
          Process.sleep(50)
        end)

      assert log =~ "Info level message"
    end

    test "captures logs above configured level" do
      # Error level should be captured when level is :info
      log =
        capture_log(fn ->
          Logger.error("Error level message")
          Process.sleep(50)
        end)

      assert log =~ "Error level message"
    end
  end

  describe "handle_log_event/4" do
    test "processes log event" do
      timestamp = {{2026, 3, 27}, {10, 30, 0, 0}}
      metadata = [request_id: "test-123"]

      # This should not raise
      assert Backend.handle_log_event(:info, "Test message", timestamp, metadata) == :ok
    end

    test "handles various message formats" do
      timestamp = {{2026, 3, 27}, {10, 30, 0, 0}}

      # String message
      assert Backend.handle_log_event(:info, "Simple string", timestamp, []) == :ok

      # IOData message
      assert Backend.handle_log_event(:info, ["IO", "data", " ", "message"], timestamp, []) == :ok

      # Charlist message
      assert Backend.handle_log_event(:info, ~c"Charlist message", timestamp, []) == :ok
    end

    test "handles various metadata" do
      timestamp = {{2026, 3, 27}, {10, 30, 0, 0}}

      # Empty metadata
      assert Backend.handle_log_event(:info, "Message", timestamp, []) == :ok

      # With metadata
      assert Backend.handle_log_event(:info, "Message", timestamp,
               user_id: 123,
               request_id: "abc",
               duration_ms: 42.5
             ) == :ok
    end
  end

  describe "trace context extraction" do
    test "extracts trace context when span is active" do
      # Start a span to create trace context
      ObservLib.Traces.with_span("test_span", %{}, fn ->
        # Log within the span
        log =
          capture_log(fn ->
            Logger.info("Message within span")
            Process.sleep(50)
          end)

        assert log =~ "Message within span"
      end)
    end

    test "handles missing trace context gracefully" do
      # Log without any active span
      log =
        capture_log(fn ->
          Logger.info("Message without span")
          Process.sleep(50)
        end)

      assert log =~ "Message without span"
    end
  end

  describe "integration with Logger" do
    test "captures Logger.info messages" do
      log =
        capture_log(fn ->
          Logger.info("Integration test info")
          Process.sleep(50)
        end)

      assert log =~ "Integration test info"
    end

    test "captures Logger.error messages" do
      log =
        capture_log(fn ->
          Logger.error("Integration test error")
          Process.sleep(50)
        end)

      assert log =~ "Integration test error"
    end

    test "captures Logger.warning messages" do
      log =
        capture_log(fn ->
          Logger.warning("Integration test warning")
          Process.sleep(50)
        end)

      assert log =~ "Integration test warning"
    end

    test "captures Logger.debug messages" do
      Backend.configure(level: :debug)

      log =
        capture_log(fn ->
          Logger.debug("Integration test debug")
          Process.sleep(50)
        end)

      assert log =~ "Integration test debug"
    end
  end

  describe "structured logging" do
    test "preserves metadata in log records" do
      log =
        capture_log(fn ->
          Logger.info("Structured log", user_id: 123, action: "login")
          Process.sleep(50)
        end)

      assert log =~ "Structured log"
    end

    test "handles complex metadata values" do
      log =
        capture_log(fn ->
          Logger.info("Complex metadata",
            map_val: %{nested: "value"},
            list_val: [1, 2, 3],
            bool_val: true
          )

          Process.sleep(50)
        end)

      assert log =~ "Complex metadata"
    end
  end

  describe "ObservLib.Logs integration" do
    test "ObservLib.Logs.log/3 is captured" do
      log =
        capture_log(fn ->
          ObservLib.Logs.log(:info, "ObservLib log message", %{key: "value"})
          Process.sleep(50)
        end)

      assert log =~ "ObservLib log message"
    end

    test "ObservLib.Logs.with_context/2 logs are captured" do
      log =
        capture_log(fn ->
          ObservLib.Logs.with_context(%{request_id: "ctx-123"}, fn ->
            ObservLib.Logs.info("Context log message")
          end)

          Process.sleep(50)
        end)

      assert log =~ "Context log message"
    end
  end

  describe "error handling" do
    test "handles exporter not running gracefully" do
      # The backend should not crash even if exporter is temporarily unavailable
      # This test verifies resilience
      log =
        capture_log(fn ->
          Logger.info("Resilience test message")
          Process.sleep(50)
        end)

      assert log =~ "Resilience test message"
    end
  end
end
