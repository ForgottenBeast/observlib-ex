defmodule ObservLib.Application do
  @moduledoc """
  OTP Application for ObservLib.

  Starts the supervision tree with all required components for
  OpenTelemetry observability.
  """

  use Application
  require Logger

  alias ObservLib.Exporters.{OtlpTraceExporter, OtlpMetricsExporter, OtlpLogsExporter}

  @impl true
  def start(_type, _args) do
    children = [
      # Configuration GenServer
      {ObservLib.Config, []}
      # Additional components will be added in later phases:
      # {ObservLib.Traces.Supervisor, []},
      # {ObservLib.Metrics.Supervisor, []},
      # {ObservLib.Logs.Supervisor, []},
      # {ObservLib.Pyroscope.Client, []}
    ]

    opts = [strategy: :one_for_one, name: ObservLib.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # Setup OTLP exporters after Config is started
      setup_exporters()
      {:ok, pid}
    end
  end

  defp setup_exporters do
    # Only setup exporters if OTLP endpoint is configured
    case ObservLib.Config.get_otlp_endpoint() do
      nil ->
        Logger.info("OTLP endpoint not configured, skipping exporter setup")
        :ok

      _endpoint ->
        # Setup trace exporter (non-GenServer, just configuration)
        case OtlpTraceExporter.setup() do
          :ok ->
            Logger.debug("OTLP trace exporter setup successful")

          {:error, reason} ->
            Logger.warning("OTLP trace exporter setup failed: #{inspect(reason)}")
        end

        # Start metrics exporter GenServer
        case start_metrics_exporter() do
          {:ok, _pid} ->
            Logger.debug("OTLP metrics exporter started")

          {:error, reason} ->
            Logger.warning("OTLP metrics exporter failed to start: #{inspect(reason)}")
        end

        # Start logs exporter GenServer
        case start_logs_exporter() do
          {:ok, _pid} ->
            Logger.debug("OTLP logs exporter started")

          {:error, reason} ->
            Logger.warning("OTLP logs exporter failed to start: #{inspect(reason)}")
        end

        :ok
    end
  end

  defp start_metrics_exporter do
    # Start as a standalone process (not in supervision tree for now)
    # In Phase 5, these will be properly supervised
    OtlpMetricsExporter.start_link()
  end

  defp start_logs_exporter do
    # Start as a standalone process (not in supervision tree for now)
    # In Phase 5, these will be properly supervised
    OtlpLogsExporter.start_link()
  end
end
