defmodule ObservLib.Traces.PyroscopeProcessor do
  @moduledoc """
  GenServer that attaches profiling data to spans for Pyroscope correlation.

  This processor links span IDs to profiling labels, enabling correlation between
  distributed traces and continuous profiling data in Pyroscope.

  ## Configuration

  The processor reads configuration from ObservLib.Config:

    * `:pyroscope_endpoint` - The Pyroscope server endpoint (required for processor to start)
    * `:pyroscope_sample_rate` - Sampling rate for profiling (default: 100)

  ## Usage

  When a span is started, attach profiling context:

      span_id = extract_span_id(span_ctx)
      ObservLib.Traces.PyroscopeProcessor.attach_profile(span_id, %{labels: labels})

  """

  use GenServer
  require Logger

  @ets_table :observlib_pyroscope_profiles

  # Public API

  @doc """
  Starts the Pyroscope Processor GenServer.

  Only starts if `pyroscope_endpoint` is configured.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attaches profiling data to a span.

  ## Parameters

    * `span_id` - The span ID to attach profiling data to
    * `profile_data` - Map containing profiling labels and metadata

  ## Returns

    * `:ok` on success

  ## Examples

      iex> ObservLib.Traces.PyroscopeProcessor.attach_profile(span_id, %{labels: %{"function" => "process"}})
      :ok

  """
  @spec attach_profile(term(), map()) :: :ok
  def attach_profile(span_id, profile_data) do
    GenServer.cast(__MODULE__, {:attach_profile, span_id, profile_data})
  end

  @doc """
  Gets the profiling data for a span.

  ## Parameters

    * `span_id` - The span ID to look up

  ## Returns

    * `{:ok, profile_data}` if found
    * `{:error, :not_found}` if not found

  """
  @spec get_profile(term()) :: {:ok, map()} | {:error, :not_found}
  def get_profile(span_id) do
    GenServer.call(__MODULE__, {:get_profile, span_id})
  end

  @doc """
  Removes profiling data for a span (called when span ends).

  ## Parameters

    * `span_id` - The span ID to remove

  """
  @spec remove_profile(term()) :: :ok
  def remove_profile(span_id) do
    GenServer.cast(__MODULE__, {:remove_profile, span_id})
  end

  @doc """
  Gets the current Pyroscope labels for the current trace context.

  Returns labels that can be passed to Pyroscope for correlation.
  """
  @spec get_current_labels() :: map()
  def get_current_labels do
    GenServer.call(__MODULE__, :get_current_labels)
  end

  @doc """
  Returns whether the processor is enabled (Pyroscope is configured).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    GenServer.call(__MODULE__, :enabled?)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    endpoint = get_pyroscope_endpoint()
    sample_rate = get_pyroscope_sample_rate()

    if is_nil(endpoint) do
      Logger.info("PyroscopeProcessor starting in disabled mode (no endpoint configured)")
    else
      Logger.debug("PyroscopeProcessor starting with endpoint: #{endpoint}")
    end

    # Create ETS table for profile data
    table = :ets.new(@ets_table, [:set, :protected, :named_table, read_concurrency: true])

    state = %{
      table: table,
      endpoint: endpoint,
      sample_rate: sample_rate,
      enabled: not is_nil(endpoint)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:attach_profile, span_id, profile_data}, state) do
    if state.enabled do
      # Add timestamp and trace context to profile data
      enriched_data =
        profile_data
        |> Map.put(:attached_at, System.monotonic_time(:millisecond))
        |> Map.put(:span_id, span_id)

      :ets.insert(@ets_table, {span_id, enriched_data})
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:remove_profile, span_id}, state) do
    :ets.delete(@ets_table, span_id)
    {:noreply, state}
  end

  @impl true
  def handle_call({:get_profile, span_id}, _from, state) do
    result =
      case :ets.lookup(@ets_table, span_id) do
        [{^span_id, data}] -> {:ok, data}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_current_labels, _from, state) do
    labels =
      if state.enabled do
        build_current_labels()
      else
        %{}
      end

    {:reply, labels, state}
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  @impl true
  def terminate(_reason, _state) do
    if :ets.whereis(@ets_table) != :undefined do
      :ets.delete(@ets_table)
    end

    :ok
  end

  # Private functions

  defp get_pyroscope_endpoint do
    try do
      ObservLib.Config.get_pyroscope_endpoint() ||
        Application.get_env(:observlib, :pyroscope_endpoint)
    catch
      :exit, _ ->
        Application.get_env(:observlib, :pyroscope_endpoint)
    end
  end

  defp get_pyroscope_sample_rate do
    try do
      ObservLib.Config.get(:pyroscope_sample_rate, 100)
    catch
      :exit, _ ->
        Application.get_env(:observlib, :pyroscope_sample_rate, 100)
    end
  end

  defp build_current_labels do
    # Get current span context from OTel
    case :otel_tracer.current_span_ctx() do
      nil ->
        %{}

      span_ctx when is_tuple(span_ctx) and tuple_size(span_ctx) == 8 ->
        try do
          # Extract trace_id and span_id for Pyroscope correlation
          {_, trace_id, span_id, _, _, _, _, _} = span_ctx

          %{
            "trace_id" => format_id(trace_id),
            "span_id" => format_id(span_id)
          }
        rescue
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp format_id(id) when is_integer(id) do
    Integer.to_string(id, 16)
  end

  defp format_id(id) when is_binary(id), do: id
  defp format_id(_), do: "unknown"
end
