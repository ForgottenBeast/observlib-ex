defmodule ObservLib.Metrics.Supervisor do
  @moduledoc """
  Supervisor for the Metrics subsystem.

  Manages the metrics collection and export pipeline:
  - MeterProvider: ETS-backed metric storage and aggregation
  - PrometheusReader: HTTP endpoint for Prometheus scraping (optional)
  - OtlpMetricsExporter: OTLP export for metrics

  Uses `:rest_for_one` strategy so that if MeterProvider crashes,
  dependent processes (PrometheusReader, OtlpMetricsExporter) are restarted.
  """

  use Supervisor

  @doc """
  Starts the Metrics supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Build children list, conditionally including PrometheusReader
    children = build_children()

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp build_children do
    base_children = [
      {ObservLib.Metrics.MeterProvider, []}
    ]

    # Add PrometheusReader if prometheus_port is configured
    prometheus_children =
      case Application.get_env(:observlib, :prometheus_port) do
        nil -> []
        _port -> [{ObservLib.Metrics.PrometheusReader, []}]
      end

    # Add OtlpMetricsExporter if OTLP endpoint is configured
    exporter_children =
      case Application.get_env(:observlib, :otlp_endpoint) do
        nil -> []
        _endpoint -> [{ObservLib.Exporters.OtlpMetricsExporter, []}]
      end

    base_children ++ prometheus_children ++ exporter_children
  end

  @doc """
  Returns the child specification for this supervisor.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5000
    }
  end
end
