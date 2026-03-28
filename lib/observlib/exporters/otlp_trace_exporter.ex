defmodule ObservLib.Exporters.OtlpTraceExporter do
  @moduledoc """
  OTLP Traces Exporter for ObservLib.

  Configures OpenTelemetry to export spans to an OTLP-compatible collector
  using the :opentelemetry_exporter package. Supports HTTP/protobuf and gRPC
  protocols with configurable batch processing and retry logic.

  ## Configuration

  The exporter reads configuration from ObservLib.Config and applies it to
  the :opentelemetry and :opentelemetry_exporter applications:

    - `:otlp_endpoint` - Base OTLP endpoint URL (e.g., "http://localhost:4318")
    - `:otlp_traces_endpoint` - Specific traces endpoint (takes precedence)
    - `:otlp_protocol` - Protocol to use (`:http_protobuf` or `:grpc`, default: `:http_protobuf`)
    - `:otlp_compression` - Compression type (`:gzip` or `nil`, default: `nil`)
    - `:batch_size` - Number of spans to batch (default: 512)
    - `:batch_timeout` - Batch timeout in milliseconds (default: 5000)
    - `:batch_max_queue_size` - Maximum queue size (default: 2048)

  ## Example

      # Configure the exporter (typically done during application startup)
      ObservLib.Exporters.OtlpTraceExporter.setup()

      # Export spans (handled automatically by OpenTelemetry batch processor)
      span = ObservLib.Traces.start_span("my_operation")
      ObservLib.Traces.end_span(span)
  """

  require Logger

  @default_endpoint "http://localhost:4318"
  @default_protocol :http_protobuf
  @default_batch_size 512
  @default_batch_timeout 5000
  @default_max_queue_size 2048

  @doc """
  Sets up the OTLP trace exporter with configuration from ObservLib.Config.

  This function applies configuration to the :opentelemetry and
  :opentelemetry_exporter applications. It should be called during application
  startup before any spans are created.

  ## Returns

    - `:ok` if setup succeeds
    - `{:error, reason}` if configuration is invalid

  ## Examples

      iex> ObservLib.Exporters.OtlpTraceExporter.setup()
      :ok
  """
  @spec setup() :: :ok | {:error, term()}
  def setup do
    case get_configuration() do
      {:ok, config} ->
        apply_configuration(config)

      {:error, reason} ->
        safe_reason = ObservLib.HTTP.redact_sensitive_headers(reason)
        Logger.warning("OTLP trace exporter not configured: #{inspect(safe_reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets the current exporter configuration.

  Returns a map with the exporter configuration including endpoint,
  protocol, compression, and batch settings.

  ## Returns

    - `{:ok, config}` if configuration is valid
    - `{:error, reason}` if configuration is invalid or missing

  ## Examples

      iex> ObservLib.Exporters.OtlpTraceExporter.get_configuration()
      {:ok, %{
        endpoint: "http://localhost:4318",
        protocol: :http_protobuf,
        compression: nil,
        batch_size: 512,
        batch_timeout: 5000
      }}
  """
  @spec get_configuration() :: {:ok, map()} | {:error, term()}
  def get_configuration do
    try do
      endpoint = get_endpoint()
      protocol = get_protocol()
      compression = get_compression()
      batch_size = get_batch_size()
      batch_timeout = get_batch_timeout()
      max_queue_size = get_max_queue_size()

      config = %{
        endpoint: endpoint,
        protocol: protocol,
        compression: compression,
        batch_size: batch_size,
        batch_timeout: batch_timeout,
        max_queue_size: max_queue_size
      }

      {:ok, config}
    rescue
      e ->
        {:error, e}
    end
  end

  @doc """
  Forces a flush of any pending spans in the batch processor.

  Useful for ensuring spans are exported before application shutdown.

  ## Returns

    - `:ok` if flush succeeds
    - `{:error, reason}` if flush fails

  ## Examples

      iex> ObservLib.Exporters.OtlpTraceExporter.force_flush()
      :ok
  """
  @spec force_flush() :: :ok | {:error, term()}
  def force_flush do
    try do
      :otel_batch_processor.force_flush()
      :ok
    catch
      kind, reason ->
        safe_reason = ObservLib.HTTP.redact_sensitive_headers({kind, reason})
        Logger.error("Failed to force flush spans: #{inspect(safe_reason)}")
        {:error, {kind, reason}}
    end
  end

  # Private functions

  defp apply_configuration(config) do
    # Configure the opentelemetry_exporter application
    configure_exporter_app(config)

    # Configure the opentelemetry application for batch processing
    configure_opentelemetry_app(config)

    Logger.info("OTLP trace exporter configured successfully")
    :ok
  rescue
    e ->
      safe_error = ObservLib.HTTP.redact_sensitive_headers(e)
      Logger.error("Error configuring OTLP trace exporter: #{inspect(safe_error)}")
      {:error, e}
  end

  defp configure_exporter_app(config) do
    # Set protocol
    Application.put_env(:opentelemetry_exporter, :otlp_protocol, config.protocol)

    # Set endpoint (prefer specific traces endpoint)
    if config.endpoint do
      Application.put_env(:opentelemetry_exporter, :otlp_traces_endpoint, config.endpoint)
    end

    # Set compression if configured
    if config.compression do
      Application.put_env(:opentelemetry_exporter, :otlp_traces_compression, config.compression)
    end
  end

  defp configure_opentelemetry_app(config) do
    # Configure batch span processor settings
    Application.put_env(:opentelemetry, :span_processor, :batch)
    Application.put_env(:opentelemetry, :traces_exporter, :otlp)

    # Set batch processor options
    Application.put_env(:opentelemetry, :bsp_scheduled_delay_ms, config.batch_timeout)
    Application.put_env(:opentelemetry, :bsp_max_queue_size, config.max_queue_size)
    Application.put_env(:opentelemetry, :bsp_exporting_timeout_ms, config.batch_timeout * 2)
  end

  defp get_endpoint do
    # Check for specific traces endpoint first (includes fallback to otlp_endpoint in Config)
    case Application.get_env(:observlib, :otlp_traces_endpoint) || Application.get_env(:observlib, :otlp_endpoint) do
      nil ->
        @default_endpoint

      traces_endpoint when is_binary(traces_endpoint) ->
        # Only append /v1/traces if this came from the general otlp_endpoint
        # (specific traces endpoint is used as-is)
        if String.ends_with?(traces_endpoint, "/v1/traces") or has_custom_path?(traces_endpoint) do
          traces_endpoint
        else
          append_traces_path(traces_endpoint)
        end
    end
  end

  defp has_custom_path?(endpoint) when is_binary(endpoint) do
    uri = URI.parse(endpoint)

    case uri.path do
      nil -> false
      "" -> false
      "/" -> false
      _ -> true
    end
  end

  defp append_traces_path(endpoint) when is_binary(endpoint) do
    uri = URI.parse(endpoint)

    # Only append /v1/traces if path is empty or root
    path =
      case uri.path do
        nil -> "/v1/traces"
        "" -> "/v1/traces"
        "/" -> "/v1/traces"
        existing_path -> existing_path
      end

    %{uri | path: path}
    |> URI.to_string()
  end

  defp get_protocol do
    Application.get_env(:observlib, :otlp_protocol, @default_protocol)
  end

  defp get_compression do
    Application.get_env(:observlib, :otlp_compression)
  end

  defp get_batch_size do
    Application.get_env(:observlib, :batch_size, @default_batch_size)
  end

  defp get_batch_timeout do
    Application.get_env(:observlib, :batch_timeout, @default_batch_timeout)
  end

  defp get_max_queue_size do
    Application.get_env(:observlib, :otlp_max_queue_size, @default_max_queue_size)
  end
end
