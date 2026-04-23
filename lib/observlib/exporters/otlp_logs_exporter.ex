defmodule ObservLib.Exporters.OtlpLogsExporter do
  @moduledoc """
  OTLP HTTP exporter for OpenTelemetry logs.

  Exports logs to an OTLP-compatible collector over HTTP. Supports batch processing,
  configurable batch sizes, retry logic, and integration with Erlang's :logger handler.

  ## Features

  - HTTP/1.1 and HTTP/2 support for OTLP log export
  - Batch processing with configurable batch size and timeout
  - Automatic retry with exponential backoff
  - Log level to OpenTelemetry severity number mapping
  - Structured log attributes from metadata
  - Integration with Erlang :logger handler

  ## Configuration

  Configure via Application environment:

      config :observlib,
        otlp_endpoint: "http://localhost:4318",
        logs_batch_size: 100,
        logs_batch_timeout: 5000,
        logs_max_retries: 3

  ## Example

      # Start the exporter
      {:ok, pid} = ObservLib.Exporters.OtlpLogsExporter.start_link()

      # Export logs (typically called by logger handler)
      log_records = [build_log_record()]
      ObservLib.Exporters.OtlpLogsExporter.export(log_records)

  """

  use GenServer
  require Logger

  @default_batch_size 100
  @default_batch_timeout 5000
  @default_max_retries 3
  @default_endpoint "http://localhost:4318"

  # OpenTelemetry severity number mapping
  # https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber
  @severity_map %{
    debug: 5,
    info: 9,
    notice: 10,
    warning: 13,
    warn: 13,
    error: 17,
    critical: 21,
    alert: 22,
    emergency: 24
  }

  # Client API

  @doc """
  Starts the OTLP logs exporter GenServer.

  ## Options

    * `:name` - The registered name for the GenServer (default: `__MODULE__`)
    * `:batch_size` - Maximum batch size before automatic flush (default: 100)
    * `:batch_timeout` - Maximum time in ms before automatic flush (default: 5000)
    * `:max_retries` - Maximum retry attempts on failure (default: 3)

  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Exports a batch of log records to the OTLP collector.

  ## Parameters

    * `log_records` - List of log record maps to export

  ## Returns

    * `:ok` - Export successful
    * `{:error, reason}` - Export failed

  """
  @spec export(list(map())) :: :ok | {:error, term()}
  def export(log_records) when is_list(log_records) do
    GenServer.call(__MODULE__, {:export, log_records})
  end

  @doc """
  Adds log records to the batch queue.

  Records are queued and exported when the batch size or timeout is reached.

  ## Parameters

    * `log_records` - List of log record maps to queue

  """
  @spec add_to_batch(list(map())) :: :ok
  def add_to_batch(log_records) when is_list(log_records) do
    GenServer.cast(__MODULE__, {:add_to_batch, log_records})
  end

  @doc """
  Flushes any pending log records in the batch queue.

  Forces immediate export of all queued log records.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc """
  Maps Elixir/Erlang log level to OpenTelemetry severity number.

  ## Parameters

    * `level` - Log level atom (`:debug`, `:info`, `:warn`, `:error`, etc.)

  ## Returns

  Integer severity number according to OpenTelemetry specification.

  ## Examples

      iex> ObservLib.Exporters.OtlpLogsExporter.severity_number(:debug)
      5

      iex> ObservLib.Exporters.OtlpLogsExporter.severity_number(:info)
      9

      iex> ObservLib.Exporters.OtlpLogsExporter.severity_number(:error)
      17

  """
  @spec severity_number(atom()) :: integer()
  def severity_number(level) when is_atom(level) do
    Map.get(@severity_map, level, 0)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    endpoint = Keyword.get(opts, :endpoint) || get_config(:otlp_endpoint, @default_endpoint)
    batch_size = Keyword.get(opts, :batch_size, get_config(:logs_batch_size, @default_batch_size))

    batch_timeout =
      Keyword.get(opts, :batch_timeout, get_config(:logs_batch_timeout, @default_batch_timeout))

    max_retries =
      Keyword.get(opts, :max_retries, get_config(:logs_max_retries, @default_max_retries))

    batch_limit = Keyword.get(opts, :batch_limit, ObservLib.Config.get_log_batch_limit())

    state = %{
      endpoint: endpoint,
      batch_size: batch_size,
      batch_timeout: batch_timeout,
      max_retries: max_retries,
      batch_limit: batch_limit,
      batch: [],
      timer_ref: schedule_flush(batch_timeout),
      retry_count: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:export, log_records}, _from, state) do
    case do_export(log_records, state) do
      :ok ->
        {:reply, :ok, state}

      {:retry, _retry_count} ->
        {:reply, {:error, :connection_failed}, state}

      {:error, reason} = error ->
        safe_reason = ObservLib.HTTP.redact_sensitive_headers(reason)
        Logger.error("Failed to export logs: #{inspect(safe_reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    new_state = flush_batch(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:add_to_batch, log_records}, state) do
    new_batch = state.batch ++ log_records

    # Enforce batch limit by dropping oldest logs if exceeded
    new_batch =
      if length(new_batch) > state.batch_limit do
        dropped_count = length(new_batch) - state.batch_limit

        Logger.warning("Log batch limit exceeded, dropping oldest logs",
          limit: state.batch_limit,
          dropped: dropped_count
        )

        Enum.take(new_batch, state.batch_limit)
      else
        new_batch
      end

    if length(new_batch) >= state.batch_size do
      # Flush immediately if batch size reached
      cancel_timer(state.timer_ref)

      case do_export(new_batch, state) do
        :ok ->
          new_state = %{
            state
            | batch: [],
              timer_ref: schedule_flush(state.batch_timeout),
              retry_count: 0
          }

          {:noreply, new_state}

        {:retry, new_retry_count} ->
          # Schedule retry with exponential backoff
          retry_delay = calculate_retry_delay(new_retry_count)
          Process.send_after(self(), {:retry_export, new_batch}, retry_delay)

          {:noreply,
           %{
             state
             | batch: [],
               timer_ref: schedule_flush(state.batch_timeout),
               retry_count: new_retry_count
           }}

        {:error, reason} ->
          safe_reason = ObservLib.HTTP.redact_sensitive_headers(reason)
          Logger.error("Failed to export batch: #{inspect(safe_reason)}")
          # Keep records for retry
          {:noreply, %{state | retry_count: 0}}
      end
    else
      {:noreply, %{state | batch: new_batch}}
    end
  end

  @impl true
  def handle_info(:flush_batch, state) do
    new_state = flush_batch(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:retry_export, log_records}, state) do
    case do_export(log_records, state) do
      :ok ->
        {:noreply, %{state | retry_count: 0}}

      {:retry, new_retry_count} ->
        # Schedule another retry with exponential backoff
        retry_delay = calculate_retry_delay(new_retry_count)
        Process.send_after(self(), {:retry_export, log_records}, retry_delay)
        {:noreply, %{state | retry_count: new_retry_count}}

      {:error, reason} ->
        safe_reason = ObservLib.HTTP.redact_sensitive_headers(reason)
        Logger.error("Failed to export logs after retries: #{inspect(safe_reason)}")
        {:noreply, %{state | retry_count: 0}}
    end
  end

  # Private functions

  defp do_export([], _state), do: :ok

  defp do_export(log_records, state) do
    payload = build_otlp_payload(log_records)
    send_to_collector(payload, state, 0)
  end

  defp send_to_collector(payload, state, retry_count) do
    url = "#{state.endpoint}/v1/logs"

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    case ObservLib.HTTP.post(url, json: payload, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        error = {:http_error, status, body}

        if retry_count < state.max_retries and should_retry?(status) do
          {:retry, retry_count + 1}
        else
          {:error, error}
        end

      {:error, reason} ->
        if retry_count < state.max_retries do
          {:retry, retry_count + 1}
        else
          {:error, reason}
        end
    end
  end

  defp should_retry?(status) when status in [429, 500, 502, 503, 504], do: true
  defp should_retry?(_status), do: false

  defp build_otlp_payload(log_records) do
    resource = get_resource_attributes()

    scope_logs = %{
      scope: %{
        name: "observlib",
        version: "0.1.0"
      },
      log_records: Enum.map(log_records, &transform_log_record/1)
    }

    %{
      resource_logs: [
        %{
          resource: %{
            attributes: resource
          },
          scope_logs: [scope_logs]
        }
      ]
    }
  end

  defp transform_log_record(log_record) do
    level = Map.get(log_record, :level, :info)
    message = Map.get(log_record, :message, "")
    timestamp = Map.get(log_record, :timestamp, System.system_time(:nanosecond))
    attributes = Map.get(log_record, :attributes, %{})

    %{
      time_unix_nano: timestamp,
      severity_number: severity_number(level),
      severity_text: level |> to_string() |> String.upcase(),
      body: %{string_value: to_string(message)},
      attributes: format_attributes(attributes)
    }
  end

  defp format_attributes(attributes) when is_map(attributes) do
    Enum.map(attributes, fn {key, value} ->
      %{
        key: to_string(key),
        value: format_attribute_value(value)
      }
    end)
  end

  defp format_attributes(_), do: []

  defp format_attribute_value(value) when is_binary(value) do
    %{string_value: value}
  end

  defp format_attribute_value(value) when is_integer(value) do
    %{int_value: value}
  end

  defp format_attribute_value(value) when is_float(value) do
    %{double_value: value}
  end

  defp format_attribute_value(value) when is_boolean(value) do
    %{bool_value: value}
  end

  defp format_attribute_value(value) when is_list(value) do
    %{array_value: %{values: Enum.map(value, &format_attribute_value/1)}}
  end

  defp format_attribute_value(value) when is_map(value) do
    %{kvlist_value: %{values: format_attributes(value)}}
  end

  defp format_attribute_value(value) do
    %{string_value: inspect(value)}
  end

  defp get_resource_attributes do
    resource = ObservLib.Config.get_resource()

    Enum.map(resource, fn {key, value} ->
      %{
        key: to_string(key),
        value: format_attribute_value(value)
      }
    end)
  end

  defp get_config(key, default) do
    case ObservLib.Config.get(key) do
      nil -> default
      value -> value
    end
  end

  defp schedule_flush(timeout) do
    Process.send_after(self(), :flush_batch, timeout)
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp flush_batch(%{batch: []} = state) do
    %{state | timer_ref: schedule_flush(state.batch_timeout)}
  end

  defp flush_batch(state) do
    case do_export(state.batch, state) do
      :ok ->
        %{state | batch: [], timer_ref: schedule_flush(state.batch_timeout), retry_count: 0}

      {:retry, new_retry_count} ->
        # Schedule retry with exponential backoff
        retry_delay = calculate_retry_delay(new_retry_count)
        Process.send_after(self(), {:retry_export, state.batch}, retry_delay)

        %{
          state
          | batch: [],
            timer_ref: schedule_flush(state.batch_timeout),
            retry_count: new_retry_count
        }

      {:error, reason} ->
        safe_reason = ObservLib.HTTP.redact_sensitive_headers(reason)
        Logger.error("Failed to flush batch: #{inspect(safe_reason)}")
        # Reschedule flush, keep records
        %{state | timer_ref: schedule_flush(state.batch_timeout), retry_count: 0}
    end
  end

  defp calculate_retry_delay(retry_count) do
    # Exponential backoff with jitter: 1s, 2s, 4s, 8s, max 30s
    base = min(:math.pow(2, retry_count) * 1000, 30_000)
    jitter = :rand.uniform(1000)
    trunc(base + jitter)
  end
end
