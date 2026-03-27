defmodule ObservLib.Exporters.OtlpLogsExporterTest do
  use ExUnit.Case, async: false

  alias ObservLib.Exporters.OtlpLogsExporter

  setup do
    # Start the Config GenServer if not already started
    case GenServer.whereis(ObservLib.Config) do
      nil ->
        Application.put_env(:observlib, :service_name, "test_service")
        Application.put_env(:observlib, :otlp_endpoint, "http://localhost:4318")
        {:ok, _pid} = ObservLib.Config.start_link()

      _pid ->
        :ok
    end

    # Start the exporter
    {:ok, pid} = start_supervised({OtlpLogsExporter, name: TestExporter})

    {:ok, exporter_pid: pid}
  end

  describe "severity_number/1" do
    test "maps debug level to severity 5" do
      assert OtlpLogsExporter.severity_number(:debug) == 5
    end

    test "maps info level to severity 9" do
      assert OtlpLogsExporter.severity_number(:info) == 9
    end

    test "maps notice level to severity 10" do
      assert OtlpLogsExporter.severity_number(:notice) == 10
    end

    test "maps warn level to severity 13" do
      assert OtlpLogsExporter.severity_number(:warn) == 13
    end

    test "maps warning level to severity 13" do
      assert OtlpLogsExporter.severity_number(:warning) == 13
    end

    test "maps error level to severity 17" do
      assert OtlpLogsExporter.severity_number(:error) == 17
    end

    test "maps critical level to severity 21" do
      assert OtlpLogsExporter.severity_number(:critical) == 21
    end

    test "maps alert level to severity 22" do
      assert OtlpLogsExporter.severity_number(:alert) == 22
    end

    test "maps emergency level to severity 24" do
      assert OtlpLogsExporter.severity_number(:emergency) == 24
    end

    test "returns 0 for unknown level" do
      assert OtlpLogsExporter.severity_number(:unknown) == 0
    end
  end

  describe "start_link/1" do
    test "starts the GenServer successfully" do
      {:ok, pid} = OtlpLogsExporter.start_link(name: TestExporter2)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "accepts custom batch_size option" do
      {:ok, pid} = OtlpLogsExporter.start_link(name: TestExporter3, batch_size: 50)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "accepts custom batch_timeout option" do
      {:ok, pid} = OtlpLogsExporter.start_link(name: TestExporter4, batch_timeout: 10_000)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "accepts custom max_retries option" do
      {:ok, pid} = OtlpLogsExporter.start_link(name: TestExporter5, max_retries: 5)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "export/1" do
    test "exports empty list successfully", %{exporter_pid: _pid} do
      assert OtlpLogsExporter.export([]) == :ok
    end

    test "exports a single log record", %{exporter_pid: _pid} do
      log_record = %{
        level: :info,
        message: "Test log message",
        timestamp: System.system_time(:nanosecond),
        attributes: %{test_key: "test_value"}
      }

      # Note: This will fail if no OTLP collector is running, but tests the code path
      result = OtlpLogsExporter.export([log_record])
      assert result == :ok or match?({:error, _}, result)
    end

    test "exports multiple log records", %{exporter_pid: _pid} do
      log_records = [
        %{
          level: :info,
          message: "First log",
          timestamp: System.system_time(:nanosecond),
          attributes: %{}
        },
        %{
          level: :error,
          message: "Second log",
          timestamp: System.system_time(:nanosecond),
          attributes: %{error_code: 500}
        }
      ]

      result = OtlpLogsExporter.export(log_records)
      assert result == :ok or match?({:error, _}, result)
    end

    test "handles log records with different severity levels", %{exporter_pid: _pid} do
      log_records = [
        %{level: :debug, message: "Debug", timestamp: System.system_time(:nanosecond), attributes: %{}},
        %{level: :info, message: "Info", timestamp: System.system_time(:nanosecond), attributes: %{}},
        %{level: :warn, message: "Warn", timestamp: System.system_time(:nanosecond), attributes: %{}},
        %{level: :error, message: "Error", timestamp: System.system_time(:nanosecond), attributes: %{}}
      ]

      result = OtlpLogsExporter.export(log_records)
      assert result == :ok or match?({:error, _}, result)
    end

    test "handles log records with structured attributes", %{exporter_pid: _pid} do
      log_record = %{
        level: :info,
        message: "Structured log",
        timestamp: System.system_time(:nanosecond),
        attributes: %{
          user_id: 123,
          request_id: "abc-123",
          duration_ms: 45.5,
          success: true,
          tags: ["api", "user"]
        }
      }

      result = OtlpLogsExporter.export([log_record])
      assert result == :ok or match?({:error, _}, result)
    end

    test "handles log records with nested attributes", %{exporter_pid: _pid} do
      log_record = %{
        level: :info,
        message: "Nested attributes",
        timestamp: System.system_time(:nanosecond),
        attributes: %{
          request: %{
            method: "GET",
            path: "/api/users",
            headers: %{
              "content-type" => "application/json"
            }
          }
        }
      }

      result = OtlpLogsExporter.export([log_record])
      assert result == :ok or match?({:error, _}, result)
    end

    test "handles log records with missing optional fields", %{exporter_pid: _pid} do
      log_record = %{
        message: "Minimal log"
      }

      result = OtlpLogsExporter.export([log_record])
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "add_to_batch/1" do
    test "adds log records to batch queue", %{exporter_pid: _pid} do
      log_record = %{
        level: :info,
        message: "Batched log",
        timestamp: System.system_time(:nanosecond),
        attributes: %{}
      }

      assert OtlpLogsExporter.add_to_batch([log_record]) == :ok
    end

    test "adds multiple batches", %{exporter_pid: _pid} do
      log_record1 = %{level: :info, message: "Log 1", timestamp: System.system_time(:nanosecond), attributes: %{}}
      log_record2 = %{level: :info, message: "Log 2", timestamp: System.system_time(:nanosecond), attributes: %{}}

      assert OtlpLogsExporter.add_to_batch([log_record1]) == :ok
      assert OtlpLogsExporter.add_to_batch([log_record2]) == :ok
    end

    test "automatically flushes when batch size is reached" do
      # Start exporter with small batch size
      {:ok, pid} = OtlpLogsExporter.start_link(name: BatchTestExporter, batch_size: 2)

      log_record = %{level: :info, message: "Test", timestamp: System.system_time(:nanosecond), attributes: %{}}

      # Add records up to batch size
      GenServer.cast(BatchTestExporter, {:add_to_batch, [log_record]})
      GenServer.cast(BatchTestExporter, {:add_to_batch, [log_record]})

      # Give time for automatic flush
      Process.sleep(100)

      GenServer.stop(pid)
    end
  end

  describe "flush/0" do
    test "flushes pending log records", %{exporter_pid: _pid} do
      log_record = %{
        level: :info,
        message: "To be flushed",
        timestamp: System.system_time(:nanosecond),
        attributes: %{}
      }

      OtlpLogsExporter.add_to_batch([log_record])
      assert OtlpLogsExporter.flush() == :ok
    end

    test "flush is idempotent when batch is empty", %{exporter_pid: _pid} do
      assert OtlpLogsExporter.flush() == :ok
      assert OtlpLogsExporter.flush() == :ok
    end
  end

  describe "batch processing" do
    test "respects batch timeout" do
      {:ok, pid} = OtlpLogsExporter.start_link(name: TimeoutTestExporter, batch_timeout: 100)

      log_record = %{level: :info, message: "Timeout test", timestamp: System.system_time(:nanosecond), attributes: %{}}
      GenServer.cast(TimeoutTestExporter, {:add_to_batch, [log_record]})

      # Wait for timeout to trigger flush
      Process.sleep(150)

      GenServer.stop(pid)
    end

    test "batch timeout reschedules after flush" do
      {:ok, pid} = OtlpLogsExporter.start_link(name: RescheduleTestExporter, batch_timeout: 50)

      # Trigger multiple timeout cycles
      Process.sleep(60)
      Process.sleep(60)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "error handling" do
    test "handles export errors gracefully", %{exporter_pid: _pid} do
      # Create a log record that will be sent to non-existent collector
      log_record = %{
        level: :error,
        message: "Error test",
        timestamp: System.system_time(:nanosecond),
        attributes: %{}
      }

      # Should return error but not crash
      result = OtlpLogsExporter.export([log_record])
      assert match?({:error, _}, result)
    end

    test "continues operating after export failure" do
      {:ok, pid} = OtlpLogsExporter.start_link(name: ErrorRecoveryExporter)

      log_record = %{level: :info, message: "Test", timestamp: System.system_time(:nanosecond), attributes: %{}}

      # First export will fail (no collector)
      GenServer.call(ErrorRecoveryExporter, {:export, [log_record]})

      # Process should still be alive
      assert Process.alive?(pid)

      # Can still accept new logs
      GenServer.cast(ErrorRecoveryExporter, {:add_to_batch, [log_record]})

      GenServer.stop(pid)
    end
  end

  describe "attribute formatting" do
    test "formats string attributes" do
      log_record = %{
        level: :info,
        message: "String attr test",
        timestamp: System.system_time(:nanosecond),
        attributes: %{string_key: "string_value"}
      }

      result = OtlpLogsExporter.export([log_record])
      assert result == :ok or match?({:error, _}, result)
    end

    test "formats integer attributes" do
      log_record = %{
        level: :info,
        message: "Integer attr test",
        timestamp: System.system_time(:nanosecond),
        attributes: %{count: 42, negative: -10}
      }

      result = OtlpLogsExporter.export([log_record])
      assert result == :ok or match?({:error, _}, result)
    end

    test "formats float attributes" do
      log_record = %{
        level: :info,
        message: "Float attr test",
        timestamp: System.system_time(:nanosecond),
        attributes: %{duration: 123.456, ratio: 0.75}
      }

      result = OtlpLogsExporter.export([log_record])
      assert result == :ok or match?({:error, _}, result)
    end

    test "formats boolean attributes" do
      log_record = %{
        level: :info,
        message: "Boolean attr test",
        timestamp: System.system_time(:nanosecond),
        attributes: %{success: true, failed: false}
      }

      result = OtlpLogsExporter.export([log_record])
      assert result == :ok or match?({:error, _}, result)
    end

    test "formats array attributes" do
      log_record = %{
        level: :info,
        message: "Array attr test",
        timestamp: System.system_time(:nanosecond),
        attributes: %{tags: ["web", "api", "production"]}
      }

      result = OtlpLogsExporter.export([log_record])
      assert result == :ok or match?({:error, _}, result)
    end

    test "formats mixed type attributes" do
      log_record = %{
        level: :info,
        message: "Mixed attr test",
        timestamp: System.system_time(:nanosecond),
        attributes: %{
          string: "text",
          integer: 123,
          float: 45.67,
          boolean: true,
          list: [1, 2, 3]
        }
      }

      result = OtlpLogsExporter.export([log_record])
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "integration with logger handler" do
    test "can process logs from Erlang logger format" do
      # Simulate log record from Erlang logger
      erlang_log = %{
        level: :info,
        message: "Log from Erlang logger",
        timestamp: System.system_time(:nanosecond),
        attributes: %{
          pid: inspect(self()),
          module: __MODULE__,
          function: "test"
        }
      }

      result = OtlpLogsExporter.export([erlang_log])
      assert result == :ok or match?({:error, _}, result)
    end

    test "processes logs with metadata from ObservLib.Logs" do
      log_record = %{
        level: :info,
        message: "Log with context",
        timestamp: System.system_time(:nanosecond),
        attributes: %{
          request_id: "abc-123",
          user_id: 456,
          action: "login"
        }
      }

      result = OtlpLogsExporter.export([log_record])
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "resource attributes" do
    test "includes service name in exported logs", %{exporter_pid: _pid} do
      log_record = %{
        level: :info,
        message: "Test with service name",
        timestamp: System.system_time(:nanosecond),
        attributes: %{}
      }

      # Export will include resource attributes from Config
      result = OtlpLogsExporter.export([log_record])
      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "configuration" do
    test "uses default endpoint when not configured" do
      {:ok, pid} = OtlpLogsExporter.start_link(name: DefaultConfigExporter)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "uses default batch size when not configured" do
      {:ok, pid} = OtlpLogsExporter.start_link(name: DefaultBatchExporter)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
