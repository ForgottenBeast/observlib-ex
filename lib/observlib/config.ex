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

    # Get OTLP endpoints (with fallback to general otlp_endpoint)
    otlp_endpoint = Keyword.get(config, :otlp_endpoint)
    otlp_traces_endpoint = Keyword.get(config, :otlp_traces_endpoint, otlp_endpoint)
    otlp_metrics_endpoint = Keyword.get(config, :otlp_metrics_endpoint, otlp_endpoint)
    otlp_logs_endpoint = Keyword.get(config, :otlp_logs_endpoint, otlp_endpoint)

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
      otlp_timeout: Keyword.get(config, :otlp_timeout, 10000),
      batch_size: Keyword.get(config, :batch_size, 512),
      batch_timeout: Keyword.get(config, :batch_timeout, 5000),
      pyroscope_endpoint: Keyword.get(config, :pyroscope_endpoint)
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
end
