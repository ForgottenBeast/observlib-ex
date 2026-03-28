defmodule ObservLib.Traces.Provider do
  @moduledoc """
  GenServer managing span lifecycle with ETS-backed active span tracking.

  This provider wraps OpenTelemetry span operations while maintaining an ETS
  table of active spans for observability and debugging purposes.

  ## ETS Table

  The provider owns an ETS table `:observlib_active_spans` that tracks:
    * Span ID (key)
    * Span name
    * Start time
    * Attributes
    * Parent span ID (if any)
    * Process PID that created the span

  ## Cleanup

  Stale spans (spans that exceed the configured timeout without being ended)
  are automatically cleaned up on a configurable interval.
  """

  use GenServer
  require Logger

  @ets_table :observlib_active_spans
  @default_cleanup_interval :timer.minutes(1)
  @default_stale_span_timeout :timer.minutes(5)

  # Public API

  @doc """
  Starts the Traces Provider GenServer.

  ## Options

    * `:cleanup_interval` - Interval in ms for stale span cleanup (default: 60000)
    * `:stale_span_timeout` - Time in ms after which a span is considered stale (default: 300000)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a new span with the given name and attributes.

  Creates an OpenTelemetry span and tracks it in the ETS table.

  ## Parameters

    * `name` - The span name (string or atom)
    * `attributes` - A map of span attributes (default: %{})

  ## Returns

  The span context.

  ## Examples

      iex> span = ObservLib.Traces.Provider.start_span("my_operation", %{"user.id" => "123"})
      iex> ObservLib.Traces.Provider.end_span(span)

  """
  @spec start_span(String.t() | atom(), map()) :: term()
  def start_span(name, attributes \\ %{}) do
    tracer = :opentelemetry.get_tracer(:observlib)
    opts = %{attributes: attributes}
    span_ctx = :otel_tracer.start_span(tracer, name, opts)

    # Track in ETS (fire-and-forget via cast for performance)
    GenServer.cast(__MODULE__, {:track_span, span_ctx, name, attributes})

    span_ctx
  end

  @doc """
  Ends the given span.

  Ends the OpenTelemetry span and removes it from ETS tracking.

  ## Parameters

    * `span_ctx` - The span context to end

  ## Returns

  The updated span context.

  """
  @spec end_span(term()) :: term()
  def end_span(span_ctx) do
    result = :otel_span.end_span(span_ctx)

    # Remove from ETS tracking
    GenServer.cast(__MODULE__, {:untrack_span, span_ctx})

    result
  end

  @doc """
  Returns all currently active spans from ETS.

  ## Returns

  A list of maps containing span information.

  ## Examples

      iex> ObservLib.Traces.Provider.get_active_spans()
      [%{span_id: "abc123", name: "my_operation", ...}]

  """
  @spec get_active_spans() :: [map()]
  def get_active_spans do
    GenServer.call(__MODULE__, :get_active_spans)
  end

  @doc """
  Gets a specific span by its span ID.

  ## Parameters

    * `span_id` - The span ID to look up

  ## Returns

    * `{:ok, span_info}` if found
    * `{:error, :not_found}` if not found

  """
  @spec get_span(term()) :: {:ok, map()} | {:error, :not_found}
  def get_span(span_id) do
    GenServer.call(__MODULE__, {:get_span, span_id})
  end

  @doc """
  Returns the count of active spans.
  """
  @spec active_span_count() :: non_neg_integer()
  def active_span_count do
    GenServer.call(__MODULE__, :active_span_count)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    # Create ETS table owned by this process
    table = :ets.new(@ets_table, [:set, :protected, :named_table, read_concurrency: true])

    cleanup_interval = Keyword.get(opts, :cleanup_interval, @default_cleanup_interval)
    stale_timeout = Keyword.get(opts, :stale_span_timeout, @default_stale_span_timeout)

    # Schedule first cleanup
    schedule_cleanup(cleanup_interval)

    state = %{
      table: table,
      cleanup_interval: cleanup_interval,
      stale_span_timeout: stale_timeout
    }

    Logger.debug("Traces.Provider started with ETS table #{inspect(table)}")
    {:ok, state}
  end

  @impl true
  def handle_cast({:track_span, span_ctx, name, attributes}, state) do
    # Check span limit before inserting (SEC-013: M-04)
    max_spans = ObservLib.Config.get(:max_active_spans, 10_000)
    current_count = :ets.info(@ets_table, :size)

    if current_count >= max_spans do
      Logger.warning("Max active spans limit reached, rejecting new span",
        limit: max_spans,
        current: current_count,
        span_name: name
      )

      {:noreply, state}
    else
      span_id = extract_span_id(span_ctx)
      parent_id = extract_parent_span_id(span_ctx)

      span_info = {
        span_id,
        %{
          span_id: span_id,
          name: name,
          attributes: attributes,
          parent_span_id: parent_id,
          start_time: System.monotonic_time(:millisecond),
          pid: self()
        }
      }

      :ets.insert(@ets_table, span_info)
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:untrack_span, span_ctx}, state) do
    span_id = extract_span_id(span_ctx)
    :ets.delete(@ets_table, span_id)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_active_spans, _from, state) do
    spans =
      :ets.tab2list(@ets_table)
      |> Enum.map(fn {_id, info} -> info end)

    {:reply, spans, state}
  end

  @impl true
  def handle_call({:get_span, span_id}, _from, state) do
    result =
      case :ets.lookup(@ets_table, span_id) do
        [{^span_id, info}] -> {:ok, info}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:active_span_count, _from, state) do
    count = :ets.info(@ets_table, :size)
    {:reply, count, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_stale_spans(state.stale_span_timeout)
    schedule_cleanup(state.cleanup_interval)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    # Clean up ETS table on termination
    if :ets.whereis(@ets_table) != :undefined do
      Logger.debug("Traces.Provider terminating, cleaning up ETS table")
      :ets.delete(@ets_table)
    end

    :ok
  end

  # Private functions

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  defp cleanup_stale_spans(timeout) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - timeout

    # Find and delete stale spans
    stale_spans =
      :ets.select(@ets_table, [
        {{:"$1", %{start_time: :"$2"}}, [{:<, :"$2", cutoff}], [:"$1"]}
      ])

    if length(stale_spans) > 0 do
      Logger.warning("Cleaning up #{length(stale_spans)} stale spans")

      Enum.each(stale_spans, fn span_id ->
        :ets.delete(@ets_table, span_id)
      end)
    end
  end

  defp extract_span_id(span_ctx) when is_tuple(span_ctx) do
    # OpenTelemetry span context is a record/tuple
    # The span_id is typically at position 2 (after the record tag and trace_id)
    case span_ctx do
      {_, trace_id, span_id, _, _, _, _, _} ->
        {trace_id, span_id}

      _ ->
        # Fallback: use the whole context as key
        :erlang.phash2(span_ctx)
    end
  end

  defp extract_span_id(_), do: nil

  defp extract_parent_span_id(span_ctx) when is_tuple(span_ctx) do
    # Try to extract parent span from OTel context
    case :otel_tracer.current_span_ctx() do
      ^span_ctx -> nil
      parent when is_tuple(parent) -> extract_span_id(parent)
      _ -> nil
    end
  end

  defp extract_parent_span_id(_), do: nil
end
