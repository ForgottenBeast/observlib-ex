defmodule ObservLib.Traces.Supervisor do
  @moduledoc """
  Supervisor for the tracing subsystem.

  Manages the Traces.Provider GenServer and optionally the PyroscopeProcessor
  when Pyroscope integration is enabled.

  ## Children

    * `ObservLib.Traces.Provider` - GenServer managing span lifecycle with ETS tracking
    * `ObservLib.Traces.PyroscopeProcessor` - (optional) Profiling correlation processor

  ## Strategy

  Uses `:one_for_one` strategy - each child is restarted independently on failure.
  """

  use Supervisor

  @doc """
  Starts the Traces supervisor.

  ## Options

    * `:name` - The supervisor name (default: `ObservLib.Traces.Supervisor`)

  ## Examples

      iex> ObservLib.Traces.Supervisor.start_link([])
      {:ok, pid}

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the child specification for this supervisor.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @impl true
  def init(_opts) do
    children = build_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp build_children do
    base_children = [
      {ObservLib.Traces.Provider, []}
    ]

    # Conditionally add PyroscopeProcessor if Pyroscope is configured
    case get_pyroscope_endpoint() do
      nil ->
        base_children

      _endpoint ->
        base_children ++ [{ObservLib.Traces.PyroscopeProcessor, []}]
    end
  end

  defp get_pyroscope_endpoint do
    # Try to get from Config GenServer if running, otherwise from Application env
    try do
      ObservLib.Config.get_pyroscope_endpoint()
    catch
      :exit, _ ->
        Application.get_env(:observlib, :pyroscope_endpoint)
    end
  end
end
