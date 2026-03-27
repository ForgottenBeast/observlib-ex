defmodule ObservLib.Logs.Supervisor do
  @moduledoc """
  Supervisor for the logging subsystem.

  Manages the lifecycle of log-related processes including the Logger backend
  and the OTLP logs exporter.

  ## Children

    - `ObservLib.Logs.Backend` - Logger backend for capturing log events
    - `ObservLib.Exporters.OtlpLogsExporter` - OTLP HTTP exporter for logs

  ## Supervision Strategy

  Uses `:one_for_one` strategy - if a child process crashes, only that
  process is restarted.
  """

  use Supervisor

  @doc """
  Starts the Logs supervisor.

  ## Options

  All options are passed through to `Supervisor.start_link/3`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # OTLP Logs Exporter - handles batching and HTTP export
      {ObservLib.Exporters.OtlpLogsExporter, []},
      # Logger backend - captures Logger events and forwards to exporter
      {ObservLib.Logs.Backend, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns a child specification for this supervisor.

  This allows the Logs supervisor to be added as a child of another supervisor.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end
end
