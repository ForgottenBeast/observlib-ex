defmodule ObservLib.Security.AccessControlTest do
  use ExUnit.Case, async: false

  @moduletag :security

  describe "sec-013: ETS table access control" do
    test "metrics ETS table uses :protected access mode" do
      # Get table info
      table_info = :ets.info(:observlib_metrics)

      assert table_info != :undefined
      assert table_info[:protection] == :protected
    end

    test "registry ETS table uses :protected access mode" do
      table_info = :ets.info(:observlib_metric_registry)

      assert table_info != :undefined
      assert table_info[:protection] == :protected
    end

    test "active spans ETS table uses :protected access mode" do
      table_info = :ets.info(:observlib_active_spans)

      assert table_info != :undefined
      assert table_info[:protection] == :protected
    end

    test "external processes can read from protected ETS tables" do
      # Record a metric from this process
      ObservLib.Metrics.counter("access.test", 1, %{source: "test"})

      # Read from a different process
      task =
        Task.async(fn ->
          # Should be able to read
          metrics = :ets.tab2list(:observlib_metrics)
          assert is_list(metrics)
          metrics
        end)

      result = Task.await(task)
      assert is_list(result)
    end

    test "external processes cannot write to protected ETS tables" do
      # Attempt to write from a different process
      task =
        Task.async(fn ->
          try do
            :ets.insert(
              :observlib_metrics,
              {{"malicious.metric", %{}}, %{type: :counter, value: 999}}
            )

            :write_succeeded
          rescue
            ArgumentError -> :write_failed
          end
        end)

      result = Task.await(task)
      assert result == :write_failed
    end

    test "external processes cannot delete from protected ETS tables" do
      # Record a metric
      ObservLib.Metrics.counter("protected.metric", 1, %{})

      # Attempt to delete from a different process
      task =
        Task.async(fn ->
          try do
            :ets.delete(:observlib_metrics, {"protected.metric", %{}})
            :delete_succeeded
          rescue
            ArgumentError -> :delete_failed
          end
        end)

      result = Task.await(task)
      assert result == :delete_failed
    end

    test "external processes cannot clear protected ETS tables" do
      # Record some metrics
      ObservLib.Metrics.counter("test.metric.1", 1, %{})
      ObservLib.Metrics.counter("test.metric.2", 1, %{})

      # Attempt to clear from a different process
      task =
        Task.async(fn ->
          try do
            :ets.delete_all_objects(:observlib_metrics)
            :clear_succeeded
          rescue
            ArgumentError -> :clear_failed
          end
        end)

      result = Task.await(task)
      assert result == :clear_failed

      # Verify metrics still exist
      metrics = :ets.tab2list(:observlib_metrics)
      assert length(metrics) >= 2
    end

    test "only MeterProvider process can write to metrics table" do
      meter_provider_pid = Process.whereis(ObservLib.Metrics.MeterProvider)
      assert meter_provider_pid != nil

      # Get table owner
      table_info = :ets.info(:observlib_metrics)
      owner_pid = table_info[:owner]

      # Owner should be the MeterProvider
      assert owner_pid == meter_provider_pid
    end

    test "only Traces.Provider process can write to spans table" do
      traces_provider_pid = Process.whereis(ObservLib.Traces.Provider)
      assert traces_provider_pid != nil

      # Get table owner
      table_info = :ets.info(:observlib_active_spans)
      owner_pid = table_info[:owner]

      # Owner should be the Traces.Provider
      assert owner_pid == traces_provider_pid
    end

    test "ETS tables have read_concurrency enabled for performance" do
      metrics_info = :ets.info(:observlib_metrics)
      registry_info = :ets.info(:observlib_metric_registry)
      spans_info = :ets.info(:observlib_active_spans)

      assert metrics_info[:read_concurrency] == true
      assert registry_info[:read_concurrency] == true
      assert spans_info[:read_concurrency] == true
    end
  end
end
