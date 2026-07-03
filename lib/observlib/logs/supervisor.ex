defmodule ObservLib.Logs.Supervisor do
  @moduledoc """
  Supervisor for the logging subsystem.

  Manages the lifecycle of log-related processes including the Logger backend
  and the OTLP logs exporter.

  ## Children

    - `ObservLib.Exporters.OtlpLogsExporter` - OTLP HTTP exporter for logs
    - `ObservLib.Logs.Backend` - Logger backend for capturing log events

  Both children start only when an OTLP logs endpoint is configured
  (`:otlp_logs_endpoint`, falling back to `:otlp_endpoint`). With no endpoint
  the subsystem is a no-op: nothing is exported, no handler is registered, and
  log output flows through the default console handler (stdout) untouched.
  This mirrors `ObservLib.Metrics.Supervisor`'s conditional exporter.

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
    Supervisor.init(children(), strategy: :one_for_one)
  end

  @doc """
  Computes the child list from application config.

  Returns `[]` (no-op mode) when neither `:otlp_logs_endpoint` nor
  `:otlp_endpoint` is configured — without an endpoint the exporter would
  batch and POST every log line at a dead default address, and the backend
  would capture events nobody consumes. Logs still reach stdout via the
  default console handler, which this subsystem never removes.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children do
    endpoint =
      Application.get_env(:observlib, :otlp_logs_endpoint) ||
        Application.get_env(:observlib, :otlp_endpoint)

    case endpoint do
      nil ->
        []

      _configured ->
        [
          # OTLP Logs Exporter - handles batching and HTTP export
          {ObservLib.Exporters.OtlpLogsExporter, []},
          # Logger backend - captures Logger events and forwards to exporter
          {ObservLib.Logs.Backend, []}
        ]
    end
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
