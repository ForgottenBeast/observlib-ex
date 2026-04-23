defmodule ObservLib.LogsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  describe "log/3" do
    test "emits log at debug level" do
      log =
        capture_log(fn ->
          ObservLib.Logs.log(:debug, "Debug message")
        end)

      assert log =~ "Debug message"
    end

    test "emits log at info level" do
      log =
        capture_log(fn ->
          ObservLib.Logs.log(:info, "Info message")
        end)

      assert log =~ "Info message"
    end

    test "emits log at warn level" do
      log =
        capture_log(fn ->
          ObservLib.Logs.log(:warn, "Warning message")
        end)

      assert log =~ "Warning message"
    end

    test "emits log at error level" do
      log =
        capture_log(fn ->
          ObservLib.Logs.log(:error, "Error message")
        end)

      assert log =~ "Error message"
    end

    test "returns :ok" do
      assert ObservLib.Logs.log(:info, "Test message") == :ok
    end

    test "accepts attributes as map" do
      log =
        capture_log(fn ->
          ObservLib.Logs.log(:info, "Message with attributes", %{user_id: 123, action: "login"})
        end)

      assert log =~ "Message with attributes"
    end

    test "accepts attributes as keyword list" do
      log =
        capture_log(fn ->
          ObservLib.Logs.log(:info, "Message with keywords", user_id: 456, action: "logout")
        end)

      assert log =~ "Message with keywords"
    end

    test "handles empty attributes" do
      log =
        capture_log(fn ->
          ObservLib.Logs.log(:info, "Message without attributes", %{})
        end)

      assert log =~ "Message without attributes"
    end
  end

  describe "debug/2" do
    test "logs at debug level" do
      log =
        capture_log(fn ->
          ObservLib.Logs.debug("Debug message")
        end)

      assert log =~ "Debug message"
    end

    test "accepts attributes" do
      log =
        capture_log(fn ->
          ObservLib.Logs.debug("Debug with attrs", key: "value")
        end)

      assert log =~ "Debug with attrs"
    end

    test "returns :ok" do
      assert ObservLib.Logs.debug("Test") == :ok
    end
  end

  describe "info/2" do
    test "logs at info level" do
      log =
        capture_log(fn ->
          ObservLib.Logs.info("Info message")
        end)

      assert log =~ "Info message"
    end

    test "accepts attributes" do
      log =
        capture_log(fn ->
          ObservLib.Logs.info("Info with attrs", status: "success")
        end)

      assert log =~ "Info with attrs"
    end

    test "returns :ok" do
      assert ObservLib.Logs.info("Test") == :ok
    end
  end

  describe "warn/2" do
    test "logs at warn level" do
      log =
        capture_log(fn ->
          ObservLib.Logs.warn("Warning message")
        end)

      assert log =~ "Warning message"
    end

    test "accepts attributes" do
      log =
        capture_log(fn ->
          ObservLib.Logs.warn("Warning with attrs", threshold: 90)
        end)

      assert log =~ "Warning with attrs"
    end

    test "returns :ok" do
      assert ObservLib.Logs.warn("Test") == :ok
    end
  end

  describe "error/2" do
    test "logs at error level" do
      log =
        capture_log(fn ->
          ObservLib.Logs.error("Error message")
        end)

      assert log =~ "Error message"
    end

    test "accepts attributes" do
      log =
        capture_log(fn ->
          ObservLib.Logs.error("Error with attrs", code: 500)
        end)

      assert log =~ "Error with attrs"
    end

    test "returns :ok" do
      assert ObservLib.Logs.error("Test") == :ok
    end
  end

  describe "structured logging" do
    test "logs with structured attributes as map" do
      log =
        capture_log(fn ->
          ObservLib.Logs.info("User action", %{
            user_id: 123,
            action: "login",
            timestamp: "2026-03-27T10:00:00Z"
          })
        end)

      assert log =~ "User action"
    end

    test "logs with structured attributes as keyword list" do
      log =
        capture_log(fn ->
          ObservLib.Logs.info("Request processed",
            request_id: "abc-123",
            duration_ms: 42,
            status_code: 200
          )
        end)

      assert log =~ "Request processed"
    end

    test "handles mixed attribute types" do
      log =
        capture_log(fn ->
          ObservLib.Logs.info("Complex log", %{
            string_val: "text",
            int_val: 123,
            float_val: 45.67,
            bool_val: true
          })
        end)

      assert log =~ "Complex log"
    end
  end

  describe "with_context/2" do
    test "adds context attributes to logs within function" do
      log =
        capture_log(fn ->
          ObservLib.Logs.with_context(%{request_id: "abc-123"}, fn ->
            ObservLib.Logs.info("Processing request")
          end)
        end)

      assert log =~ "Processing request"
    end

    test "returns function result" do
      result =
        ObservLib.Logs.with_context(%{key: "value"}, fn ->
          42
        end)

      assert result == 42
    end

    test "cleans up context after function execution" do
      # Set context
      ObservLib.Logs.with_context(%{request_id: "test-1"}, fn ->
        ObservLib.Logs.info("Inside context")
      end)

      # Verify context is cleaned up by checking process dictionary
      assert Process.get(:observlib_log_context) == nil
    end

    test "context applies to multiple log calls" do
      log =
        capture_log(fn ->
          ObservLib.Logs.with_context(%{request_id: "req-456"}, fn ->
            ObservLib.Logs.info("First log")
            ObservLib.Logs.debug("Second log")
            ObservLib.Logs.warn("Third log")
          end)
        end)

      assert log =~ "First log"
      assert log =~ "Second log"
      assert log =~ "Third log"
    end

    test "nested contexts merge attributes" do
      log =
        capture_log(fn ->
          ObservLib.Logs.with_context(%{outer: "value1"}, fn ->
            ObservLib.Logs.with_context(%{inner: "value2"}, fn ->
              ObservLib.Logs.info("Nested log")
            end)
          end)
        end)

      assert log =~ "Nested log"
    end

    test "inner context attributes override outer context" do
      log =
        capture_log(fn ->
          ObservLib.Logs.with_context(%{key: "outer"}, fn ->
            ObservLib.Logs.with_context(%{key: "inner"}, fn ->
              ObservLib.Logs.info("Override test")
            end)
          end)
        end)

      assert log =~ "Override test"
    end

    test "context is restored after nested execution" do
      ObservLib.Logs.with_context(%{level1: "value1"}, fn ->
        ObservLib.Logs.with_context(%{level2: "value2"}, fn ->
          # Inner context
          :ok
        end)

        # After inner context, only level1 should remain
        context = Process.get(:observlib_log_context)
        assert context == %{level1: "value1"}
      end)

      # After outer context, nothing should remain
      assert Process.get(:observlib_log_context) == nil
    end

    test "accepts keyword list as context" do
      log =
        capture_log(fn ->
          ObservLib.Logs.with_context([user_id: 789, session_id: "xyz"], fn ->
            ObservLib.Logs.info("Context as keyword list")
          end)
        end)

      assert log =~ "Context as keyword list"
    end

    test "context survives exceptions but still cleans up" do
      assert_raise RuntimeError, "test error", fn ->
        ObservLib.Logs.with_context(%{request_id: "error-test"}, fn ->
          raise "test error"
        end)
      end

      # Context should be cleaned up even after exception
      assert Process.get(:observlib_log_context) == nil
    end
  end

  describe "attach_logger_handler/0" do
    test "returns :ok on successful attachment" do
      # Detach first if it exists
      ObservLib.Logs.detach_logger_handler()

      assert ObservLib.Logs.attach_logger_handler() == :ok
    end

    test "returns :ok if handler already exists" do
      # Attach twice
      ObservLib.Logs.attach_logger_handler()
      assert ObservLib.Logs.attach_logger_handler() == :ok
    end

    test "handler can be attached after detachment" do
      ObservLib.Logs.detach_logger_handler()
      assert ObservLib.Logs.attach_logger_handler() == :ok
    end
  end

  describe "detach_logger_handler/0" do
    test "returns :ok on successful detachment" do
      # Attach first
      ObservLib.Logs.attach_logger_handler()

      assert ObservLib.Logs.detach_logger_handler() == :ok
    end

    test "returns :ok if handler doesn't exist" do
      # Detach twice
      ObservLib.Logs.detach_logger_handler()
      assert ObservLib.Logs.detach_logger_handler() == :ok
    end

    test "logs still work after detachment" do
      ObservLib.Logs.detach_logger_handler()

      log =
        capture_log(fn ->
          ObservLib.Logs.info("Log after detachment")
        end)

      assert log =~ "Log after detachment"
    end
  end

  describe "handler lifecycle" do
    test "attach and detach cycle" do
      assert ObservLib.Logs.attach_logger_handler() == :ok
      assert ObservLib.Logs.detach_logger_handler() == :ok
      assert ObservLib.Logs.attach_logger_handler() == :ok
      assert ObservLib.Logs.detach_logger_handler() == :ok
    end

    test "logs work during entire lifecycle" do
      ObservLib.Logs.attach_logger_handler()

      log1 =
        capture_log(fn ->
          ObservLib.Logs.info("With handler")
        end)

      ObservLib.Logs.detach_logger_handler()

      log2 =
        capture_log(fn ->
          ObservLib.Logs.info("Without handler")
        end)

      assert log1 =~ "With handler"
      assert log2 =~ "Without handler"
    end
  end

  describe "integration tests" do
    test "structured logging with context" do
      log =
        capture_log(fn ->
          ObservLib.Logs.with_context(%{request_id: "integration-test"}, fn ->
            ObservLib.Logs.info("Starting process", step: 1)
            ObservLib.Logs.debug("Processing data", step: 2)
            ObservLib.Logs.info("Process complete", step: 3, status: "success")
          end)
        end)

      assert log =~ "Starting process"
      assert log =~ "Processing data"
      assert log =~ "Process complete"
    end

    test "multiple log levels in sequence" do
      log =
        capture_log(fn ->
          ObservLib.Logs.debug("Debug message", level: 1)
          ObservLib.Logs.info("Info message", level: 2)
          ObservLib.Logs.warn("Warning message", level: 3)
          ObservLib.Logs.error("Error message", level: 4)
        end)

      assert log =~ "Debug message"
      assert log =~ "Info message"
      assert log =~ "Warning message"
      assert log =~ "Error message"
    end

    test "context with different attribute types" do
      log =
        capture_log(fn ->
          ObservLib.Logs.with_context(
            %{
              user_id: 123,
              session_token: "abc-def-ghi",
              is_authenticated: true,
              request_time: 1_234_567_890.123
            },
            fn ->
              ObservLib.Logs.info("Complex context test")
            end
          )
        end)

      assert log =~ "Complex context test"
    end
  end
end
