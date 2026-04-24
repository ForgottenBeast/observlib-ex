defmodule ObservLib.Exporters.OtlpTraceExporterTest do
  use ExUnit.Case, async: false

  alias ObservLib.Exporters.OtlpTraceExporter

  describe "get_configuration/0" do
    setup do
      # Store original configuration
      original_config = Application.get_all_env(:observlib)

      on_exit(fn ->
        # Restore original configuration
        Application.delete_env(:observlib, :otlp_endpoint)
        Application.delete_env(:observlib, :otlp_traces_endpoint)
        Application.delete_env(:observlib, :otlp_protocol)
        Application.delete_env(:observlib, :otlp_compression)
        Application.delete_env(:observlib, :otlp_batch_size)
        Application.delete_env(:observlib, :otlp_batch_timeout)
        Application.delete_env(:observlib, :otlp_max_queue_size)

        # Restore original values
        Enum.each(original_config, fn {key, value} ->
          Application.put_env(:observlib, key, value)
        end)
      end)

      :ok
    end

    test "returns default configuration when no endpoint is configured" do
      Application.delete_env(:observlib, :otlp_endpoint)
      Application.delete_env(:observlib, :otlp_traces_endpoint)

      assert {:ok, config} = OtlpTraceExporter.get_configuration()

      assert config.endpoint == "http://localhost:4318/v1/traces"
      assert config.protocol == :http_protobuf
      assert config.compression == nil
      assert config.batch_size == 512
      assert config.batch_timeout == 5000
      assert config.max_queue_size == 2048
    end

    test "uses otlp_endpoint with /v1/traces path appended" do
      Application.put_env(:observlib, :otlp_endpoint, "http://collector:4318")

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.endpoint == "http://collector:4318/v1/traces"
    end

    test "uses otlp_traces_endpoint without modification when provided" do
      Application.put_env(:observlib, :otlp_endpoint, "http://collector:4318")

      Application.put_env(
        :observlib,
        :otlp_traces_endpoint,
        "http://traces.collector:4318/custom/path"
      )

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      # Specific traces endpoint takes precedence
      assert config.endpoint == "http://traces.collector:4318/custom/path"
    end

    test "does not append /v1/traces if endpoint already has a path" do
      Application.put_env(:observlib, :otlp_endpoint, "http://collector:4318/my/custom/path")

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.endpoint == "http://collector:4318/my/custom/path"
    end

    test "configures protocol when specified" do
      Application.put_env(:observlib, :otlp_protocol, :grpc)

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.protocol == :grpc
    end

    test "configures compression when specified" do
      Application.put_env(:observlib, :otlp_compression, :gzip)

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.compression == :gzip
    end

    test "configures custom batch size" do
      Application.put_env(:observlib, :otlp_batch_size, 1024)

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.batch_size == 1024
    end

    test "configures custom batch timeout" do
      Application.put_env(:observlib, :otlp_batch_timeout, 10_000)

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.batch_timeout == 10_000
    end

    test "configures custom max queue size" do
      Application.put_env(:observlib, :otlp_max_queue_size, 4096)

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.max_queue_size == 4096
    end

    test "handles all configuration options together" do
      Application.put_env(
        :observlib,
        :otlp_traces_endpoint,
        "https://api.example.com:443/v1/traces"
      )

      Application.put_env(:observlib, :otlp_protocol, :grpc)
      Application.put_env(:observlib, :otlp_compression, :gzip)
      Application.put_env(:observlib, :otlp_batch_size, 256)
      Application.put_env(:observlib, :otlp_batch_timeout, 3000)
      Application.put_env(:observlib, :otlp_max_queue_size, 1024)

      assert {:ok, config} = OtlpTraceExporter.get_configuration()

      assert config.endpoint == "https://api.example.com:443/v1/traces"
      assert config.protocol == :grpc
      assert config.compression == :gzip
      assert config.batch_size == 256
      assert config.batch_timeout == 3000
      assert config.max_queue_size == 1024
    end
  end

  describe "setup/0" do
    setup do
      # Store original configuration
      original_config = Application.get_all_env(:observlib)
      original_exporter_config = Application.get_all_env(:opentelemetry_exporter)
      original_otel_config = Application.get_all_env(:opentelemetry)

      on_exit(fn ->
        # Restore configurations
        Application.delete_env(:observlib, :otlp_endpoint)
        Application.delete_env(:observlib, :otlp_traces_endpoint)
        Application.delete_env(:observlib, :otlp_protocol)
        Application.delete_env(:observlib, :otlp_compression)

        Enum.each(original_config, fn {key, value} ->
          Application.put_env(:observlib, key, value)
        end)

        Enum.each(original_exporter_config, fn {key, value} ->
          Application.put_env(:opentelemetry_exporter, key, value)
        end)

        Enum.each(original_otel_config, fn {key, value} ->
          Application.put_env(:opentelemetry, key, value)
        end)
      end)

      :ok
    end

    test "configures opentelemetry_exporter application with default settings" do
      Application.delete_env(:observlib, :otlp_endpoint)

      assert :ok = OtlpTraceExporter.setup()

      # Verify the exporter configuration was set
      assert Application.get_env(:opentelemetry_exporter, :otlp_protocol) == :http_protobuf

      assert Application.get_env(:opentelemetry_exporter, :otlp_traces_endpoint) ==
               "http://localhost:4318/v1/traces"

      # Verify OpenTelemetry is configured for batch processing
      assert Application.get_env(:opentelemetry, :span_processor) == :batch
      assert Application.get_env(:opentelemetry, :traces_exporter) == :otlp
    end

    test "configures opentelemetry_exporter with custom endpoint" do
      Application.put_env(:observlib, :otlp_traces_endpoint, "http://custom:4318/traces")

      assert :ok = OtlpTraceExporter.setup()

      assert Application.get_env(:opentelemetry_exporter, :otlp_traces_endpoint) ==
               "http://custom:4318/traces"
    end

    test "configures opentelemetry_exporter with grpc protocol" do
      Application.put_env(:observlib, :otlp_protocol, :grpc)

      assert :ok = OtlpTraceExporter.setup()

      assert Application.get_env(:opentelemetry_exporter, :otlp_protocol) == :grpc
    end

    test "configures opentelemetry_exporter with compression" do
      Application.put_env(:observlib, :otlp_compression, :gzip)

      assert :ok = OtlpTraceExporter.setup()

      assert Application.get_env(:opentelemetry_exporter, :otlp_traces_compression) == :gzip
    end

    test "configures batch processor settings" do
      Application.put_env(:observlib, :otlp_batch_size, 256)
      Application.put_env(:observlib, :otlp_batch_timeout, 3000)
      Application.put_env(:observlib, :otlp_max_queue_size, 1024)

      assert :ok = OtlpTraceExporter.setup()

      assert Application.get_env(:opentelemetry, :bsp_scheduled_delay_ms) == 3000
      assert Application.get_env(:opentelemetry, :bsp_max_queue_size) == 1024
      assert Application.get_env(:opentelemetry, :bsp_exporting_timeout_ms) == 6000
    end
  end

  describe "force_flush/0" do
    test "attempts to flush pending spans" do
      # force_flush may fail if processor is not initialized
      result = OtlpTraceExporter.force_flush()

      # Should either succeed or fail gracefully
      assert result in [:ok] or match?({:error, _}, result)
    end
  end

  describe "endpoint path handling" do
    setup do
      original_config = Application.get_all_env(:observlib)

      on_exit(fn ->
        Application.delete_env(:observlib, :otlp_endpoint)

        Enum.each(original_config, fn {key, value} ->
          Application.put_env(:observlib, key, value)
        end)
      end)

      :ok
    end

    test "appends /v1/traces to endpoint with no path" do
      Application.put_env(:observlib, :otlp_endpoint, "http://localhost:4318")

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.endpoint == "http://localhost:4318/v1/traces"
    end

    test "appends /v1/traces to endpoint with root path" do
      Application.put_env(:observlib, :otlp_endpoint, "http://localhost:4318/")

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.endpoint == "http://localhost:4318/v1/traces"
    end

    test "preserves custom paths in endpoint" do
      Application.put_env(:observlib, :otlp_endpoint, "http://localhost:4318/api/otlp")

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.endpoint == "http://localhost:4318/api/otlp"
    end

    test "handles endpoints with query parameters" do
      Application.put_env(:observlib, :otlp_endpoint, "http://localhost:4318?token=abc")

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.endpoint == "http://localhost:4318/v1/traces?token=abc"
    end
  end

  describe "batch processing configuration" do
    setup do
      original_config = Application.get_all_env(:observlib)

      on_exit(fn ->
        Application.delete_env(:observlib, :otlp_batch_size)
        Application.delete_env(:observlib, :otlp_batch_timeout)
        Application.delete_env(:observlib, :otlp_max_queue_size)

        Enum.each(original_config, fn {key, value} ->
          Application.put_env(:observlib, key, value)
        end)
      end)

      :ok
    end

    test "uses default batch size when not configured" do
      Application.delete_env(:observlib, :otlp_batch_size)

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.batch_size == 512
    end

    test "uses default batch timeout when not configured" do
      Application.delete_env(:observlib, :otlp_batch_timeout)

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.batch_timeout == 5000
    end

    test "uses default max queue size when not configured" do
      Application.delete_env(:observlib, :otlp_max_queue_size)

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.max_queue_size == 2048
    end

    test "respects configured batch parameters" do
      Application.put_env(:observlib, :otlp_batch_size, 100)
      Application.put_env(:observlib, :otlp_batch_timeout, 1000)
      Application.put_env(:observlib, :otlp_max_queue_size, 500)

      assert {:ok, config} = OtlpTraceExporter.get_configuration()
      assert config.batch_size == 100
      assert config.batch_timeout == 1000
      assert config.max_queue_size == 500
    end
  end
end
