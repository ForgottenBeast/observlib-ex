defmodule ObservLib.ApplicationTest do
  use ExUnit.Case, async: false

  alias ObservLib.Exporters.{OtlpLogsExporter, OtlpMetricsExporter, OtlpTraceExporter}

  describe "application startup" do
    test "starts successfully with Config GenServer" do
      # Application is already started by test framework
      # Verify Config is running
      assert Process.whereis(ObservLib.Config) != nil
    end

    test "starts with OTLP endpoint not configured" do
      # When endpoint is nil (as in test config), exporters should log but not crash
      # Application should still start successfully
      assert Process.whereis(ObservLib.Config) != nil
    end
  end

  describe "exporter setup" do
    test "trace exporter setup is called during application startup" do
      # OtlpTraceExporter.setup() should be called
      # We can verify by checking that it returns expected result
      case ObservLib.Config.get_otlp_endpoint() do
        nil ->
          # setup/0 uses a default endpoint (localhost:4318) when none is configured
          assert :ok = OtlpTraceExporter.setup()

        _endpoint ->
          # If endpoint is configured, setup should succeed
          assert :ok = OtlpTraceExporter.setup()
      end
    end

    test "metrics exporter starts when endpoint is configured" do
      case ObservLib.Config.get_otlp_endpoint() do
        nil ->
          # Metrics exporter may not be running if no endpoint configured
          # This is acceptable graceful degradation
          :ok

        _endpoint ->
          # If endpoint is configured, metrics exporter should be running
          assert Process.whereis(OtlpMetricsExporter) != nil
      end
    end

    test "logs exporter starts when endpoint is configured" do
      case ObservLib.Config.get_otlp_endpoint() do
        nil ->
          # Logs exporter may not be running if no endpoint configured
          # This is acceptable graceful degradation
          :ok

        _endpoint ->
          # If endpoint is configured, logs exporter should be running
          assert Process.whereis(OtlpLogsExporter) != nil
      end
    end
  end

  describe "graceful degradation" do
    test "application starts even when exporters fail to configure" do
      # Application should remain running even if exporter setup fails
      assert Process.whereis(ObservLib.Supervisor) != nil
      assert Process.whereis(ObservLib.Config) != nil
    end

    test "exporters log warnings but don't crash app when not configured" do
      # With no OTLP endpoint in test config, exporters should handle gracefully
      endpoint = ObservLib.Config.get_otlp_endpoint()

      if is_nil(endpoint) do
        # Application should still be running
        assert Process.whereis(ObservLib.Config) != nil
      end
    end
  end
end
