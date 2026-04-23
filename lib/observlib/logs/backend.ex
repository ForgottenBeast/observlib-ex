defmodule ObservLib.Logs.Backend do
  @moduledoc """
  Logger backend for capturing Elixir Logger output and forwarding to OTLP export.

  This module implements a GenServer that registers itself as an Erlang :logger handler,
  captures log events, enriches them with trace context when available, and forwards
  them to the OtlpLogsExporter for batch processing and export.

  ## Features

    - Captures all Logger events at configurable log level
    - Extracts trace context (trace_id, span_id) from OpenTelemetry when available
    - Forwards structured log records to OtlpLogsExporter
    - Runtime reconfiguration support

  ## Configuration

  Configure via Application environment:

      config :observlib,
        logs_level: :info  # Minimum log level to capture (default: :debug)

  ## Usage

  The backend is automatically started and registered when ObservLib.Logs.Supervisor starts.
  """

  use GenServer
  require Logger

  @default_level :debug

  # Client API

  @doc """
  Starts the Logger backend GenServer.

  ## Options

    - `:level` - Minimum log level to capture (default: `:debug`)
    - `:name` - Registered name for the GenServer (default: `__MODULE__`)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Configures the backend at runtime.

  ## Options

    - `:level` - Minimum log level to capture

  ## Examples

      ObservLib.Logs.Backend.configure(level: :info)

  """
  @spec configure(keyword()) :: :ok
  def configure(opts) do
    GenServer.call(__MODULE__, {:configure, opts})
  end

  @doc """
  Gets the current configuration.

  ## Returns

  A keyword list containing the current configuration.
  """
  @spec get_config() :: keyword()
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  @doc """
  Processes a log event and forwards it to the exporter.

  This is called internally when log events are received, but can also be
  called directly for testing purposes.

  ## Parameters

    - `level` - The log level atom
    - `message` - The log message (iodata)
    - `timestamp` - The log timestamp
    - `metadata` - The log metadata keyword list

  """
  @spec handle_log_event(atom(), iodata(), term(), keyword()) :: :ok
  def handle_log_event(level, message, timestamp, metadata) do
    GenServer.cast(__MODULE__, {:log_event, level, message, timestamp, metadata})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    level = Keyword.get(opts, :level, get_configured_level())

    state = %{
      level: level
    }

    # Register as Logger backend after init
    Process.send_after(self(), :register_backend, 0)

    {:ok, state}
  end

  @impl true
  def handle_call({:configure, opts}, _from, state) do
    new_level = Keyword.get(opts, :level, state.level)
    new_state = %{state | level: new_level}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    {:reply, [level: state.level], state}
  end

  @impl true
  def handle_cast({:log_event, level, message, timestamp, metadata}, state) do
    if should_log?(level, state.level) do
      log_record = build_log_record(level, message, timestamp, metadata)
      forward_to_exporter(log_record)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:register_backend, state) do
    # Add ourselves as a Logger handler using Erlang's :logger
    handler_config = %{
      level: :all,
      filter_default: :log,
      filters: [],
      formatter: {:logger_formatter, %{}},
      config: %{backend_pid: self()}
    }

    handler_id = :observlib_logs_backend

    case :logger.add_handler(handler_id, __MODULE__.Handler, handler_config) do
      :ok ->
        Logger.debug("ObservLib.Logs.Backend registered as logger handler")

      {:error, {:already_exist, _}} ->
        Logger.debug("ObservLib.Logs.Backend handler already registered")

      {:error, reason} ->
        Logger.warning("Failed to register ObservLib.Logs.Backend: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    # Remove the logger handler on termination
    :logger.remove_handler(:observlib_logs_backend)
    :ok
  end

  # Private functions

  defp get_configured_level do
    case ObservLib.Config.get(:logs_level) do
      nil -> @default_level
      level when is_atom(level) -> level
      _ -> @default_level
    end
  rescue
    # Config may not be started yet during tests
    _ -> @default_level
  end

  defp should_log?(event_level, min_level) do
    Logger.compare_levels(event_level, min_level) != :lt
  end

  defp build_log_record(level, message, timestamp, metadata) do
    # Convert timestamp to nanoseconds
    timestamp_nanos = timestamp_to_nanos(timestamp)

    # Extract trace context from OpenTelemetry if available
    trace_context = extract_trace_context()

    # Build attributes from metadata and trace context
    attributes =
      metadata
      |> Keyword.delete(:gl)
      |> Keyword.delete(:pid)
      |> Map.new()
      |> Map.merge(trace_context)

    %{
      level: level,
      message: IO.iodata_to_binary(message),
      timestamp: timestamp_nanos,
      attributes: attributes
    }
  end

  defp timestamp_to_nanos({{year, month, day}, {hour, min, sec, microsec}}) do
    # Convert Erlang timestamp to Unix nanoseconds
    datetime = %DateTime{
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: min,
      second: sec,
      microsecond: {microsec, 6},
      zone_abbr: "UTC",
      utc_offset: 0,
      std_offset: 0,
      time_zone: "Etc/UTC"
    }

    DateTime.to_unix(datetime, :nanosecond)
  end

  defp timestamp_to_nanos(_) do
    # Fallback to current time
    System.system_time(:nanosecond)
  end

  defp extract_trace_context do
    # Try to get current span context from OpenTelemetry
    try do
      span_ctx = :otel_tracer.current_span_ctx()

      case span_ctx do
        :undefined ->
          %{}

        span when is_tuple(span) ->
          # Extract trace_id and span_id from the span context tuple
          # OpenTelemetry span context is a record/tuple
          trace_id = extract_trace_id(span)
          span_id = extract_span_id(span)

          context = %{}

          context =
            if trace_id && trace_id != 0 do
              Map.put(context, :trace_id, format_trace_id(trace_id))
            else
              context
            end

          context =
            if span_id && span_id != 0 do
              Map.put(context, :span_id, format_span_id(span_id))
            else
              context
            end

          context

        _ ->
          %{}
      end
    rescue
      _ -> %{}
    catch
      _, _ -> %{}
    end
  end

  # Extract trace_id from span context tuple
  # The span context is typically: {:span_ctx, TraceId, SpanId, TraceFlags, Tracestate, IsValid, IsRemote, IsRecording}
  defp extract_trace_id(span_ctx) when is_tuple(span_ctx) do
    case tuple_size(span_ctx) do
      size when size >= 2 -> elem(span_ctx, 1)
      _ -> nil
    end
  end

  defp extract_trace_id(_), do: nil

  # Extract span_id from span context tuple
  defp extract_span_id(span_ctx) when is_tuple(span_ctx) do
    case tuple_size(span_ctx) do
      size when size >= 3 -> elem(span_ctx, 2)
      _ -> nil
    end
  end

  defp extract_span_id(_), do: nil

  # Format trace_id as hex string (128-bit / 32 hex chars)
  defp format_trace_id(trace_id) when is_integer(trace_id) do
    trace_id
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(32, "0")
  end

  defp format_trace_id(_), do: nil

  # Format span_id as hex string (64-bit / 16 hex chars)
  defp format_span_id(span_id) when is_integer(span_id) do
    span_id
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(16, "0")
  end

  defp format_span_id(_), do: nil

  defp forward_to_exporter(log_record) do
    try do
      ObservLib.Exporters.OtlpLogsExporter.add_to_batch([log_record])
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end

defmodule ObservLib.Logs.Backend.Handler do
  @moduledoc false
  # Erlang :logger handler module for ObservLib.Logs.Backend

  def log(%{level: level, msg: msg, meta: meta}, _config) do
    # Convert message to string
    message =
      case msg do
        {:string, str} -> str
        {:report, report} -> inspect(report)
        {format, args} when is_list(args) -> :io_lib.format(format, args) |> IO.iodata_to_binary()
        other -> inspect(other)
      end

    # Convert timestamp
    timestamp =
      case Map.get(meta, :time) do
        nil ->
          System.system_time(:nanosecond)

        time_microseconds ->
          # Erlang logger time is in microseconds since epoch
          time_microseconds * 1000
      end

    # Build metadata from meta map
    metadata =
      meta
      |> Map.drop([:time, :gl, :pid, :mfa, :file, :line, :domain, :report_cb])
      |> Map.to_list()

    # Build log record
    trace_context = extract_trace_context()

    attributes =
      metadata
      |> Map.new()
      |> Map.merge(trace_context)

    log_record = %{
      level: level,
      message: message,
      timestamp: timestamp,
      attributes: attributes
    }

    # Forward to exporter
    try do
      ObservLib.Exporters.OtlpLogsExporter.add_to_batch([log_record])
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  def adding_handler(config) do
    # OTP 28+ requires :level key in returned config
    level = Map.get(config, :level, :all)
    {:ok, %{level: level}}
  end

  def removing_handler(_config) do
    :ok
  end

  def changing_config(_action, _old_config, new_config) do
    {:ok, new_config}
  end

  defp extract_trace_context do
    try do
      span_ctx = :otel_tracer.current_span_ctx()

      case span_ctx do
        :undefined ->
          %{}

        span when is_tuple(span) and tuple_size(span) >= 3 ->
          trace_id = elem(span, 1)
          span_id = elem(span, 2)

          context = %{}

          context =
            if trace_id && trace_id != 0 do
              Map.put(context, :trace_id, format_id(trace_id, 32))
            else
              context
            end

          if span_id && span_id != 0 do
            Map.put(context, :span_id, format_id(span_id, 16))
          else
            context
          end

        _ ->
          %{}
      end
    rescue
      _ -> %{}
    catch
      _, _ -> %{}
    end
  end

  defp format_id(id, pad_length) when is_integer(id) do
    id
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(pad_length, "0")
  end

  defp format_id(_, _), do: nil
end
