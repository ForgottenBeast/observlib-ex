defmodule ObservLib.Metrics do
  @moduledoc """
  Metrics collection module for ObservLib.

  Provides a unified interface for recording metrics using :telemetry and :telemetry_metrics,
  with integration to :opentelemetry for OTLP export.

  Supports four metric types:
  - Counter: Monotonically increasing value
  - Gauge: Point-in-time value that can go up or down
  - Histogram: Statistical distribution of values
  - UpDownCounter: Counter that can increment or decrement

  ## Example

      # Register metrics
      ObservLib.Metrics.register_counter("http.requests", unit: :count)
      ObservLib.Metrics.register_histogram("http.request.duration", unit: :millisecond)

      # Record metric values
      ObservLib.Metrics.counter("http.requests", 1, %{method: "GET", status: 200})
      ObservLib.Metrics.histogram("http.request.duration", 45.2, %{method: "GET"})

  """

  @type metric_name :: String.t() | atom()
  @type metric_value :: number()
  @type attributes :: map()
  @type metric_opts :: keyword()

  @doc """
  Increment a counter metric by the given value.

  Counters are monotonically increasing and used for counting events.
  The value must be non-negative.

  ## Parameters

    * `name` - Metric name (string or atom)
    * `value` - Amount to increment (must be >= 0)
    * `attributes` - Map of metric attributes/labels

  ## Example

      ObservLib.Metrics.counter("http.requests", 1, %{method: "GET", status: 200})
      ObservLib.Metrics.counter(:api_calls, 1, %{endpoint: "/users"})

  """
  @spec counter(metric_name(), metric_value(), attributes()) :: :ok
  def counter(name, value, attributes \\ %{}) when is_number(value) and value >= 0 do
    event_name = normalize_event_name(name)
    measurements = %{count: value}
    metadata = Map.merge(attributes, %{metric_type: :counter})

    :telemetry.execute(event_name, measurements, metadata)
    :ok
  end

  @doc """
  Set a gauge metric to the given value.

  Gauges represent a point-in-time value that can increase or decrease.
  Use for things like memory usage, queue depth, or active connections.

  ## Parameters

    * `name` - Metric name (string or atom)
    * `value` - Current value to set
    * `attributes` - Map of metric attributes/labels

  ## Example

      ObservLib.Metrics.gauge("memory.usage", 1024.5, %{type: "heap"})
      ObservLib.Metrics.gauge(:queue_depth, 42, %{queue: "default"})

  """
  @spec gauge(metric_name(), metric_value(), attributes()) :: :ok
  def gauge(name, value, attributes \\ %{}) when is_number(value) do
    event_name = normalize_event_name(name)
    measurements = %{value: value}
    metadata = Map.merge(attributes, %{metric_type: :gauge})

    :telemetry.execute(event_name, measurements, metadata)
    :ok
  end

  @doc """
  Record a histogram observation.

  Histograms track the statistical distribution of values, typically for
  measurements like request durations or response sizes.

  ## Parameters

    * `name` - Metric name (string or atom)
    * `value` - Observed value to record
    * `attributes` - Map of metric attributes/labels

  ## Example

      ObservLib.Metrics.histogram("http.request.duration", 45.2, %{method: "GET"})
      ObservLib.Metrics.histogram(:db_query_time, 123.4, %{table: "users"})

  """
  @spec histogram(metric_name(), metric_value(), attributes()) :: :ok
  def histogram(name, value, attributes \\ %{}) when is_number(value) do
    event_name = normalize_event_name(name)
    measurements = %{value: value}
    metadata = Map.merge(attributes, %{metric_type: :histogram})

    :telemetry.execute(event_name, measurements, metadata)
    :ok
  end

  @doc """
  Increment or decrement an up-down counter.

  Up-down counters can both increase and decrease, unlike regular counters.
  Use for tracking values that go up and down like active sessions or inventory.

  ## Parameters

    * `name` - Metric name (string or atom)
    * `value` - Amount to change (positive to increment, negative to decrement)
    * `attributes` - Map of metric attributes/labels

  ## Example

      ObservLib.Metrics.up_down_counter("active.connections", 1, %{protocol: "http"})
      ObservLib.Metrics.up_down_counter("active.connections", -1, %{protocol: "http"})

  """
  @spec up_down_counter(metric_name(), metric_value(), attributes()) :: :ok
  def up_down_counter(name, value, attributes \\ %{}) when is_number(value) do
    event_name = normalize_event_name(name)
    measurements = %{value: value}
    metadata = Map.merge(attributes, %{metric_type: :up_down_counter})

    :telemetry.execute(event_name, measurements, metadata)
    :ok
  end

  @doc """
  Register a counter metric.

  Registration is optional but recommended for documenting available metrics
  and their configuration. Registered metrics are tracked in the process dictionary
  for the current process.

  ## Parameters

    * `name` - Metric name (string or atom)
    * `opts` - Keyword list of options:
      * `:unit` - Unit of measurement (e.g., :count, :byte, :millisecond)
      * `:description` - Human-readable description

  ## Example

      ObservLib.Metrics.register_counter("http.requests",
        unit: :count,
        description: "Total HTTP requests"
      )

  """
  @spec register_counter(metric_name(), metric_opts()) :: :ok
  def register_counter(name, opts \\ []) do
    register_metric(name, :counter, opts)
  end

  @doc """
  Register a gauge metric.

  Registration is optional but recommended for documenting available metrics
  and their configuration.

  ## Parameters

    * `name` - Metric name (string or atom)
    * `opts` - Keyword list of options:
      * `:unit` - Unit of measurement
      * `:description` - Human-readable description

  ## Example

      ObservLib.Metrics.register_gauge("memory.usage",
        unit: :byte,
        description: "Current memory usage"
      )

  """
  @spec register_gauge(metric_name(), metric_opts()) :: :ok
  def register_gauge(name, opts \\ []) do
    register_metric(name, :gauge, opts)
  end

  @doc """
  Register a histogram metric.

  Registration is optional but recommended for documenting available metrics
  and their configuration.

  ## Parameters

    * `name` - Metric name (string or atom)
    * `opts` - Keyword list of options:
      * `:unit` - Unit of measurement
      * `:description` - Human-readable description

  ## Example

      ObservLib.Metrics.register_histogram("http.request.duration",
        unit: :millisecond,
        description: "HTTP request duration"
      )

  """
  @spec register_histogram(metric_name(), metric_opts()) :: :ok
  def register_histogram(name, opts \\ []) do
    register_metric(name, :histogram, opts)
  end

  @doc """
  Get all registered metrics.

  Returns a list of registered metrics with their type and options.

  ## Example

      ObservLib.Metrics.list_registered_metrics()
      #=> [
      #=>   %{name: "http.requests", type: :counter, opts: [unit: :count]},
      #=>   %{name: "memory.usage", type: :gauge, opts: [unit: :byte]}
      #=> ]

  """
  @spec list_registered_metrics() :: [map()]
  def list_registered_metrics do
    case Process.get(:observlib_metrics_registry) do
      nil -> []
      registry when is_list(registry) -> registry
    end
  end

  # Private helpers

  defp register_metric(name, type, opts) do
    normalized_name = normalize_name(name)
    metric = %{name: normalized_name, type: type, opts: opts}

    registry = Process.get(:observlib_metrics_registry, [])
    updated_registry = [metric | Enum.reject(registry, &(&1.name == normalized_name))]
    Process.put(:observlib_metrics_registry, updated_registry)

    :ok
  end

  defp normalize_event_name(name) do
    name
    |> normalize_name()
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
  end

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name
end
