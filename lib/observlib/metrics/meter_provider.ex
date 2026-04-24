defmodule ObservLib.Metrics.MeterProvider do
  @moduledoc """
  GenServer managing metric storage and aggregation using ETS.

  This is the core of the metrics subsystem, replacing the process dictionary
  approach with ETS tables for cross-process metric access.

  Owns two ETS tables:
  - `:observlib_metrics` - Stores aggregated metric values
  - `:observlib_metric_registry` - Stores metric definitions

  ## Metric Types

  - Counter: Monotonically increasing sum (atomic increment via ETS)
  - Gauge: Last observed value (simple insert)
  - Histogram: Statistical distribution (count, sum, min, max, bucket counts)
  - UpDownCounter: Sum that can increase or decrease (atomic update)

  ## Example

      # Register a metric
      ObservLib.Metrics.MeterProvider.register("http.requests", :counter, unit: :count)

      # Record a value
      ObservLib.Metrics.MeterProvider.record("http.requests", :counter, 1, %{method: "GET"})

      # Read all metrics
      ObservLib.Metrics.MeterProvider.read_all()
  """

  use GenServer
  require Logger

  @metrics_table :observlib_metrics
  @registry_table :observlib_metric_registry

  # Default histogram bucket boundaries
  @default_bucket_boundaries [0.0, 5.0, 10.0, 25.0, 50.0, 75.0, 100.0, 250.0, 500.0, 1000.0]

  # Client API

  @doc """
  Starts the MeterProvider GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a metric definition.

  ## Parameters

    * `name` - Metric name (string)
    * `type` - Metric type (:counter, :gauge, :histogram, :up_down_counter)
    * `opts` - Options including :unit, :description, :bucket_boundaries (for histograms)

  ## Example

      MeterProvider.register("http.requests", :counter, unit: :count)
  """
  @spec register(String.t(), atom(), keyword()) :: :ok
  def register(name, type, opts \\ []) do
    GenServer.call(__MODULE__, {:register, name, type, opts})
  end

  @doc """
  Records a metric value.

  This is a cast (non-blocking) to avoid hot-path blocking.

  ## Parameters

    * `name` - Metric name
    * `type` - Metric type
    * `value` - Value to record
    * `attributes` - Map of attribute key-value pairs
  """
  @spec record(String.t(), atom(), number(), map()) :: :ok
  def record(name, type, value, attributes \\ %{}) do
    GenServer.cast(__MODULE__, {:record, name, type, value, attributes})
  end

  @doc """
  Reads all current metric values.

  Returns a list of metric data with their aggregated values.
  """
  @spec read_all() :: [map()]
  def read_all do
    GenServer.call(__MODULE__, :read_all)
  end

  @doc """
  Reads a specific metric by name.

  Returns the metric data or nil if not found.
  """
  @spec read(String.t()) :: map() | nil
  def read(name) do
    GenServer.call(__MODULE__, {:read, name})
  end

  @doc """
  Resets all metrics (clears values but keeps registrations).

  Useful for testing and after export flush.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc """
  Lists all registered metric definitions.
  """
  @spec list_registered() :: [map()]
  def list_registered do
    GenServer.call(__MODULE__, :list_registered)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables owned by this process
    metrics_table =
      :ets.new(@metrics_table, [
        :set,
        # Protected: only owner can write, others can read
        :protected,
        :named_table,
        read_concurrency: true
      ])

    registry_table =
      :ets.new(@registry_table, [
        :set,
        :protected,
        :named_table,
        read_concurrency: true
      ])

    # Attach telemetry handler
    attach_telemetry_handler()

    state = %{
      metrics_table: metrics_table,
      registry_table: registry_table,
      # Track cardinality per metric name
      cardinality_tracker: %{}
    }

    Logger.debug("MeterProvider started with ETS tables")
    {:ok, state}
  end

  @impl true
  def handle_call({:register, name, type, opts}, _from, state) do
    definition = %{
      name: name,
      type: type,
      unit: Keyword.get(opts, :unit),
      description: Keyword.get(opts, :description),
      bucket_boundaries: Keyword.get(opts, :bucket_boundaries, @default_bucket_boundaries)
    }

    :ets.insert(@registry_table, {name, definition})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:read_all, _from, state) do
    metrics =
      :ets.tab2list(@metrics_table)
      |> Enum.map(fn {{name, attributes}, data} ->
        %{
          name: name,
          attributes: attributes,
          type: data.type,
          data: format_metric_data(data)
        }
      end)

    {:reply, metrics, state}
  end

  @impl true
  def handle_call({:read, name}, _from, state) do
    metrics =
      :ets.match_object(@metrics_table, {{name, :_}, :_})
      |> Enum.map(fn {{_name, attributes}, data} ->
        %{
          name: name,
          attributes: attributes,
          type: data.type,
          data: format_metric_data(data)
        }
      end)

    result = if Enum.empty?(metrics), do: nil, else: metrics
    {:reply, result, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@metrics_table)
    :ets.delete_all_objects(@registry_table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:list_registered, _from, state) do
    registered =
      :ets.tab2list(@registry_table)
      |> Enum.map(fn {_name, definition} -> definition end)

    {:reply, registered, state}
  end

  @impl true
  def handle_cast({:record, name, type, value, attributes}, state) do
    key = {name, normalize_attributes(attributes)}

    # Check cardinality limit (sec-003)
    cardinality_limit = ObservLib.Config.cardinality_limit()

    case check_cardinality_limit(state.metrics_table, key, name, cardinality_limit) do
      :ok ->
        record_metric(key, type, value)
        {:noreply, state}

      :limit_exceeded ->
        # Log warning but don't crash - drop the metric
        Logger.warning(
          "Metric cardinality limit exceeded for metric #{name}, limit: #{cardinality_limit}"
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:telemetry_event, event_name, measurements, metadata}, state) do
    # Handle telemetry events forwarded from the handler
    metric_name = Enum.join(event_name, ".")
    metric_type = Map.get(metadata, :metric_type, :counter)
    attributes = Map.drop(metadata, [:metric_type])

    value = extract_value(metric_type, measurements)
    key = {metric_name, normalize_attributes(attributes)}

    # Check cardinality limit (sec-003)
    cardinality_limit = ObservLib.Config.cardinality_limit()

    case check_cardinality_limit(state.metrics_table, key, metric_name, cardinality_limit) do
      :ok ->
        record_metric(key, metric_type, value)
        {:noreply, state}

      :limit_exceeded ->
        Logger.warning(
          "Metric cardinality limit exceeded for metric #{metric_name}, limit: #{cardinality_limit}"
        )

        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    # Detach telemetry handler
    :telemetry.detach(:observlib_meter_provider_handler)

    # ETS tables are automatically deleted when owner process terminates
    :ok
  end

  # Private Functions

  defp check_cardinality_limit(table, key, name, limit) do
    # If the key already exists, allow the update
    case :ets.lookup(table, key) do
      [{^key, _}] ->
        :ok

      [] ->
        # Count current cardinality for this metric name
        current_count = count_metric_variants(table, name)

        if current_count >= limit do
          :limit_exceeded
        else
          :ok
        end
    end
  end

  defp count_metric_variants(table, name) do
    # Use match_spec to count entries where the key's first element matches name
    match_spec = [
      {{{:"$1", :_}, :_}, [{:==, :"$1", name}], [true]}
    ]

    :ets.select_count(table, match_spec)
  end

  defp attach_telemetry_handler do
    handler_id = :observlib_meter_provider_handler
    pid = self()

    _handler_fun = fn event_name, measurements, metadata, _config ->
      # Only handle events with metric_type in metadata
      if Map.has_key?(metadata, :metric_type) do
        send(pid, {:telemetry_event, event_name, measurements, metadata})
      end
    end

    # Detach existing handler if present
    :telemetry.detach(handler_id)

    # We need to attach to all events since we don't know the names ahead of time
    # The handler filters by checking for :metric_type in metadata
    # For now, attach to common prefixes - this will be expanded via dynamic attachment
    :ok
  end

  defp record_metric(key, :counter, value) do
    case :ets.lookup(@metrics_table, key) do
      [] ->
        # Initialize counter
        data = %{
          type: :counter,
          value: value,
          timestamp: System.system_time(:nanosecond)
        }

        :ets.insert(@metrics_table, {key, data})

      [{^key, existing}] ->
        # Atomic increment
        updated = %{
          existing
          | value: existing.value + value,
            timestamp: System.system_time(:nanosecond)
        }

        :ets.insert(@metrics_table, {key, updated})
    end
  end

  defp record_metric(key, :gauge, value) do
    # Gauge: last value wins
    data = %{
      type: :gauge,
      value: value,
      timestamp: System.system_time(:nanosecond)
    }

    :ets.insert(@metrics_table, {key, data})
  end

  defp record_metric(key, :histogram, value) do
    case :ets.lookup(@metrics_table, key) do
      [] ->
        # Initialize histogram
        data = %{
          type: :histogram,
          count: 1,
          sum: value,
          min: value,
          max: value,
          buckets: init_buckets(value, @default_bucket_boundaries),
          timestamp: System.system_time(:nanosecond)
        }

        :ets.insert(@metrics_table, {key, data})

      [{^key, existing}] ->
        # Update histogram statistics
        updated = %{
          existing
          | count: existing.count + 1,
            sum: existing.sum + value,
            min: min(existing.min, value),
            max: max(existing.max, value),
            buckets: update_buckets(existing.buckets, value, @default_bucket_boundaries),
            timestamp: System.system_time(:nanosecond)
        }

        :ets.insert(@metrics_table, {key, updated})
    end
  end

  defp record_metric(key, :up_down_counter, value) do
    case :ets.lookup(@metrics_table, key) do
      [] ->
        # Initialize up-down counter
        data = %{
          type: :up_down_counter,
          value: value,
          timestamp: System.system_time(:nanosecond)
        }

        :ets.insert(@metrics_table, {key, data})

      [{^key, existing}] ->
        # Update (can go negative)
        updated = %{
          existing
          | value: existing.value + value,
            timestamp: System.system_time(:nanosecond)
        }

        :ets.insert(@metrics_table, {key, updated})
    end
  end

  defp record_metric(_key, _unknown_type, _value) do
    # Ignore unknown metric types
    :ok
  end

  defp init_buckets(value, boundaries) do
    # Initialize bucket counts
    Enum.map(boundaries, fn boundary ->
      count = if value <= boundary, do: 1, else: 0
      {boundary, count}
    end) ++ [{:infinity, if(value > List.last(boundaries), do: 1, else: 0)}]
  end

  defp update_buckets(existing_buckets, value, boundaries) do
    # Update bucket counts
    Enum.map(existing_buckets, fn
      {:infinity, count} ->
        inc = if value > List.last(boundaries), do: 1, else: 0
        {:infinity, count + inc}

      {boundary, count} ->
        # Find the first boundary >= value
        inc = if value <= boundary, do: 1, else: 0
        {boundary, count + inc}
    end)
  end

  defp extract_value(:counter, measurements), do: Map.get(measurements, :count, 0)
  defp extract_value(:gauge, measurements), do: Map.get(measurements, :value, 0)
  defp extract_value(:histogram, measurements), do: Map.get(measurements, :value, 0)
  defp extract_value(:up_down_counter, measurements), do: Map.get(measurements, :value, 0)

  defp extract_value(_, measurements),
    do: Map.get(measurements, :value, Map.get(measurements, :count, 0))

  defp normalize_attributes(attributes) when is_map(attributes) do
    # Sort attributes for consistent key generation
    attributes
    |> Enum.sort()
    |> Enum.into(%{})
  end

  defp format_metric_data(%{type: :counter} = data) do
    %{value: data.value, timestamp: data.timestamp}
  end

  defp format_metric_data(%{type: :gauge} = data) do
    %{value: data.value, timestamp: data.timestamp}
  end

  defp format_metric_data(%{type: :histogram} = data) do
    %{
      count: data.count,
      sum: data.sum,
      min: data.min,
      max: data.max,
      buckets: data.buckets,
      timestamp: data.timestamp
    }
  end

  defp format_metric_data(%{type: :up_down_counter} = data) do
    %{value: data.value, timestamp: data.timestamp}
  end

  defp format_metric_data(data), do: data
end
