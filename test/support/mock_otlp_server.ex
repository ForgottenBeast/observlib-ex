defmodule ObservLib.Test.MockOtlpServer do
  @moduledoc """
  Mock OTLP HTTP server for integration testing.

  Accepts POST requests to OTLP endpoints and stores received payloads
  for test assertions.

  ## Usage

      {:ok, server} = MockOtlpServer.start_link()
      port = MockOtlpServer.port(server)

      # Configure ObservLib to use this endpoint
      # ... emit traces, metrics, logs ...

      # Assert on received data
      traces = MockOtlpServer.get_traces(server)
      metrics = MockOtlpServer.get_metrics(server)
      logs = MockOtlpServer.get_logs(server)

      MockOtlpServer.stop(server)
  """

  use GenServer
  require Logger

  defstruct [:listen_socket, :port, :acceptor_pid, :traces, :metrics, :logs, :response_mode]

  # Client API

  @doc """
  Starts the mock OTLP server on a random available port.

  ## Options

    * `:port` - Specific port to listen on (default: 0 for random)
    * `:response_mode` - `:success`, `:error_503`, or `:error_then_success` (default: `:success`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Gets the port the server is listening on.
  """
  @spec port(GenServer.server()) :: integer()
  def port(server) do
    GenServer.call(server, :get_port)
  end

  @doc """
  Gets the endpoint URL for this server.
  """
  @spec endpoint(GenServer.server()) :: String.t()
  def endpoint(server) do
    "http://127.0.0.1:#{port(server)}"
  end

  @doc """
  Gets all received trace payloads.
  """
  @spec get_traces(GenServer.server()) :: [map()]
  def get_traces(server) do
    GenServer.call(server, :get_traces)
  end

  @doc """
  Gets all received metric payloads.
  """
  @spec get_metrics(GenServer.server()) :: [map()]
  def get_metrics(server) do
    GenServer.call(server, :get_metrics)
  end

  @doc """
  Gets all received log payloads.
  """
  @spec get_logs(GenServer.server()) :: [map()]
  def get_logs(server) do
    GenServer.call(server, :get_logs)
  end

  @doc """
  Resets all stored payloads.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server) do
    GenServer.call(server, :reset)
  end

  @doc """
  Sets the response mode for testing retry logic.

    * `:success` - Always return 200 OK
    * `:error_503` - Always return 503 Service Unavailable
    * `:error_then_success` - Return 503 once, then 200
  """
  @spec set_response_mode(GenServer.server(), atom()) :: :ok
  def set_response_mode(server, mode) do
    GenServer.call(server, {:set_response_mode, mode})
  end

  @doc """
  Stops the mock server.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 0)
    response_mode = Keyword.get(opts, :response_mode, :success)

    case :gen_tcp.listen(port, [
      :binary,
      packet: :http_bin,
      active: false,
      reuseaddr: true
    ]) do
      {:ok, listen_socket} ->
        # Get the actual port if we requested 0
        {:ok, actual_port} = :inet.port(listen_socket)

        # Start acceptor process
        parent = self()
        acceptor_pid = spawn_link(fn -> accept_loop(listen_socket, parent) end)

        state = %__MODULE__{
          listen_socket: listen_socket,
          port: actual_port,
          acceptor_pid: acceptor_pid,
          traces: [],
          metrics: [],
          logs: [],
          response_mode: response_mode
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get_port, _from, state) do
    {:reply, state.port, state}
  end

  @impl true
  def handle_call(:get_traces, _from, state) do
    {:reply, Enum.reverse(state.traces), state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    {:reply, Enum.reverse(state.metrics), state}
  end

  @impl true
  def handle_call(:get_logs, _from, state) do
    {:reply, Enum.reverse(state.logs), state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | traces: [], metrics: [], logs: []}}
  end

  @impl true
  def handle_call({:set_response_mode, mode}, _from, state) do
    {:reply, :ok, %{state | response_mode: mode}}
  end

  @impl true
  def handle_info({:request, path, body, from}, state) do
    {response_status, new_response_mode} = get_response(state.response_mode)

    new_state =
      case path do
        "/v1/traces" ->
          payload = parse_json(body)
          send(from, {:response, response_status})
          %{state | traces: [payload | state.traces], response_mode: new_response_mode}

        "/v1/metrics" ->
          payload = parse_json(body)
          send(from, {:response, response_status})
          %{state | metrics: [payload | state.metrics], response_mode: new_response_mode}

        "/v1/logs" ->
          payload = parse_json(body)
          send(from, {:response, response_status})
          %{state | logs: [payload | state.logs], response_mode: new_response_mode}

        _ ->
          send(from, {:response, 404})
          %{state | response_mode: new_response_mode}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.listen_socket do
      :gen_tcp.close(state.listen_socket)
    end
    :ok
  end

  # Private Functions

  defp accept_loop(listen_socket, parent) do
    case :gen_tcp.accept(listen_socket, 1000) do
      {:ok, client_socket} ->
        spawn(fn -> handle_client(client_socket, parent) end)
        accept_loop(listen_socket, parent)

      {:error, :timeout} ->
        # Keep accepting
        accept_loop(listen_socket, parent)

      {:error, :closed} ->
        # Socket closed, exit
        :ok

      {:error, _reason} ->
        # Keep accepting on other errors
        accept_loop(listen_socket, parent)
    end
  end

  defp handle_client(socket, parent) do
    case read_request(socket) do
      {:ok, method, path, body} when method in [:POST, "POST"] ->
        # Send request to parent for processing
        send(parent, {:request, path, body, self()})

        # Wait for response
        receive do
          {:response, status} ->
            send_response(socket, status)
        after
          5000 ->
            send_response(socket, 500)
        end

      {:ok, _method, _path, _body} ->
        send_response(socket, 405)

      {:error, _reason} ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp read_request(socket) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, {:http_request, method, {:abs_path, path}, _version}} ->
        headers = read_headers(socket, %{})
        content_length = Map.get(headers, "content-length", "0") |> String.to_integer()

        # Switch to raw mode to read body
        :inet.setopts(socket, packet: :raw)

        body =
          if content_length > 0 do
            case :gen_tcp.recv(socket, content_length, 5000) do
              {:ok, data} -> data
              {:error, _} -> ""
            end
          else
            ""
          end

        {:ok, method, path, body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, :http_eoh} ->
        acc

      {:ok, {:http_header, _, key, _, value}} ->
        key_str = normalize_header_key(key)
        read_headers(socket, Map.put(acc, key_str, value))

      {:error, _} ->
        acc
    end
  end

  defp normalize_header_key(key) when is_atom(key) do
    key |> Atom.to_string() |> String.downcase()
  end

  defp normalize_header_key(key) when is_binary(key) do
    String.downcase(key)
  end

  defp send_response(socket, 200) do
    response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
    :gen_tcp.send(socket, response)
  end

  defp send_response(socket, 404) do
    body = "Not Found"
    response = "HTTP/1.1 404 Not Found\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
    :gen_tcp.send(socket, response)
  end

  defp send_response(socket, 405) do
    body = "Method Not Allowed"
    response = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
    :gen_tcp.send(socket, response)
  end

  defp send_response(socket, 500) do
    body = "Internal Server Error"
    response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
    :gen_tcp.send(socket, response)
  end

  defp send_response(socket, 503) do
    body = "Service Unavailable"
    response = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
    :gen_tcp.send(socket, response)
  end

  defp get_response(:success), do: {200, :success}
  defp get_response(:error_503), do: {503, :error_503}
  defp get_response(:error_then_success), do: {503, :success}

  defp parse_json(body) when is_binary(body) and byte_size(body) > 0 do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"raw" => body}
    end
  end

  defp parse_json(_), do: %{}
end
