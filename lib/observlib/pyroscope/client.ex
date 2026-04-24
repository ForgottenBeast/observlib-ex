defmodule ObservLib.Pyroscope.Client do
  @moduledoc """
  GenServer that periodically sends profiling data to Pyroscope.

  This client performs periodic stack sampling of Erlang/Elixir processes
  and uploads the profiling data to a Pyroscope server for continuous profiling
  and visualization.

  ## Features

    - Periodic stack sampling at configurable rate
    - HTTP upload to Pyroscope ingest endpoint
    - Span correlation via labels (uses trace_id/span_id when available)
    - Graceful degradation when Pyroscope is unreachable
    - Configurable process filtering

  ## Configuration

  Configure via Application environment:

      config :observlib,
        pyroscope_endpoint: "http://localhost:4040",
        pyroscope_sample_rate: 5000,  # Sample every 5 seconds
        pyroscope_labels: %{
          "env" => "production"
        }

  ## Usage

  The client is automatically started by ObservLib.Supervisor when
  `pyroscope_endpoint` is configured. It can also be started manually:

      {:ok, pid} = ObservLib.Pyroscope.Client.start_link()

  """

  use GenServer
  require Logger

  @default_sample_rate 5000
  @default_labels %{}

  # Client API

  @doc """
  Starts the Pyroscope client GenServer.

  ## Options

    - `:name` - Registered name for the GenServer (default: `__MODULE__`)
    - `:endpoint` - Pyroscope server URL (reads from config if not provided)
    - `:sample_rate` - Sampling interval in milliseconds (default: 5000)
    - `:labels` - Additional labels to attach to profiles

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Adds labels to the profiling data.

  Labels are merged with existing labels. These labels will be attached
  to all subsequent profile uploads.

  ## Examples

      ObservLib.Pyroscope.Client.add_labels(%{"user_id" => "123"})

  """
  @spec add_labels(map()) :: :ok
  def add_labels(labels) when is_map(labels) do
    GenServer.call(__MODULE__, {:add_labels, labels})
  end

  @doc """
  Removes labels from the profiling data.

  ## Examples

      ObservLib.Pyroscope.Client.remove_labels(["user_id"])

  """
  @spec remove_labels(list(String.t())) :: :ok
  def remove_labels(label_keys) when is_list(label_keys) do
    GenServer.call(__MODULE__, {:remove_labels, label_keys})
  end

  @doc """
  Gets the current status of the Pyroscope client.

  ## Returns

  A map containing:
    - `:enabled` - Whether the client is actively profiling
    - `:endpoint` - The configured Pyroscope endpoint
    - `:sample_rate` - The sampling interval in milliseconds
    - `:labels` - Current labels attached to profiles
    - `:last_upload` - Timestamp of last successful upload (or nil)
    - `:upload_count` - Number of successful uploads
    - `:error_count` - Number of failed uploads

  """
  @spec get_status() :: map()
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc """
  Forces an immediate profile collection and upload.

  Useful for testing or when you want to capture a specific moment.
  """
  @spec force_flush() :: :ok | {:error, term()}
  def force_flush do
    GenServer.call(__MODULE__, :force_flush)
  end

  @doc """
  Returns a child specification for this GenServer.

  Only includes the client in the supervision tree if `pyroscope_endpoint`
  is configured.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    endpoint = Keyword.get_lazy(opts, :endpoint, fn -> get_pyroscope_endpoint() end)
    sample_rate = Keyword.get(opts, :sample_rate, get_sample_rate())
    configured_labels = Keyword.get(opts, :labels, get_configured_labels())

    # Get service name for profile identification
    service_name = get_service_name()

    state = %{
      endpoint: endpoint,
      sample_rate: sample_rate,
      labels: Map.merge(@default_labels, configured_labels),
      service_name: service_name,
      enabled: endpoint != nil,
      last_upload: nil,
      upload_count: 0,
      error_count: 0,
      timer_ref: nil
    }

    if state.enabled do
      Logger.info("Pyroscope client starting with endpoint: #{endpoint}")
      # Schedule first profile collection
      timer_ref = schedule_collection(sample_rate)
      {:ok, %{state | timer_ref: timer_ref}}
    else
      Logger.info("Pyroscope client started in disabled mode (no endpoint configured)")
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:add_labels, new_labels}, _from, state) do
    updated_labels = Map.merge(state.labels, new_labels)
    {:reply, :ok, %{state | labels: updated_labels}}
  end

  @impl true
  def handle_call({:remove_labels, label_keys}, _from, state) do
    updated_labels = Map.drop(state.labels, label_keys)
    {:reply, :ok, %{state | labels: updated_labels}}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      enabled: state.enabled,
      endpoint: state.endpoint,
      sample_rate: state.sample_rate,
      labels: state.labels,
      last_upload: state.last_upload,
      upload_count: state.upload_count,
      error_count: state.error_count
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:force_flush, _from, state) do
    if state.enabled do
      case collect_and_upload(state) do
        {:ok, new_state} ->
          {:reply, :ok, new_state}

        {:error, reason, new_state} ->
          {:reply, {:error, reason}, new_state}
      end
    else
      {:reply, {:error, :disabled}, state}
    end
  end

  @impl true
  def handle_info(:collect_profile, state) do
    new_state =
      if state.enabled do
        case collect_and_upload(state) do
          {:ok, updated_state} -> updated_state
          {:error, _reason, updated_state} -> updated_state
        end
      else
        state
      end

    # Schedule next collection
    timer_ref = schedule_collection(new_state.sample_rate)
    {:noreply, %{new_state | timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Cancel any pending timer
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
    end

    :ok
  end

  # Private functions

  defp get_pyroscope_endpoint do
    try do
      ObservLib.Config.get_pyroscope_endpoint()
    rescue
      _ -> nil
    end
  end

  defp get_sample_rate do
    try do
      case ObservLib.Config.get(:pyroscope_sample_rate) do
        nil -> @default_sample_rate
        rate when is_integer(rate) -> rate
        _ -> @default_sample_rate
      end
    rescue
      _ -> @default_sample_rate
    end
  end

  defp get_configured_labels do
    try do
      case ObservLib.Config.get(:pyroscope_labels) do
        nil -> %{}
        labels when is_map(labels) -> labels
        _ -> %{}
      end
    rescue
      _ -> %{}
    end
  end

  defp get_service_name do
    try do
      ObservLib.Config.get_service_name()
    rescue
      _ -> "unknown"
    end
  end

  defp schedule_collection(sample_rate) do
    Process.send_after(self(), :collect_profile, sample_rate)
  end

  defp collect_and_upload(state) do
    # Collect stack samples from all processes
    profile_data = collect_stack_samples()

    # Add trace context if available
    labels_with_trace = add_trace_context(state.labels)

    # Upload to Pyroscope
    case upload_profile(profile_data, labels_with_trace, state) do
      :ok ->
        new_state = %{
          state
          | last_upload: System.system_time(:second),
            upload_count: state.upload_count + 1
        }

        {:ok, new_state}

      {:error, reason} ->
        safe_reason = ObservLib.HTTP.redact_sensitive_headers(reason)
        Logger.warning("Pyroscope upload failed: #{inspect(safe_reason)}")
        new_state = %{state | error_count: state.error_count + 1}
        {:error, reason, new_state}
    end
  end

  defp collect_stack_samples do
    # Get all processes
    processes = Process.list()

    # Collect stack traces
    samples =
      processes
      |> Enum.map(fn pid ->
        try do
          case Process.info(pid, [:current_stacktrace, :registered_name]) do
            [{:current_stacktrace, stacktrace}, {:registered_name, name}] ->
              {pid, name, stacktrace}

            _ ->
              nil
          end
        catch
          _, _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Format as collapsed stack format (Brendan Gregg's format)
    format_collapsed_stacks(samples)
  end

  defp format_collapsed_stacks(samples) do
    samples
    |> Enum.map_join("\n", fn {_pid, name, stacktrace} ->
      process_name = format_process_name(name)

      stack_string =
        stacktrace
        |> Enum.reverse()
        |> Enum.map_join(";", &format_stack_frame/1)

      if stack_string != "" do
        "#{process_name};#{stack_string} 1"
      else
        "#{process_name} 1"
      end
    end)
  end

  defp format_process_name(nil), do: "anonymous"
  defp format_process_name([]), do: "anonymous"
  defp format_process_name(name) when is_atom(name), do: Atom.to_string(name)
  defp format_process_name(name), do: inspect(name)

  defp format_stack_frame({module, function, arity, _location}) do
    "#{module}.#{function}/#{arity}"
  end

  defp format_stack_frame({module, function, arity}) do
    "#{module}.#{function}/#{arity}"
  end

  defp format_stack_frame(other) do
    inspect(other)
  end

  defp add_trace_context(labels) do
    try do
      span_ctx = :otel_tracer.current_span_ctx()

      case span_ctx do
        :undefined ->
          labels

        span when is_tuple(span) and tuple_size(span) >= 3 ->
          trace_id = elem(span, 1)
          span_id = elem(span, 2)

          labels
          |> maybe_add_label("trace_id", format_id(trace_id, 32))
          |> maybe_add_label("span_id", format_id(span_id, 16))

        _ ->
          labels
      end
    rescue
      _ -> labels
    catch
      _, _ -> labels
    end
  end

  defp maybe_add_label(labels, _key, nil), do: labels
  defp maybe_add_label(labels, key, value), do: Map.put(labels, key, value)

  defp format_id(id, pad_length) when is_integer(id) and id != 0 do
    id
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(pad_length, "0")
  end

  defp format_id(_, _), do: nil

  defp upload_profile(profile_data, labels, state) do
    url = build_ingest_url(state.endpoint, state.service_name, labels)

    headers = [
      {"content-type", "application/octet-stream"}
    ]

    try do
      case ObservLib.HTTP.post(url, profile_data, headers) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, {:exception, e}}
    end
  end

  defp build_ingest_url(endpoint, service_name, labels) do
    # Build labels string for URL
    labels_with_service = Map.put(labels, "__name__", "#{service_name}.cpu")

    labels_string =
      labels_with_service
      |> Enum.map_join(",", fn {k, v} -> "#{k}=#{v}" end)

    "#{endpoint}/ingest?name=#{URI.encode(labels_string)}&spyName=elixir&sampleRate=#{@default_sample_rate}"
  end
end
