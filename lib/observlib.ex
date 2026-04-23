defmodule ObservLib do
  @moduledoc """
  ObservLib - OpenTelemetry observability library for Elixir.

  Provides a unified interface for distributed tracing, metrics collection,
  and structured logging using OpenTelemetry with OTLP exporters.

  ## Example

      # Configure with defaults from application config
      ObservLib.configure()

      # Configure with custom options
      ObservLib.configure(
        service_name: "my_service",
        otlp_endpoint: "localhost:4318",
        resource_attributes: %{
          "service.version" => "1.0.0",
          "deployment.environment" => "production"
        }
      )

      # Get configuration values
      ObservLib.service_name()
      #=> "my_service"

      ObservLib.resource()
      #=> %{"service.name" => "my_service", "service.version" => "1.0.0", ...}

  """

  alias ObservLib.Config

  @doc """
  Configure ObservLib with default settings from application environment.

  Uses configuration from `config/config.exs`:

      config :observlib,
        service_name: "my_service",
        otlp_endpoint: nil,
        resource_attributes: %{}

  Returns `:ok` on success, or `{:error, reason}` on failure.
  """
  @spec configure() :: :ok | {:error, term()}
  def configure do
    # Configuration is already loaded from application env during Config GenServer init
    # This function validates that the Config GenServer is running
    case Process.whereis(ObservLib.Config) do
      nil -> {:error, :config_not_started}
      _pid -> :ok
    end
  end

  @doc """
  Configure ObservLib with custom options at runtime.

  ## Options

    * `:service_name` - Service name for telemetry (required, non-empty string)
    * `:otlp_endpoint` - OTLP endpoint (e.g., "localhost:4318")
    * `:pyroscope_endpoint` - Pyroscope endpoint for profiling
    * `:resource_attributes` - Map of additional resource attributes
    * `:log_level` - Log level (`:debug`, `:info`, `:warning`, `:error`)

  ## Examples

      ObservLib.configure(service_name: "api_server")

      ObservLib.configure(
        service_name: "worker",
        otlp_endpoint: "otel-collector:4318",
        resource_attributes: %{"env" => "prod"}
      )

  Returns `:ok` on success, or `{:error, reason}` for validation errors.
  """
  @spec configure(keyword()) :: :ok | {:error, term()}
  def configure(opts) when is_list(opts) do
    # Validate service_name if provided
    # Use Keyword.has_key? to distinguish between "not provided" and "explicitly nil"
    if Keyword.has_key?(opts, :service_name) do
      case Keyword.get(opts, :service_name) do
        name when is_binary(name) and byte_size(name) > 0 ->
          :ok

        _ ->
          {:error, :invalid_service_name}
      end
    else
      # service_name not provided - uses application config
      :ok
    end

    # TODO: In future phases, this will update Config GenServer state
    # and reconfigure telemetry components (traces, metrics, logs)
    # For now, we just validate the options
  end

  @doc """
  Get the current service name.

  Returns the configured service name as a string, or `nil` if not configured.

  ## Example

      ObservLib.service_name()
      #=> "my_service"

  """
  @spec service_name() :: String.t() | nil
  def service_name do
    Config.get_service_name()
  end

  @doc """
  Get the current resource attributes.

  Returns a map containing all resource attributes, including the base
  `"service.name"` attribute merged with any user-provided attributes.

  ## Example

      ObservLib.resource()
      #=> %{
      #=>   "service.name" => "my_service",
      #=>   "service.version" => "1.0.0",
      #=>   "deployment.environment" => "production"
      #=> }

  """
  @spec resource() :: map()
  def resource do
    Config.get_resource()
  end

  @doc """
  Get the current OTLP endpoint.

  Returns the OTLP endpoint string, or `nil` if not configured.

  ## Example

      ObservLib.otlp_endpoint()
      #=> "localhost:4318"

  """
  @spec otlp_endpoint() :: String.t() | nil
  def otlp_endpoint do
    Config.get_otlp_endpoint()
  end

  @doc """
  Get the current Pyroscope endpoint.

  Returns the Pyroscope endpoint string, or `nil` if not configured.

  ## Example

      ObservLib.pyroscope_endpoint()
      #=> "localhost:4040"

  """
  @spec pyroscope_endpoint() :: String.t() | nil
  def pyroscope_endpoint do
    Config.get_pyroscope_endpoint()
  end

  # Convenience API functions

  @doc """
  Execute a function within a traced span.

  Convenience wrapper around `ObservLib.Traces.with_span/3`. The span is
  automatically started before the function executes and ended after it
  completes (even if an exception is raised).

  ## Parameters

    * `name` - The span name (string or atom)
    * `attributes` - A map of span attributes (default: %{})
    * `func` - The function to execute within the span (must be arity 0)

  ## Returns

  The return value of the function.

  ## Examples

      ObservLib.traced("database_query", %{"db.system" => "postgresql"}, fn ->
        # Perform database query
        {:ok, results}
      end)

      ObservLib.traced("api_call", fn ->
        # Makes HTTP request
        HTTPoison.get("https://api.example.com")
      end)

  """
  @spec traced(String.t() | atom(), map(), (-> result)) :: result when result: any()
  def traced(name, attributes \\ %{}, func) when is_function(func, 0) do
    ObservLib.Traces.with_span(name, attributes, func)
  end

  @doc """
  Increment a counter metric.

  Convenience wrapper around `ObservLib.Metrics.counter/3`. Counters are
  monotonically increasing and used for counting events.

  ## Parameters

    * `name` - Metric name (string or atom)
    * `value` - Amount to increment (must be >= 0, default: 1)
    * `attributes` - Map of metric attributes/labels (default: %{})

  ## Examples

      ObservLib.counter("http.requests", 1, %{method: "GET", status: 200})
      ObservLib.counter("cache.hits")
      ObservLib.counter("api.calls", 5, %{endpoint: "/users"})

  """
  @spec counter(String.t() | atom(), number(), map()) :: :ok
  def counter(name, value \\ 1, attributes \\ %{}) when is_number(value) and value >= 0 do
    ObservLib.Metrics.counter(name, value, attributes)
  end

  @doc """
  Set a gauge metric value.

  Convenience wrapper around `ObservLib.Metrics.gauge/3`. Gauges represent
  a point-in-time value that can increase or decrease.

  ## Parameters

    * `name` - Metric name (string or atom)
    * `value` - Current value to set
    * `attributes` - Map of metric attributes/labels (default: %{})

  ## Examples

      ObservLib.gauge("memory.usage", 1024.5, %{type: "heap"})
      ObservLib.gauge("queue.depth", 42, %{queue: "default"})
      ObservLib.gauge("cpu.usage", 75.3)

  """
  @spec gauge(String.t() | atom(), number(), map()) :: :ok
  def gauge(name, value, attributes \\ %{}) when is_number(value) do
    ObservLib.Metrics.gauge(name, value, attributes)
  end

  @doc """
  Record a histogram observation.

  Convenience wrapper around `ObservLib.Metrics.histogram/3`. Histograms
  track the statistical distribution of values, typically for measurements
  like request durations or response sizes.

  ## Parameters

    * `name` - Metric name (string or atom)
    * `value` - Observed value to record
    * `attributes` - Map of metric attributes/labels (default: %{})

  ## Examples

      ObservLib.histogram("http.request.duration", 45.2, %{method: "GET"})
      ObservLib.histogram("response.size", 2048, %{endpoint: "/api/users"})
      ObservLib.histogram("db.query.time", 123.4)

  """
  @spec histogram(String.t() | atom(), number(), map()) :: :ok
  def histogram(name, value, attributes \\ %{}) when is_number(value) do
    ObservLib.Metrics.histogram(name, value, attributes)
  end

  @doc """
  Emit a structured log message.

  Convenience wrapper around `ObservLib.Logs.log/3`. Supports all standard
  log levels and structured attributes.

  ## Parameters

    * `level` - Log level (`:debug`, `:info`, `:warn`, or `:error`)
    * `message` - Log message string
    * `attributes` - Map or keyword list of structured attributes (default: %{})

  ## Examples

      ObservLib.log(:info, "User logged in", %{user_id: 123})
      ObservLib.log(:error, "Database connection failed", %{error: "timeout"})
      ObservLib.log(:debug, "Cache miss", key: "user:123")

  """
  @spec log(atom(), String.t(), map() | keyword()) :: :ok
  def log(level, message, attributes \\ %{}) when is_atom(level) and is_binary(message) do
    ObservLib.Logs.log(level, message, attributes)
  end
end
