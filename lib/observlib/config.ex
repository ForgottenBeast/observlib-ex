defmodule ObservLib.Config do
  @moduledoc """
  Configuration GenServer for ObservLib.

  Manages application configuration including service name, resource attributes,
  and endpoint URLs for OTLP and Pyroscope exporters.
  """

  use GenServer

  # Public API

  @doc """
  Starts the Config GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a configuration value by key with an optional default.
  """
  def get(key, default \\ nil) do
    GenServer.call(__MODULE__, {:get, key, default})
  end

  @doc """
  Gets the service name from the resource attributes.
  """
  def get_service_name do
    GenServer.call(__MODULE__, :get_service_name)
  end

  @doc """
  Gets the complete resource map including service.name and user-provided attributes.
  """
  def get_resource do
    GenServer.call(__MODULE__, :get_resource)
  end

  @doc """
  Gets the OTLP endpoint URL.
  """
  def get_otlp_endpoint do
    GenServer.call(__MODULE__, :get_otlp_endpoint)
  end

  @doc """
  Gets the Pyroscope endpoint URL.
  """
  def get_pyroscope_endpoint do
    GenServer.call(__MODULE__, :get_pyroscope_endpoint)
  end

  @doc """
  Gets the OTLP traces endpoint URL.
  Falls back to general otlp_endpoint if not specified.
  """
  def get_otlp_traces_endpoint do
    GenServer.call(__MODULE__, :get_otlp_traces_endpoint)
  end

  @doc """
  Gets the OTLP metrics endpoint URL.
  Falls back to general otlp_endpoint if not specified.
  """
  def get_otlp_metrics_endpoint do
    GenServer.call(__MODULE__, :get_otlp_metrics_endpoint)
  end

  @doc """
  Gets the OTLP logs endpoint URL.
  Falls back to general otlp_endpoint if not specified.
  """
  def get_otlp_logs_endpoint do
    GenServer.call(__MODULE__, :get_otlp_logs_endpoint)
  end

  @doc """
  Gets OTLP exporter headers.
  Returns empty map if not configured.
  """
  def get_otlp_headers do
    GenServer.call(__MODULE__, :get_otlp_headers)
  end

  @doc """
  Gets OTLP exporter timeout in milliseconds.
  Defaults to 10000 (10 seconds).
  """
  def get_otlp_timeout do
    GenServer.call(__MODULE__, :get_otlp_timeout)
  end

  @doc """
  Gets batch size for OTLP exporters.
  Defaults to 512.
  """
  def get_batch_size do
    GenServer.call(__MODULE__, :get_batch_size)
  end

  @doc """
  Gets batch timeout in milliseconds for OTLP exporters.
  Defaults to 5000 (5 seconds).
  """
  def get_batch_timeout do
    GenServer.call(__MODULE__, :get_batch_timeout)
  end

  @doc """
  Gets the cardinality limit per metric name to prevent unbounded ETS growth.
  Defaults to 2000.
  """
  def cardinality_limit do
    GenServer.call(__MODULE__, :get_cardinality_limit)
  end

  @doc """
  Gets the maximum log batch size limit.
  Defaults to 1000 logs.
  Prevents memory exhaustion when OTLP collector is unavailable.
  """
  def get_log_batch_limit do
    GenServer.call(__MODULE__, :get_log_batch_limit)
  end

  @doc """
  Gets the maximum number of concurrent Prometheus connections.
  Defaults to 10.
  """
  def get_prometheus_max_connections do
    GenServer.call(__MODULE__, :get_prometheus_max_connections)
  end

  @doc """
  Gets the Prometheus rate limit in requests per minute.
  Defaults to 100.
  """
  def get_prometheus_rate_limit do
    GenServer.call(__MODULE__, :get_prometheus_rate_limit)
  end

  @doc """
  Gets the Prometheus basic auth credentials.
  Returns nil if not configured, or {username, password} tuple.
  """
  def get_prometheus_basic_auth do
    GenServer.call(__MODULE__, :get_prometheus_basic_auth)
  end

  @doc """
  Gets the maximum attribute value size in bytes.
  Defaults to 4096 (4KB).
  """
  def get_max_attribute_value_size do
    GenServer.call(__MODULE__, :get_max_attribute_value_size)
  end

  @doc """
  Gets the maximum number of attributes per operation.
  Defaults to 128.
  """
  def get_max_attribute_count do
    GenServer.call(__MODULE__, :get_max_attribute_count)
  end

  @doc """
  Gets the list of attribute key patterns to redact.
  Returns nil to use default list, [] to disable, or custom list.
  """
  def get_redacted_attribute_keys do
    GenServer.call(__MODULE__, :get_redacted_attribute_keys)
  end

  @doc """
  Gets the redaction pattern to replace sensitive values with.
  Defaults to "[REDACTED]".
  """
  def get_redaction_pattern do
    GenServer.call(__MODULE__, :get_redaction_pattern)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Read from Application environment
    config = Application.get_all_env(:observlib)

    # Extract service name
    service_name = Keyword.get(config, :service_name)

    # Validate service name
    if is_nil(service_name) or service_name == "" do
      raise ArgumentError, "service_name must be a non-empty string"
    end

    # Build resource with service.name as base
    base_resource = %{"service.name" => service_name}
    user_resource = Keyword.get(config, :resource_attributes, %{})
    resource = Map.merge(base_resource, user_resource)

    # Get OTLP endpoints (with fallback to general otlp_endpoint) and validate
    otlp_endpoint = Keyword.get(config, :otlp_endpoint)
    validate_endpoint!(otlp_endpoint, "otlp_endpoint")

    otlp_traces_endpoint = Keyword.get(config, :otlp_traces_endpoint, otlp_endpoint)
    validate_endpoint!(otlp_traces_endpoint, "otlp_traces_endpoint")

    otlp_metrics_endpoint = Keyword.get(config, :otlp_metrics_endpoint, otlp_endpoint)
    validate_endpoint!(otlp_metrics_endpoint, "otlp_metrics_endpoint")

    otlp_logs_endpoint = Keyword.get(config, :otlp_logs_endpoint, otlp_endpoint)
    validate_endpoint!(otlp_logs_endpoint, "otlp_logs_endpoint")

    # Build state
    state = %{
      config: config,
      service_name: service_name,
      resource: resource,
      otlp_endpoint: otlp_endpoint,
      otlp_traces_endpoint: otlp_traces_endpoint,
      otlp_metrics_endpoint: otlp_metrics_endpoint,
      otlp_logs_endpoint: otlp_logs_endpoint,
      otlp_headers: Keyword.get(config, :otlp_headers, %{}),
      otlp_timeout: Keyword.get(config, :otlp_timeout, 10_000),
      batch_size: Keyword.get(config, :batch_size, 512),
      batch_timeout: Keyword.get(config, :batch_timeout, 5000),
      log_batch_limit: Keyword.get(config, :log_batch_limit, 1000),
      cardinality_limit: Keyword.get(config, :cardinality_limit, 2000),
      pyroscope_endpoint: Keyword.get(config, :pyroscope_endpoint),
      prometheus_max_connections: Keyword.get(config, :prometheus_max_connections, 10),
      prometheus_rate_limit: Keyword.get(config, :prometheus_rate_limit, 100),
      prometheus_basic_auth: Keyword.get(config, :prometheus_basic_auth, nil),
      max_attribute_value_size: Keyword.get(config, :max_attribute_value_size, 4096),
      max_attribute_count: Keyword.get(config, :max_attribute_count, 128),
      redacted_attribute_keys: Keyword.get(config, :redacted_attribute_keys, nil),
      redaction_pattern: Keyword.get(config, :redaction_pattern, "[REDACTED]")
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get, key, default}, _from, state) do
    value = Keyword.get(state.config, key, default)
    {:reply, value, state}
  end

  @impl true
  def handle_call(:get_service_name, _from, state) do
    {:reply, state.service_name, state}
  end

  @impl true
  def handle_call(:get_resource, _from, state) do
    {:reply, state.resource, state}
  end

  @impl true
  def handle_call(:get_otlp_endpoint, _from, state) do
    {:reply, state.otlp_endpoint, state}
  end

  @impl true
  def handle_call(:get_pyroscope_endpoint, _from, state) do
    {:reply, state.pyroscope_endpoint, state}
  end

  @impl true
  def handle_call(:get_otlp_traces_endpoint, _from, state) do
    {:reply, state.otlp_traces_endpoint, state}
  end

  @impl true
  def handle_call(:get_otlp_metrics_endpoint, _from, state) do
    {:reply, state.otlp_metrics_endpoint, state}
  end

  @impl true
  def handle_call(:get_otlp_logs_endpoint, _from, state) do
    {:reply, state.otlp_logs_endpoint, state}
  end

  @impl true
  def handle_call(:get_otlp_headers, _from, state) do
    {:reply, state.otlp_headers, state}
  end

  @impl true
  def handle_call(:get_otlp_timeout, _from, state) do
    {:reply, state.otlp_timeout, state}
  end

  @impl true
  def handle_call(:get_batch_size, _from, state) do
    {:reply, state.batch_size, state}
  end

  @impl true
  def handle_call(:get_batch_timeout, _from, state) do
    {:reply, state.batch_timeout, state}
  end

  @impl true
  def handle_call(:get_cardinality_limit, _from, state) do
    {:reply, state.cardinality_limit, state}
  end

  @impl true
  def handle_call(:get_log_batch_limit, _from, state) do
    {:reply, state.log_batch_limit, state}
  end

  @impl true
  def handle_call(:get_prometheus_max_connections, _from, state) do
    {:reply, state.prometheus_max_connections, state}
  end

  @impl true
  def handle_call(:get_prometheus_rate_limit, _from, state) do
    {:reply, state.prometheus_rate_limit, state}
  end

  @impl true
  def handle_call(:get_prometheus_basic_auth, _from, state) do
    {:reply, state.prometheus_basic_auth, state}
  end

  @impl true
  def handle_call(:get_max_attribute_value_size, _from, state) do
    {:reply, state.max_attribute_value_size, state}
  end

  @impl true
  def handle_call(:get_max_attribute_count, _from, state) do
    {:reply, state.max_attribute_count, state}
  end

  @impl true
  def handle_call(:get_redacted_attribute_keys, _from, state) do
    {:reply, state.redacted_attribute_keys, state}
  end

  @impl true
  def handle_call(:get_redaction_pattern, _from, state) do
    {:reply, state.redaction_pattern, state}
  end

  # Private helper for URL validation during config initialization
  defp validate_endpoint!(nil, _name), do: :ok
  defp validate_endpoint!("", _name), do: :ok

  defp validate_endpoint!(url, name) when is_binary(url) do
    case ObservLib.HTTP.validate_endpoint_url(url) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "Invalid #{name}: #{reason}. URL: #{inspect(url)}"
    end
  end
end
