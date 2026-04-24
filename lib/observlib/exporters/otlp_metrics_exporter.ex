defmodule ObservLib.Exporters.OtlpMetricsExporter do
  @moduledoc """
  OTLP Metrics Exporter for ObservLib.

  Exports metrics to an OTLP collector using HTTP/protobuf. Supports periodic
  export scheduling, metric aggregation (sum, last_value, histogram), and
  error handling with retry logic.

  Integrates with :opentelemetry_exporter and :telemetry_metrics to provide
  a complete metrics export pipeline.

  ## Configuration

  Configure via the ObservLib.Config module:

      config :observlib,
        otlp_endpoint: "http://localhost:4318",
        metrics_export_interval: 60_000  # milliseconds

  ## Supported Metric Types

    - Counter: Monotonically increasing sum
    - Gauge: Last observed value
    - Histogram: Statistical distribution
    - UpDownCounter: Sum that can increase or decrease

  ## Example

      # Start the exporter
      {:ok, pid} = ObservLib.Exporters.OtlpMetricsExporter.start_link()

      # Metrics are automatically exported on schedule
      # Manual export can be triggered if needed
      ObservLib.Exporters.OtlpMetricsExporter.force_export()
  """

  use GenServer
  require Logger

  @default_export_interval 60_000
  @default_max_retries 3
  @default_retry_delay 1_000

  # Client API

  @doc """
  Starts the OTLP Metrics Exporter.

  ## Options

    - `:export_interval` - Export interval in milliseconds (default: 60000)
    - `:max_retries` - Maximum number of retry attempts (default: 3)
    - `:retry_delay` - Delay between retries in milliseconds (default: 1000)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Forces an immediate export of metrics.

  Returns `:ok` if export succeeds, `{:error, reason}` otherwise.
  """
  def force_export do
    GenServer.call(__MODULE__, :force_export, 10_000)
  end

  @doc """
  Gets the current exporter statistics.

  Returns a map with export counts, error counts, and last export time.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    endpoint =
      case Keyword.fetch(opts, :endpoint) do
        {:ok, ep} -> ep
        :error -> ObservLib.Config.get_otlp_endpoint()
      end

    if is_nil(endpoint) do
      Logger.warning("OTLP endpoint not configured, metrics exporter disabled")
      {:ok, %{enabled: false}}
    else
      export_interval = Keyword.get(opts, :export_interval, @default_export_interval)
      max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
      retry_delay = Keyword.get(opts, :retry_delay, @default_retry_delay)

      state = %{
        enabled: true,
        endpoint: endpoint,
        export_interval: export_interval,
        max_retries: max_retries,
        retry_delay: retry_delay,
        timer_ref: nil,
        # Note: metrics are now read from MeterProvider, not stored here
        # We keep this for backward compatibility with tests that send direct messages
        metrics: %{},
        export_count: 0,
        error_count: 0,
        last_export_time: nil,
        retry_count: 0
      }

      # Note: Telemetry handler removed - metrics now flow directly to MeterProvider
      # via ObservLib.Metrics API calls

      # Schedule first export
      timer_ref = Process.send_after(self(), :export, export_interval)
      state = %{state | timer_ref: timer_ref}

      Logger.info("OTLP Metrics Exporter started, endpoint: #{endpoint}")
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:force_export, _from, %{enabled: false} = state) do
    {:reply, {:error, :disabled}, state}
  end

  @impl true
  def handle_call(:force_export, _from, state) do
    result = do_export(state)
    # Normalize {:retry, _} to {:error, :retry} for stats tracking
    normalized_result =
      case result do
        {:retry, _} -> {:error, :retry}
        other -> other
      end

    new_state = update_export_stats(state, normalized_result)

    reply_result =
      case result do
        {:retry, _} -> {:error, :connection_failed}
        other -> other
      end

    {:reply, reply_result, new_state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    # Get metric count from both MeterProvider and internal state
    metric_count =
      try do
        provider_count = length(ObservLib.Metrics.MeterProvider.read_all())
        internal_count = map_size(Map.get(state, :metrics, %{}))
        provider_count + internal_count
      rescue
        _ -> map_size(Map.get(state, :metrics, %{}))
      catch
        :exit, _ -> map_size(Map.get(state, :metrics, %{}))
      end

    stats = %{
      enabled: state.enabled,
      export_count: Map.get(state, :export_count, 0),
      error_count: Map.get(state, :error_count, 0),
      last_export_time: Map.get(state, :last_export_time),
      metric_count: metric_count
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:export, %{enabled: false} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:export, state) do
    # Perform export
    result = do_export(state)

    new_state =
      case result do
        :ok ->
          update_export_stats(state, :ok)

        {:retry, new_retry_count} ->
          # Schedule retry with exponential backoff
          retry_delay = calculate_retry_delay(new_retry_count)
          Process.send_after(self(), :retry_export, retry_delay)
          updated = update_export_stats(state, {:error, :retry_scheduled})
          %{updated | retry_count: new_retry_count}

        {:error, _reason} = error ->
          update_export_stats(state, error)
      end

    # Schedule next export
    timer_ref = Process.send_after(self(), :export, state.export_interval)
    new_state = %{new_state | timer_ref: timer_ref}

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:retry_export, state) do
    # Retry export
    result = do_export(state)

    new_state =
      case result do
        :ok ->
          update_export_stats(%{state | retry_count: 0}, :ok)

        {:retry, new_retry_count} ->
          # Schedule another retry with exponential backoff
          retry_delay = calculate_retry_delay(new_retry_count)
          Process.send_after(self(), :retry_export, retry_delay)
          %{state | retry_count: new_retry_count}

        {:error, _reason} = error ->
          update_export_stats(%{state | retry_count: 0}, error)
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:telemetry_metric, event_name, measurements, metadata}, state) do
    # Aggregate metric data
    metric_key = build_metric_key(event_name, metadata)
    metric_type = Map.get(metadata, :metric_type, :counter)

    updated_metrics =
      Map.update(
        state.metrics,
        metric_key,
        build_initial_metric(metric_type, measurements, metadata),
        fn existing ->
          aggregate_metric(existing, metric_type, measurements, metadata)
        end
      )

    {:noreply, %{state | metrics: updated_metrics}}
  end

  @impl true
  def terminate(_reason, state) do
    # Cancel timer if running
    if state[:timer_ref] do
      Process.cancel_timer(state.timer_ref)
    end

    :ok
  end

  # Private Functions

  defp do_export(%{endpoint: endpoint} = state) do
    # Read metrics from MeterProvider (primary source)
    metrics_from_provider =
      try do
        ObservLib.Metrics.MeterProvider.read_all()
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    # Also check internal metrics for backward compatibility with tests
    internal_metrics = Map.get(state, :metrics, %{})

    if Enum.empty?(metrics_from_provider) and map_size(internal_metrics) == 0 do
      Logger.debug("No metrics to export")
      :ok
    else
      # Convert metrics from MeterProvider to OTLP format
      otlp_metrics_from_provider = build_otlp_metrics_from_provider(metrics_from_provider)

      # Convert internal metrics (for backward compat with tests)
      otlp_metrics_internal = build_otlp_metrics(internal_metrics)

      # Combine both sources
      otlp_metrics = otlp_metrics_from_provider ++ otlp_metrics_internal

      # Export with retry logic
      result = export_with_retry(endpoint, otlp_metrics, state.max_retries, state.retry_delay)

      # Reset MeterProvider metrics after successful export
      if result == :ok do
        try do
          ObservLib.Metrics.MeterProvider.reset()
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end

      result
    end
  end

  defp export_with_retry(endpoint, metrics, retries_left, _delay) do
    case do_http_export(endpoint, metrics) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Metrics export failed: #{inspect(reason)}, retries left: #{retries_left - 1}"
        )

        if retries_left > 1 do
          {:retry, retries_left - 1}
        else
          {:error, reason}
        end
    end
  end

  defp do_http_export(endpoint, metrics) do
    # Build OTLP metrics endpoint URL
    url = "#{endpoint}/v1/metrics"

    # Get resource attributes
    resource = ObservLib.Config.get_resource()

    # Build OTLP request body
    body = %{
      "resourceMetrics" => [
        %{
          "resource" => %{
            "attributes" => resource_to_attributes(resource)
          },
          "scopeMetrics" => [
            %{
              "scope" => %{
                "name" => "observlib",
                "version" => "0.1.0"
              },
              "metrics" => metrics
            }
          ]
        }
      ]
    }

    # Send HTTP POST request with TLS validation
    case ObservLib.HTTP.post(url, json: body) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        Logger.debug("Metrics exported successfully")
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        safe_body = ObservLib.HTTP.redact_sensitive_headers(body)
        Logger.error("Metrics export failed with status #{status}: #{inspect(safe_body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("Metrics export request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_metric_key(event_name, metadata) do
    # Create unique key for metric aggregation
    metric_name = Enum.join(event_name, ".")
    attributes = Map.drop(metadata, [:metric_type])
    {metric_name, attributes}
  end

  defp build_initial_metric(metric_type, measurements, metadata) do
    %{
      type: metric_type,
      data_points: [build_data_point(metric_type, measurements, metadata)],
      timestamp: System.system_time(:nanosecond)
    }
  end

  @dialyzer {:nowarn_function, aggregate_metric: 4}
  defp aggregate_metric(existing, metric_type, measurements, metadata) do
    new_data_point = build_data_point(metric_type, measurements, metadata)

    case metric_type do
      :counter ->
        # Sum all counter values
        %{existing | data_points: [new_data_point | existing.data_points]}

      :gauge ->
        # Keep only last value for gauges
        %{existing | data_points: [new_data_point], timestamp: System.system_time(:nanosecond)}

      :histogram ->
        # Accumulate histogram observations
        %{existing | data_points: [new_data_point | existing.data_points]}

      :up_down_counter ->
        # Sum all up-down counter values
        %{existing | data_points: [new_data_point | existing.data_points]}

      _ ->
        existing
    end
  end

  defp build_data_point(metric_type, measurements, metadata) do
    value =
      case metric_type do
        :counter -> Map.get(measurements, :count, 0)
        :gauge -> Map.get(measurements, :value, 0)
        :histogram -> Map.get(measurements, :value, 0)
        :up_down_counter -> Map.get(measurements, :value, 0)
      end

    attributes = Map.drop(metadata, [:metric_type])

    %{
      value: value,
      attributes: attributes,
      timestamp: System.system_time(:nanosecond)
    }
  end

  defp build_otlp_metrics(metrics) do
    Enum.map(metrics, fn {{metric_name, _attributes}, metric_data} ->
      build_otlp_metric(metric_name, metric_data)
    end)
  end

  # Convert metrics from MeterProvider format to OTLP format
  defp build_otlp_metrics_from_provider([]), do: []

  defp build_otlp_metrics_from_provider(metrics) do
    # Group by metric name
    metrics
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, data_points} ->
      build_otlp_metric_from_provider(name, data_points)
    end)
  end

  defp build_otlp_metric_from_provider(name, data_points) do
    # Get type from first data point
    type = List.first(data_points).type

    case type do
      :counter ->
        %{
          "name" => name,
          "sum" => %{
            "dataPoints" =>
              Enum.map(data_points, fn dp ->
                %{
                  "asInt" => trunc(dp.data.value),
                  "timeUnixNano" => to_string(dp.data.timestamp),
                  "attributes" => map_to_attributes(dp.attributes)
                }
              end),
            "aggregationTemporality" => 2,
            "isMonotonic" => true
          }
        }

      :gauge ->
        %{
          "name" => name,
          "gauge" => %{
            "dataPoints" =>
              Enum.map(data_points, fn dp ->
                %{
                  "asDouble" => dp.data.value,
                  "timeUnixNano" => to_string(dp.data.timestamp),
                  "attributes" => map_to_attributes(dp.attributes)
                }
              end)
          }
        }

      :histogram ->
        %{
          "name" => name,
          "histogram" => %{
            "dataPoints" =>
              Enum.map(data_points, fn dp ->
                buckets = dp.data.buckets || []
                bounds = Enum.map(buckets, fn {b, _} -> b end) |> Enum.reject(&(&1 == :infinity))
                counts = Enum.map(buckets, fn {_, c} -> to_string(c) end)

                %{
                  "count" => to_string(dp.data.count),
                  "sum" => dp.data.sum,
                  "timeUnixNano" => to_string(dp.data.timestamp),
                  "attributes" => map_to_attributes(dp.attributes),
                  "bucketCounts" => counts,
                  "explicitBounds" => bounds
                }
              end),
            "aggregationTemporality" => 2
          }
        }

      :up_down_counter ->
        %{
          "name" => name,
          "sum" => %{
            "dataPoints" =>
              Enum.map(data_points, fn dp ->
                %{
                  "asInt" => trunc(dp.data.value),
                  "timeUnixNano" => to_string(dp.data.timestamp),
                  "attributes" => map_to_attributes(dp.attributes)
                }
              end),
            "aggregationTemporality" => 2,
            "isMonotonic" => false
          }
        }

      _ ->
        %{"name" => name, "gauge" => %{"dataPoints" => []}}
    end
  end

  defp build_otlp_metric(metric_name, %{type: type, data_points: data_points}) do
    # Aggregate data points based on metric type
    aggregated = aggregate_data_points(type, data_points)

    %{
      "name" => metric_name,
      metric_type_to_otlp_field(type) => aggregated
    }
  end

  defp aggregate_data_points(:counter, data_points) do
    # Sum all counter values
    total = Enum.reduce(data_points, 0, fn dp, acc -> acc + dp.value end)
    latest_timestamp = Enum.max_by(data_points, & &1.timestamp).timestamp
    attributes = List.first(data_points).attributes

    %{
      "dataPoints" => [
        %{
          "asInt" => trunc(total),
          "timeUnixNano" => to_string(latest_timestamp),
          "attributes" => map_to_attributes(attributes)
        }
      ],
      "aggregationTemporality" => 2,
      "isMonotonic" => true
    }
  end

  defp aggregate_data_points(:gauge, data_points) do
    # Use last value
    latest = Enum.max_by(data_points, & &1.timestamp)

    %{
      "dataPoints" => [
        %{
          "asDouble" => latest.value,
          "timeUnixNano" => to_string(latest.timestamp),
          "attributes" => map_to_attributes(latest.attributes)
        }
      ]
    }
  end

  defp aggregate_data_points(:histogram, data_points) do
    # Calculate histogram statistics
    values = Enum.map(data_points, & &1.value)
    count = length(values)
    sum = Enum.sum(values)
    latest_timestamp = Enum.max_by(data_points, & &1.timestamp).timestamp
    attributes = List.first(data_points).attributes

    # Calculate bucket counts (simple exponential buckets)
    buckets = calculate_histogram_buckets(values)

    %{
      "dataPoints" => [
        %{
          "count" => to_string(count),
          "sum" => sum,
          "timeUnixNano" => to_string(latest_timestamp),
          "attributes" => map_to_attributes(attributes),
          "bucketCounts" => buckets.counts,
          "explicitBounds" => buckets.bounds
        }
      ],
      "aggregationTemporality" => 2
    }
  end

  defp aggregate_data_points(:up_down_counter, data_points) do
    # Sum all up-down counter values (can be positive or negative)
    total = Enum.reduce(data_points, 0, fn dp, acc -> acc + dp.value end)
    latest_timestamp = Enum.max_by(data_points, & &1.timestamp).timestamp
    attributes = List.first(data_points).attributes

    %{
      "dataPoints" => [
        %{
          "asInt" => trunc(total),
          "timeUnixNano" => to_string(latest_timestamp),
          "attributes" => map_to_attributes(attributes)
        }
      ],
      "aggregationTemporality" => 2,
      "isMonotonic" => false
    }
  end

  defp metric_type_to_otlp_field(:counter), do: "sum"
  defp metric_type_to_otlp_field(:gauge), do: "gauge"
  defp metric_type_to_otlp_field(:histogram), do: "histogram"
  defp metric_type_to_otlp_field(:up_down_counter), do: "sum"

  defp calculate_histogram_buckets(values) do
    # Define exponential bucket boundaries
    bounds = [0.0, 5.0, 10.0, 25.0, 50.0, 75.0, 100.0, 250.0, 500.0, 1000.0]

    # Count values in each bucket
    counts =
      Enum.reduce(bounds ++ [:infinity], [], fn boundary, acc ->
        count = count_in_bucket(boundary, acc, values, bounds)
        [to_string(count) | acc]
      end)
      |> Enum.reverse()

    %{
      bounds: bounds,
      counts: counts
    }
  end

  defp count_in_bucket(:infinity, _acc, values, bounds) do
    last_bound = List.last(bounds)
    Enum.count(values, fn v -> v > last_bound end)
  end

  defp count_in_bucket(b, acc, values, bounds) do
    prev_bound = if acc == [], do: 0.0, else: Enum.at(bounds, length(acc) - 1)
    Enum.count(values, fn v -> v > prev_bound and v <= b end)
  end

  defp map_to_attributes(map) when map == %{}, do: []

  defp map_to_attributes(map) do
    Enum.map(map, fn {key, value} ->
      %{
        "key" => to_string(key),
        "value" => attribute_value(value)
      }
    end)
  end

  defp resource_to_attributes(resource) do
    Enum.map(resource, fn {key, value} ->
      %{
        "key" => to_string(key),
        "value" => attribute_value(value)
      }
    end)
  end

  defp attribute_value(value) when is_binary(value), do: %{"stringValue" => value}
  defp attribute_value(value) when is_integer(value), do: %{"intValue" => to_string(value)}
  defp attribute_value(value) when is_float(value), do: %{"doubleValue" => value}
  defp attribute_value(value) when is_boolean(value), do: %{"boolValue" => value}
  defp attribute_value(value), do: %{"stringValue" => to_string(value)}

  defp update_export_stats(state, :ok) do
    %{
      state
      | export_count: state.export_count + 1,
        last_export_time: DateTime.utc_now(),
        metrics: %{},
        retry_count: 0
    }
  end

  defp update_export_stats(state, {:error, _reason}) do
    %{
      state
      | error_count: state.error_count + 1,
        last_export_time: DateTime.utc_now(),
        retry_count: 0
    }
  end

  defp calculate_retry_delay(retry_count) do
    # Exponential backoff with jitter: 1s, 2s, 4s, 8s, max 30s
    base = min(:math.pow(2, retry_count) * 1000, 30_000)
    jitter = :rand.uniform(1000)
    trunc(base + jitter)
  end
end
