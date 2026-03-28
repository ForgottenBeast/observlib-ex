defmodule ObservLib.Metrics.PrometheusReader do
  @moduledoc """
  GenServer serving a Prometheus-compatible scrape endpoint.

  Uses `:gen_tcp` to serve HTTP requests on a configurable port (default: 9568).
  Responds to `GET /metrics` with Prometheus text format output.

  ## Configuration

      config :observlib,
        prometheus_port: 9568,
        prometheus_max_connections: 10,
        prometheus_rate_limit: 100,
        prometheus_basic_auth: {"username", "password"}

  ## Security Features

  ### sec-008: Connection, Rate Limiting, and Authentication
  - **Connection Limiting**: Limits concurrent connections to prevent resource exhaustion
  - **Rate Limiting**: Token bucket algorithm limits requests per minute
  - **Basic Authentication**: Optional HTTP Basic Auth for access control

  ### sec-014: Enhanced Prometheus Label Injection Prevention
  - **Control Character Escaping**: Escapes all ASCII control characters (0-31, 127) in label values
  - **CRLF Injection Prevention**: Escapes carriage return and newline characters
  - **Null Byte Handling**: Converts null bytes to \x00 escape sequences
  - **Comprehensive Escaping**: Handles backslash, quotes, tabs, and all other control chars

  ## Prometheus Format

  Outputs metrics in the Prometheus text exposition format:

      # HELP http_requests_total Total HTTP requests
      # TYPE http_requests_total counter
      http_requests_total{method="GET",status="200"} 42

  ## Example

      # Start the reader (typically via Metrics.Supervisor)
      {:ok, pid} = ObservLib.Metrics.PrometheusReader.start_link()

      # Scrape metrics (without auth)
      curl http://localhost:9568/metrics

      # Scrape metrics (with auth)
      curl -u username:password http://localhost:9568/metrics
  """

  use GenServer
  require Logger

  @default_port 9568

  # Client API

  @doc """
  Starts the PrometheusReader GenServer.

  ## Options

    * `:port` - TCP port to listen on (default: 9568, or from config)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the current port the reader is listening on.
  """
  @spec get_port() :: integer()
  def get_port do
    GenServer.call(__MODULE__, :get_port)
  end

  @doc """
  Gets statistics about the reader.
  """
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port) ||
           Application.get_env(:observlib, :prometheus_port, @default_port)

    max_connections = Application.get_env(:observlib, :prometheus_max_connections, 10)
    rate_limit = Application.get_env(:observlib, :prometheus_rate_limit, 100)
    basic_auth = Application.get_env(:observlib, :prometheus_basic_auth, nil)

    # Start TCP listener
    case :gen_tcp.listen(port, [
      :binary,
      packet: :http_bin,
      active: false,
      reuseaddr: true
    ]) do
      {:ok, listen_socket} ->
        # Start accepting connections in a separate process
        acceptor_pid = spawn_link(fn -> accept_loop(listen_socket, self()) end)

        state = %{
          port: port,
          listen_socket: listen_socket,
          acceptor_pid: acceptor_pid,
          scrape_count: 0,
          error_count: 0,
          last_scrape_time: nil,
          active_connections: 0,
          max_connections: max_connections,
          rate_limiter: init_rate_limiter(rate_limit),
          basic_auth: basic_auth
        }

        Logger.info("PrometheusReader started on port #{port} (max_connections: #{max_connections}, rate_limit: #{rate_limit} req/min)")
        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to start PrometheusReader on port #{port}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, state.port, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      port: state.port,
      scrape_count: state.scrape_count,
      error_count: state.error_count,
      last_scrape_time: state.last_scrape_time,
      active_connections: state.active_connections,
      max_connections: state.max_connections
    }
    {:reply, stats, state}
  end

  @impl true
  def handle_info({:new_connection, socket}, state) do
    if state.active_connections >= state.max_connections do
      Logger.warning("Prometheus connection limit exceeded (#{state.active_connections}/#{state.max_connections})")
      :gen_tcp.close(socket)
      {:noreply, state}
    else
      case check_rate_limit(state.rate_limiter) do
        {:ok, new_limiter} ->
          spawn(fn -> handle_request(socket, self(), state.basic_auth) end)
          {:noreply, %{state |
            active_connections: state.active_connections + 1,
            rate_limiter: new_limiter
          }}

        {:rate_limited, new_limiter} ->
          Logger.warning("Prometheus rate limit exceeded")
          send_rate_limit_response(socket)
          :gen_tcp.close(socket)
          {:noreply, %{state | rate_limiter: new_limiter}}
      end
    end
  end

  @impl true
  def handle_info({:connection_closed}, state) do
    {:noreply, %{state |
      active_connections: max(0, state.active_connections - 1)
    }}
  end

  @impl true
  def handle_info({:scrape_complete, :ok}, state) do
    {:noreply, %{state |
      scrape_count: state.scrape_count + 1,
      last_scrape_time: DateTime.utc_now()
    }}
  end

  @impl true
  def handle_info({:scrape_complete, :error}, state) do
    {:noreply, %{state |
      error_count: state.error_count + 1,
      last_scrape_time: DateTime.utc_now()
    }}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Close the listening socket
    if state[:listen_socket] do
      :gen_tcp.close(state.listen_socket)
    end
    :ok
  end

  # Private Functions - Accept Loop

  defp accept_loop(listen_socket, parent) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        # Send new connection to GenServer for rate limiting and auth
        send(parent, {:new_connection, client_socket})
        accept_loop(listen_socket, parent)

      {:error, :closed} ->
        # Socket closed, exit normally
        :ok

      {:error, reason} ->
        Logger.warning("Accept error: #{inspect(reason)}")
        accept_loop(listen_socket, parent)
    end
  end

  defp handle_request(socket, parent, basic_auth) do
    result = do_handle_request(socket, basic_auth)
    send(parent, {:scrape_complete, result})
    :gen_tcp.close(socket)
    send(parent, {:connection_closed})
  end

  defp do_handle_request(socket, basic_auth) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, {:http_request, :GET, {:abs_path, "/metrics"}, _version}} ->
        # Collect headers for authentication
        headers = collect_headers(socket)

        # Check authentication
        if authorized?(headers, basic_auth) do
          send_metrics_response(socket)
          :ok
        else
          send_unauthorized_response(socket)
          :error
        end

      {:ok, {:http_request, :GET, {:abs_path, _path}, _version}} ->
        # 404 for non-metrics paths
        consume_headers(socket)
        send_404_response(socket)
        :ok

      {:ok, {:http_request, _method, _path, _version}} ->
        # 405 for non-GET methods
        consume_headers(socket)
        send_405_response(socket)
        :ok

      {:error, reason} ->
        Logger.debug("Request error: #{inspect(reason)}")
        :error
    end
  end

  defp collect_headers(socket) do
    collect_headers(socket, %{})
  end

  defp collect_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, :http_eoh} ->
        headers

      {:ok, {:http_header, _, 'Authorization', _, value}} ->
        collect_headers(socket, Map.put(headers, :authorization, to_string(value)))

      {:ok, {:http_header, _, :Authorization, _, value}} ->
        collect_headers(socket, Map.put(headers, :authorization, to_string(value)))

      {:ok, {:http_header, _, _, _, _}} ->
        collect_headers(socket, headers)

      {:error, _} ->
        headers
    end
  end

  defp consume_headers(socket) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, :http_eoh} ->
        :ok

      {:ok, {:http_header, _, _, _, _}} ->
        consume_headers(socket)

      {:error, _} ->
        :ok
    end
  end

  defp send_metrics_response(socket) do
    metrics = ObservLib.Metrics.MeterProvider.read_all()
    body = format_prometheus_output(metrics)

    response = [
      "HTTP/1.1 200 OK\r\n",
      "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "\r\n",
      body
    ]

    :gen_tcp.send(socket, response)
  end

  defp send_404_response(socket) do
    body = "Not Found"
    response = [
      "HTTP/1.1 404 Not Found\r\n",
      "Content-Type: text/plain\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "\r\n",
      body
    ]
    :gen_tcp.send(socket, response)
  end

  defp send_405_response(socket) do
    body = "Method Not Allowed"
    response = [
      "HTTP/1.1 405 Method Not Allowed\r\n",
      "Content-Type: text/plain\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "\r\n",
      body
    ]
    :gen_tcp.send(socket, response)
  end

  defp send_unauthorized_response(socket) do
    body = "Unauthorized"
    response = [
      "HTTP/1.1 401 Unauthorized\r\n",
      "WWW-Authenticate: Basic realm=\"Prometheus Metrics\"\r\n",
      "Content-Type: text/plain\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "\r\n",
      body
    ]
    :gen_tcp.send(socket, response)
  end

  defp send_rate_limit_response(socket) do
    body = "Too Many Requests"
    response = [
      "HTTP/1.1 429 Too Many Requests\r\n",
      "Content-Type: text/plain\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "\r\n",
      body
    ]
    :gen_tcp.send(socket, response)
  end

  # Rate Limiting Functions

  defp init_rate_limiter(rate_per_minute) do
    %{
      tokens: rate_per_minute,
      max_tokens: rate_per_minute,
      last_refill: System.monotonic_time(:millisecond)
    }
  end

  defp check_rate_limit(limiter) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - limiter.last_refill

    # Refill tokens based on elapsed time (tokens per millisecond)
    tokens_to_add = div(elapsed * limiter.max_tokens, 60_000)
    new_tokens = min(limiter.tokens + tokens_to_add, limiter.max_tokens)

    new_limiter = %{limiter |
      tokens: new_tokens,
      last_refill: if(tokens_to_add > 0, do: now, else: limiter.last_refill)
    }

    if new_limiter.tokens > 0 do
      {:ok, %{new_limiter | tokens: new_limiter.tokens - 1}}
    else
      {:rate_limited, new_limiter}
    end
  end

  # Authentication Functions

  defp authorized?(_headers, nil), do: true

  defp authorized?(headers, {username, password}) do
    case Map.get(headers, :authorization) do
      "Basic " <> encoded ->
        case Base.decode64(encoded) do
          {:ok, credentials} ->
            credentials == "#{username}:#{password}"

          :error ->
            false
        end

      _ ->
        false
    end
  end

  # Prometheus Format Functions

  defp format_prometheus_output([]), do: ""

  defp format_prometheus_output(metrics) do
    # Group metrics by name
    metrics
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, data_points} ->
      format_metric_family(name, data_points)
    end)
    |> Enum.join("\n")
  end

  defp format_metric_family(name, data_points) do
    # Get type from first data point
    type = List.first(data_points).type
    prom_name = sanitize_metric_name(name)
    prom_type = type_to_prometheus(type)

    lines = [
      "# TYPE #{prom_name} #{prom_type}"
    ]

    metric_lines = Enum.flat_map(data_points, fn dp ->
      format_data_point(prom_name, dp)
    end)

    Enum.join(lines ++ metric_lines, "\n")
  end

  defp format_data_point(name, %{type: :counter, attributes: attrs, data: data}) do
    labels = format_labels(attrs)
    value = data.value
    ["#{name}#{labels} #{format_value(value)}"]
  end

  defp format_data_point(name, %{type: :gauge, attributes: attrs, data: data}) do
    labels = format_labels(attrs)
    value = data.value
    ["#{name}#{labels} #{format_value(value)}"]
  end

  defp format_data_point(name, %{type: :histogram, attributes: attrs, data: data}) do
    labels = format_labels(attrs)
    base_labels = if labels == "", do: "", else: String.slice(labels, 1..-2//1)

    bucket_lines = Enum.map(data.buckets, fn
      {:infinity, count} ->
        le_labels = if base_labels == "", do: "{le=\"+Inf\"}", else: "{#{base_labels},le=\"+Inf\"}"
        "#{name}_bucket#{le_labels} #{count}"

      {boundary, count} ->
        le_labels = if base_labels == "", do: "{le=\"#{boundary}\"}", else: "{#{base_labels},le=\"#{boundary}\"}"
        "#{name}_bucket#{le_labels} #{count}"
    end)

    sum_line = "#{name}_sum#{labels} #{format_value(data.sum)}"
    count_line = "#{name}_count#{labels} #{data.count}"

    bucket_lines ++ [sum_line, count_line]
  end

  defp format_data_point(name, %{type: :up_down_counter, attributes: attrs, data: data}) do
    labels = format_labels(attrs)
    value = data.value
    ["#{name}#{labels} #{format_value(value)}"]
  end

  defp format_data_point(_name, _dp), do: []

  defp format_labels(attrs) when map_size(attrs) == 0, do: ""

  defp format_labels(attrs) do
    label_pairs = attrs
    |> Enum.map(fn {k, v} ->
      key = sanitize_label_name(to_string(k))
      value = escape_label_value(to_string(v))
      "#{key}=\"#{value}\""
    end)
    |> Enum.join(",")

    "{#{label_pairs}}"
  end

  defp format_value(value) when is_float(value) do
    if value == Float.round(value), do: "#{trunc(value)}.0", else: "#{value}"
  end

  defp format_value(value) when is_integer(value), do: "#{value}"
  defp format_value(value), do: "#{value}"

  defp sanitize_metric_name(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_:]/, "_")
    |> String.replace(~r/^[^a-zA-Z_:]/, "_")
  end

  defp sanitize_label_name(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> String.replace(~r/^[^a-zA-Z_]/, "_")
  end

  defp escape_label_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")     # Backslash first!
    |> String.replace("\"", "\\\"")     # Double quote
    |> String.replace("\n", "\\n")      # Newline
    |> String.replace("\r", "\\r")      # Carriage return
    |> String.replace("\t", "\\t")      # Tab
    |> escape_control_chars()           # All other control chars
  end

  defp escape_label_value(value), do: escape_label_value(to_string(value))

  defp escape_control_chars(value) do
    value
    |> String.to_charlist()
    |> Enum.map(fn
      char when char < 32 or char == 127 ->
        # Escape control characters as \xHH (except already-escaped \n, \r, \t)
        case char do
          10 -> "\\n"  # \n (already handled)
          13 -> "\\r"  # \r (already handled)
          9 -> "\\t"   # \t (already handled)
          0 -> "\\x00" # Null byte
          _ -> "\\x" <> String.pad_leading(Integer.to_string(char, 16), 2, "0")
        end
      char ->
        <<char::utf8>>
    end)
    |> Enum.join()
  end

  defp type_to_prometheus(:counter), do: "counter"
  defp type_to_prometheus(:gauge), do: "gauge"
  defp type_to_prometheus(:histogram), do: "histogram"
  defp type_to_prometheus(:up_down_counter), do: "gauge"  # Prometheus doesn't have up_down_counter
  defp type_to_prometheus(_), do: "untyped"
end
