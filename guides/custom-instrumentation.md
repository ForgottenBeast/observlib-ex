# Custom Instrumentation Guide

This guide covers advanced instrumentation patterns with ObservLib.

## Creating Custom Spans

### Basic Span Creation

```elixir
# Start and end manually
span = ObservLib.Traces.start_span("my_operation")
# ... do work ...
ObservLib.Traces.end_span(span)
```

### Spans with Attributes

```elixir
span = ObservLib.Traces.start_span("database_query", %{
  "db.system" => "postgresql",
  "db.statement" => "SELECT * FROM users",
  "db.name" => "mydb"
})
result = Repo.all(User)
ObservLib.Traces.end_span(span)
```

### Using with_span for Automatic Cleanup

```elixir
result = ObservLib.Traces.with_span("process_order", %{"order.id" => order_id}, fn ->
  validate_order(order)
  charge_payment(order)
  fulfill_order(order)
end)
```

The span automatically ends when the function returns, even if an exception is raised.

### Setting Span Attributes Dynamically

```elixir
span = ObservLib.Traces.start_span("http_request")
:otel_tracer.set_current_span(span)

# Add attributes as you learn more
ObservLib.Traces.set_attribute("http.method", "POST")
ObservLib.Traces.set_attribute("http.url", "/api/users")

response = make_request()

ObservLib.Traces.set_attribute("http.status_code", response.status)
ObservLib.Traces.end_span(span)
```

### Setting Span Status

```elixir
span = ObservLib.Traces.start_span("operation")
:otel_tracer.set_current_span(span)

case do_work() do
  {:ok, _result} ->
    ObservLib.Traces.set_status(:ok)

  {:error, reason} ->
    ObservLib.Traces.set_status(:error, "Failed: #{inspect(reason)}")
end

ObservLib.Traces.end_span(span)
```

### Recording Exceptions

```elixir
span = ObservLib.Traces.start_span("risky_operation")
:otel_tracer.set_current_span(span)

try do
  dangerous_operation()
rescue
  e ->
    ObservLib.Traces.record_exception(e)
    ObservLib.Traces.set_status(:error, Exception.message(e))
    reraise e, __STACKTRACE__
after
  ObservLib.Traces.end_span(span)
end
```

## Recording Custom Metrics

### Counters

Use counters for monotonically increasing values:

```elixir
# Simple increment
ObservLib.counter("requests.total", 1)

# With attributes
ObservLib.counter("http.requests", 1, %{
  method: "GET",
  status: 200,
  path: "/api/users"
})

# Increment by more than 1
ObservLib.counter("bytes.received", 2048, %{protocol: "http"})
```

### Gauges

Use gauges for point-in-time values that can go up or down:

```elixir
# Current memory usage
ObservLib.gauge("memory.heap_size", :erlang.memory(:total))

# Queue depth
ObservLib.gauge("queue.length", GenServer.call(Queue, :length), %{queue: "jobs"})

# Active connections
ObservLib.gauge("connections.active", ConnectionPool.count())
```

### Histograms

Use histograms for distributions (latencies, sizes):

```elixir
# Request duration
start = System.monotonic_time()
result = process_request()
duration_ms = System.monotonic_time() - start |> System.convert_time_unit(:native, :millisecond)

ObservLib.histogram("http.request.duration", duration_ms, %{
  method: "GET",
  path: "/api/users"
})

# Response size
ObservLib.histogram("http.response.size", byte_size(body), %{content_type: "application/json"})
```

### Timing Helper Pattern

```elixir
defmodule MyApp.Metrics do
  def timed(name, attributes \\ %{}, fun) do
    start = System.monotonic_time()
    result = fun.()
    duration_ms = System.monotonic_time() - start
                  |> System.convert_time_unit(:native, :millisecond)

    ObservLib.histogram(name, duration_ms, attributes)
    result
  end
end

# Usage
MyApp.Metrics.timed("db.query.duration", %{table: "users"}, fn ->
  Repo.all(User)
end)
```

## Custom Telemetry Event Handlers

### Attaching Handlers

```elixir
# Attach to a specific event prefix
ObservLib.Telemetry.attach([:my_app, :worker])

# Events like [:my_app, :worker, :start] and [:my_app, :worker, :stop]
# will now create spans
```

### Custom Handler Function

```elixir
defmodule MyApp.TelemetryHandler do
  def handle_event([:my_app, :cache, :hit], measurements, metadata, _config) do
    ObservLib.counter("cache.hits", 1, %{
      cache: metadata[:cache_name],
      key_prefix: extract_prefix(metadata[:key])
    })
  end

  def handle_event([:my_app, :cache, :miss], measurements, metadata, _config) do
    ObservLib.counter("cache.misses", 1, %{
      cache: metadata[:cache_name]
    })

    if measurements[:lookup_time] do
      ObservLib.histogram("cache.lookup_time", measurements[:lookup_time], %{
        cache: metadata[:cache_name],
        hit: false
      })
    end
  end

  defp extract_prefix(key) when is_binary(key) do
    key |> String.split(":") |> List.first()
  end
end

# Attach custom handler
ObservLib.Telemetry.attach([:my_app, :cache, :hit],
  handler: &MyApp.TelemetryHandler.handle_event/4
)
ObservLib.Telemetry.attach([:my_app, :cache, :miss],
  handler: &MyApp.TelemetryHandler.handle_event/4
)
```

### Emitting Custom Telemetry Events

```elixir
defmodule MyApp.Cache do
  def get(key) do
    start_time = System.monotonic_time()

    case lookup(key) do
      {:ok, value} ->
        :telemetry.execute(
          [:my_app, :cache, :hit],
          %{lookup_time: System.monotonic_time() - start_time},
          %{cache_name: __MODULE__, key: key}
        )
        {:ok, value}

      :miss ->
        :telemetry.execute(
          [:my_app, :cache, :miss],
          %{lookup_time: System.monotonic_time() - start_time},
          %{cache_name: __MODULE__, key: key}
        )
        :miss
    end
  end
end
```

## Integration Patterns

### Phoenix Controller Instrumentation

```elixir
defmodule MyAppWeb.UserController do
  use MyAppWeb, :controller

  def show(conn, %{"id" => id}) do
    ObservLib.traced("UserController.show", %{"user.id" => id}, fn ->
      user = Users.get_user!(id)
      render(conn, :show, user: user)
    end)
  end
end
```

### GenServer Instrumentation

```elixir
defmodule MyApp.Worker do
  use GenServer

  def handle_call({:process, item}, _from, state) do
    result = ObservLib.traced("Worker.process", %{"item.id" => item.id}, fn ->
      ObservLib.counter("worker.items_processed", 1)
      do_process(item)
    end)

    {:reply, result, state}
  end

  def handle_info(:tick, state) do
    ObservLib.gauge("worker.queue_size", length(state.queue))
    {:noreply, state}
  end
end
```

### Ecto Query Instrumentation

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app

  def traced_all(queryable, opts \\ []) do
    ObservLib.traced("Repo.all", %{"ecto.source" => source_name(queryable)}, fn ->
      all(queryable, opts)
    end)
  end

  defp source_name(%Ecto.Query{from: %{source: {table, _}}}), do: table
  defp source_name(schema) when is_atom(schema), do: schema.__schema__(:source)
  defp source_name(_), do: "unknown"
end
```

### HTTP Client Instrumentation

```elixir
defmodule MyApp.HTTPClient do
  def get(url, headers \\ []) do
    ObservLib.traced("http.client.request", %{
      "http.method" => "GET",
      "http.url" => url
    }, fn ->
      start = System.monotonic_time()

      case Req.get(url, headers: headers) do
        {:ok, response} ->
          duration = System.monotonic_time() - start
                     |> System.convert_time_unit(:native, :millisecond)

          ObservLib.histogram("http.client.duration", duration, %{
            method: "GET",
            status: response.status
          })

          {:ok, response}

        {:error, reason} = error ->
          ObservLib.Traces.set_status(:error, inspect(reason))
          error
      end
    end)
  end
end
```

## Structured Logging Patterns

### Request Logging with Context

```elixir
defmodule MyAppWeb.Plugs.RequestLogger do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    request_id = get_req_header(conn, "x-request-id") |> List.first() || generate_id()

    ObservLib.Logs.with_context(%{request_id: request_id}, fn ->
      ObservLib.Logs.info("Request started", %{
        method: conn.method,
        path: conn.request_path
      })

      conn
    end)
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
```

### Error Logging with Traces

```elixir
def process_with_logging(data) do
  ObservLib.traced("process_data", fn ->
    case validate(data) do
      :ok ->
        ObservLib.Logs.debug("Validation passed")
        transform(data)

      {:error, errors} ->
        ObservLib.Logs.warn("Validation failed", errors: errors)
        ObservLib.Traces.set_status(:error, "Validation failed")
        {:error, :validation_failed}
    end
  end)
end
```

## Best Practices

1. **Use semantic conventions** for attribute names (e.g., `http.method`, `db.system`)
2. **Keep cardinality low** - avoid high-cardinality attributes like user IDs in metrics
3. **Use `with_span`** over manual start/end when possible
4. **Add context early** - use `with_context` at request boundaries
5. **Be consistent** - use the same attribute names across your application
