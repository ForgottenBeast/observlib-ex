defmodule ObservLib.Application do
  @moduledoc """
  OTP Application for ObservLib.

  Starts the supervision tree with all required components for
  OpenTelemetry observability.
  """

  use Application
  require Logger

  alias ObservLib.Exporters.OtlpTraceExporter

  @impl true
  def start(_type, _args) do
    # Base children that always start
    base_children = [
      # Configuration GenServer (must start first)
      {ObservLib.Config, []},
      # Traces subsystem supervisor
      {ObservLib.Traces.Supervisor, []},
      # Metrics subsystem supervisor (includes MeterProvider, PrometheusReader, OtlpMetricsExporter)
      {ObservLib.Metrics.Supervisor, []},
      # Logs subsystem supervisor (includes OtlpLogsExporter and Logs.Backend)
      {ObservLib.Logs.Supervisor, []}
    ]

    # Conditionally add Pyroscope client if endpoint is configured
    children = maybe_add_pyroscope_client(base_children)

    opts = [strategy: :one_for_one, name: ObservLib.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      # Setup OTLP exporters after Config is started
      setup_exporters()
      {:ok, pid}
    end
  end

  defp maybe_add_pyroscope_client(children) do
    # Check if pyroscope_endpoint is configured in Application env
    # (Config GenServer hasn't started yet, so we read directly)
    case Application.get_env(:observlib, :pyroscope_endpoint) do
      nil ->
        children

      _endpoint ->
        children ++ [{ObservLib.Pyroscope.Client, []}]
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

        # Note: Metrics exporter is now started by Metrics.Supervisor
        # Note: Logs exporter is now started by Logs.Supervisor

        # Setup telemetry handlers
        case ObservLib.Telemetry.setup() do
          :ok ->
            Logger.debug("Telemetry handlers setup successful")

          {:error, reason} ->
            Logger.warning("Telemetry handlers setup failed: #{inspect(reason)}")
        end

        :ok
    end
  end
end
