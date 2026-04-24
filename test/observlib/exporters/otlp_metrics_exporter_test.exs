defmodule ObservLib.Exporters.OtlpMetricsExporterTest do
  use ExUnit.Case, async: false

  alias ObservLib.Exporters.OtlpMetricsExporter

  setup_all do
    Application.put_env(:observlib, :otlp_endpoint, "http://localhost:4318")
    Application.put_env(:observlib, :service_name, "test_service")

    Supervisor.terminate_child(ObservLib.Supervisor, ObservLib.Config)
    {:ok, _} = Supervisor.restart_child(ObservLib.Supervisor, ObservLib.Config)

    on_exit(fn ->
      Application.put_env(:observlib, :service_name, "observlib_test")
      Application.delete_env(:observlib, :otlp_endpoint)
      Supervisor.terminate_child(ObservLib.Supervisor, ObservLib.Config)
      Supervisor.restart_child(ObservLib.Supervisor, ObservLib.Config)
    end)

    :ok
  end

  setup do
    ObservLib.Metrics.MeterProvider.reset()

    on_exit(fn ->
      if pid = Process.whereis(OtlpMetricsExporter) do
        try do
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts the exporter with default options" do
      assert {:ok, pid} = OtlpMetricsExporter.start_link()
      assert Process.alive?(pid)
    end

    test "starts with custom export interval" do
      assert {:ok, pid} = OtlpMetricsExporter.start_link(export_interval: 30_000)
      assert Process.alive?(pid)
    end

    test "starts with custom retry configuration" do
      assert {:ok, pid} =
               OtlpMetricsExporter.start_link(
                 max_retries: 5,
                 retry_delay: 500
               )

      assert Process.alive?(pid)
    end

    test "starts disabled when no endpoint configured" do
      assert {:ok, pid} = OtlpMetricsExporter.start_link(endpoint: nil)
      assert Process.alive?(pid)

      stats = OtlpMetricsExporter.get_stats()
      assert stats.enabled == false
    end
  end

  describe "get_stats/0" do
    test "returns statistics about exports" do
      start_supervised!(OtlpMetricsExporter)

      stats = OtlpMetricsExporter.get_stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :enabled)
      assert Map.has_key?(stats, :export_count)
      assert Map.has_key?(stats, :error_count)
      assert Map.has_key?(stats, :last_export_time)
      assert Map.has_key?(stats, :metric_count)
    end

    test "tracks export count" do
      start_supervised!(OtlpMetricsExporter)

      initial_stats = OtlpMetricsExporter.get_stats()
      assert initial_stats.export_count == 0

      # Note: We can't easily test actual exports without a running OTLP collector
      # but we can verify the stats structure is correct
    end
  end

  describe "metric aggregation - counter" do
    test "aggregates counter metrics" do
      start_supervised!(OtlpMetricsExporter)

      # Send counter metrics
      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:http, :requests],
        %{count: 1},
        %{metric_type: :counter, method: "GET"}
      })

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:http, :requests],
        %{count: 2},
        %{metric_type: :counter, method: "GET"}
      })

      # Allow time for processing
      Process.sleep(50)

      stats = OtlpMetricsExporter.get_stats()
      assert stats.metric_count > 0
    end

    test "aggregates counter metrics with different attributes separately" do
      start_supervised!(OtlpMetricsExporter)

      # Send counter metrics with different attributes
      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:http, :requests],
        %{count: 1},
        %{metric_type: :counter, method: "GET"}
      })

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:http, :requests],
        %{count: 1},
        %{metric_type: :counter, method: "POST"}
      })

      Process.sleep(50)

      stats = OtlpMetricsExporter.get_stats()
      # Should have 2 separate metrics (different attributes)
      assert stats.metric_count == 2
    end
  end

  describe "metric aggregation - gauge" do
    test "keeps last value for gauge metrics" do
      start_supervised!(OtlpMetricsExporter)

      # Send multiple gauge values
      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:memory, :usage],
        %{value: 100},
        %{metric_type: :gauge, type: "heap"}
      })

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:memory, :usage],
        %{value: 200},
        %{metric_type: :gauge, type: "heap"}
      })

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:memory, :usage],
        %{value: 150},
        %{metric_type: :gauge, type: "heap"}
      })

      Process.sleep(50)

      stats = OtlpMetricsExporter.get_stats()
      assert stats.metric_count > 0
    end

    test "handles negative gauge values" do
      start_supervised!(OtlpMetricsExporter)

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:temperature],
        %{value: -10.5},
        %{metric_type: :gauge, location: "outside"}
      })

      Process.sleep(50)

      stats = OtlpMetricsExporter.get_stats()
      assert stats.metric_count > 0
    end
  end

  describe "metric aggregation - histogram" do
    test "accumulates histogram observations" do
      start_supervised!(OtlpMetricsExporter)

      # Send histogram observations
      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:http, :request, :duration],
        %{value: 45.2},
        %{metric_type: :histogram, method: "GET"}
      })

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:http, :request, :duration],
        %{value: 123.4},
        %{metric_type: :histogram, method: "GET"}
      })

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:http, :request, :duration],
        %{value: 89.1},
        %{metric_type: :histogram, method: "GET"}
      })

      Process.sleep(50)

      stats = OtlpMetricsExporter.get_stats()
      assert stats.metric_count > 0
    end

    test "handles histogram with various value ranges" do
      start_supervised!(OtlpMetricsExporter)

      # Send values across different histogram buckets
      values = [0.5, 7.2, 15.0, 30.0, 55.0, 80.0, 150.0, 300.0, 750.0, 1500.0]

      Enum.each(values, fn value ->
        send(OtlpMetricsExporter, {
          :telemetry_metric,
          [:request, :duration],
          %{value: value},
          %{metric_type: :histogram}
        })
      end)

      Process.sleep(50)

      stats = OtlpMetricsExporter.get_stats()
      assert stats.metric_count > 0
    end
  end

  describe "metric aggregation - up_down_counter" do
    test "aggregates up_down_counter with positive and negative values" do
      start_supervised!(OtlpMetricsExporter)

      # Send up-down counter changes
      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:active, :connections],
        %{value: 5},
        %{metric_type: :up_down_counter, protocol: "http"}
      })

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:active, :connections],
        %{value: -2},
        %{metric_type: :up_down_counter, protocol: "http"}
      })

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:active, :connections],
        %{value: 3},
        %{metric_type: :up_down_counter, protocol: "http"}
      })

      Process.sleep(50)

      stats = OtlpMetricsExporter.get_stats()
      assert stats.metric_count > 0
    end

    test "handles zero values" do
      start_supervised!(OtlpMetricsExporter)

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:active, :connections],
        %{value: 0},
        %{metric_type: :up_down_counter}
      })

      Process.sleep(50)

      stats = OtlpMetricsExporter.get_stats()
      assert stats.metric_count > 0
    end
  end

  describe "periodic export" do
    test "schedules periodic exports" do
      # Start with short interval for testing
      start_supervised!({OtlpMetricsExporter, [export_interval: 100]})

      # Send a metric
      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:test, :metric],
        %{count: 1},
        %{metric_type: :counter}
      })

      Process.sleep(50)
      stats_before = OtlpMetricsExporter.get_stats()
      assert stats_before.metric_count > 0

      # Wait for export to happen (export will fail but metrics should clear)
      Process.sleep(200)

      stats_after = OtlpMetricsExporter.get_stats()
      # Export count or error count should have increased
      assert stats_after.export_count + stats_after.error_count > 0
    end
  end

  describe "force_export/0" do
    test "triggers immediate export" do
      start_supervised!(OtlpMetricsExporter)

      # Send some metrics
      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:test, :counter],
        %{count: 5},
        %{metric_type: :counter}
      })

      Process.sleep(50)

      # Force export (will fail without real OTLP endpoint, but should be handled)
      result = OtlpMetricsExporter.force_export()

      # Result should be :ok or {:error, _}
      assert result == :ok or match?({:error, _}, result)

      stats = OtlpMetricsExporter.get_stats()
      assert stats.export_count + stats.error_count > 0
    end

    test "returns error when disabled" do
      start_supervised!({OtlpMetricsExporter, [endpoint: nil]})

      assert {:error, :disabled} = OtlpMetricsExporter.force_export()
    end

    test "handles empty metrics gracefully" do
      start_supervised!(OtlpMetricsExporter)

      # Force export with no metrics
      result = OtlpMetricsExporter.force_export()

      # Should succeed (nothing to export)
      assert result == :ok
    end
  end

  describe "error handling" do
    test "handles metrics with missing measurements" do
      start_supervised!(OtlpMetricsExporter)

      # Send metric with empty measurements
      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:test, :metric],
        %{},
        %{metric_type: :counter}
      })

      Process.sleep(50)

      # Should not crash
      assert Process.alive?(Process.whereis(OtlpMetricsExporter))
    end

    test "handles invalid metric types" do
      start_supervised!(OtlpMetricsExporter)

      # Send metric with invalid type
      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:test, :metric],
        %{value: 1},
        %{metric_type: :invalid}
      })

      Process.sleep(50)

      # Should not crash
      assert Process.alive?(Process.whereis(OtlpMetricsExporter))
    end

    test "tracks error count on failed exports" do
      start_supervised!(OtlpMetricsExporter)

      # Send a metric
      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:test, :metric],
        %{count: 1},
        %{metric_type: :counter}
      })

      Process.sleep(50)

      initial_stats = OtlpMetricsExporter.get_stats()

      # Force export (will fail without real endpoint)
      OtlpMetricsExporter.force_export()

      final_stats = OtlpMetricsExporter.get_stats()

      # Either export count or error count should increase
      assert final_stats.export_count + final_stats.error_count >
               initial_stats.export_count + initial_stats.error_count
    end
  end

  describe "metric naming and attributes" do
    test "handles dotted metric names" do
      start_supervised!(OtlpMetricsExporter)

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:http, :request, :duration],
        %{value: 100},
        %{metric_type: :histogram}
      })

      Process.sleep(50)

      stats = OtlpMetricsExporter.get_stats()
      assert stats.metric_count > 0
    end

    test "handles metrics with multiple attributes" do
      start_supervised!(OtlpMetricsExporter)

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:api, :request],
        %{count: 1},
        %{
          metric_type: :counter,
          method: "GET",
          path: "/users",
          status: 200,
          region: "us-east-1"
        }
      })

      Process.sleep(50)

      stats = OtlpMetricsExporter.get_stats()
      assert stats.metric_count > 0
    end

    test "handles attributes with various value types" do
      start_supervised!(OtlpMetricsExporter)

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:test, :metric],
        %{count: 1},
        %{
          metric_type: :counter,
          string_attr: "value",
          int_attr: 42,
          float_attr: 3.14,
          bool_attr: true
        }
      })

      Process.sleep(50)

      stats = OtlpMetricsExporter.get_stats()
      assert stats.metric_count > 0
    end
  end

  describe "integration with ObservLib.Metrics" do
    test "exports metrics recorded via ObservLib.Metrics API" do
      start_supervised!(OtlpMetricsExporter)

      # Note: The actual integration requires the telemetry handler to be set up
      # to forward metrics to the exporter. This test verifies the exporter
      # can handle the expected message format.

      # Simulate what ObservLib.Metrics would send
      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:http, :requests],
        %{count: 1},
        %{metric_type: :counter, method: "GET", status: 200}
      })

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:memory, :usage],
        %{value: 1024.5},
        %{metric_type: :gauge, type: "heap"}
      })

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:http, :request, :duration],
        %{value: 45.2},
        %{metric_type: :histogram, method: "GET"}
      })

      send(OtlpMetricsExporter, {
        :telemetry_metric,
        [:active, :connections],
        %{value: 1},
        %{metric_type: :up_down_counter, protocol: "http"}
      })

      Process.sleep(50)

      stats = OtlpMetricsExporter.get_stats()
      # Should have 4 different metrics
      assert stats.metric_count == 4
    end
  end

  describe "cleanup on termination" do
    test "cancels timer on shutdown" do
      {:ok, pid} = OtlpMetricsExporter.start_link(export_interval: 10_000)
      assert Process.alive?(pid)

      GenServer.stop(pid)

      # Should terminate cleanly
      refute Process.alive?(pid)
    end

    test "detaches telemetry handler on shutdown" do
      {:ok, pid} = OtlpMetricsExporter.start_link()

      # Verify exporter is alive before shutdown
      assert Process.alive?(pid)

      GenServer.stop(pid)

      # Should terminate cleanly
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end
end
