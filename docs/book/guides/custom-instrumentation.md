# Custom Instrumentation

This guide covers advanced patterns for instrumenting your Elixir applications with ObservLib.

> **Note:** This page links to the [full custom instrumentation guide](../../../guides/custom-instrumentation.md) in the repository root.

## Quick Links

- [Manual Span Management](#manual-span-management)
- [Context Propagation](#context-propagation)
- [Custom Metrics](#custom-metrics)
- [Error Recording](#error-recording)
- [Performance Patterns](#performance-patterns)

## Manual Span Management

For fine-grained control over spans:

```elixir
defmodule MyApp.Worker do
  def process_job(job) do
    # Start span
    span = ObservLib.Traces.start_span(
      "process_job",
      %{"job.id" => job.id, "job.type" => job.type}
    )

    try do
      result = do_work(job)

      # Add attributes dynamically
      ObservLib.Traces.set_attribute("result.status", "success")
      ObservLib.Traces.set_attribute("result.records", length(result))

      result
    rescue
      error ->
        # Record exception
        ObservLib.Traces.record_exception(error)
        ObservLib.Traces.set_status(:error, "Job processing failed")
        reraise error, __STACKTRACE__
    after
      # Always end span
      ObservLib.Traces.end_span(span)
    end
  end
end
```


## Cross-Process Tracing

### Same-Process Spans

Spans automatically nest within the same process:

```elixir
ObservLib.traced("parent", fn ->
  # This creates a child span
  ObservLib.traced("child_1", fn ->
    # Work
  end)

  ObservLib.traced("child_2", fn ->
    # More work
  end)
end)
```

Result: `parent` span with two children.

### Cross-Process Spans

> **See Also:** [Context Propagation Guide](../concepts/context-propagation.md) for comprehensive coverage of cross-process tracing patterns.

When spawning processes or calling GenServers, trace context must be manually propagated:

**Task.async Pattern:**

```elixir
ObservLib.traced("parent", fn ->
  # Capture context before spawning
  ctx = :otel_ctx.get_current()

  task = Task.async(fn ->
    # Attach context in child process
    :otel_ctx.attach(ctx)

    ObservLib.traced("async_work", fn ->
      expensive_operation()
    end)
  end)

  Task.await(task)
end)
```

**GenServer Pattern:**

```elixir
defmodule MyApp.Worker do
  use GenServer

  def process(data) do
    # Capture context in caller
    ctx = :otel_ctx.get_current()
    GenServer.call(__MODULE__, {:process, data, ctx})
  end

  def handle_call({:process, data, ctx}, _from, state) do
    # Attach context in GenServer process
    :otel_ctx.attach(ctx)

    result = ObservLib.traced("worker_process", fn ->
      do_work(data)
    end)

    {:reply, result, state}
  end
end
```

For more patterns including spawn, GenServer cast, and reusable helpers, see the [Context Propagation Guide](../concepts/context-propagation.md).

### HTTP Propagation

For HTTP clients, inject W3C Trace Context headers:

```elixir
defmodule MyApp.HttpClient do
  def make_request(url) do
    ObservLib.traced("http_request", %{"http.url" => url}, fn ->
      headers = ObservLib.Traces.inject_headers([])

      case HTTPoison.get(url, headers) do
        {:ok, response} ->
          ObservLib.Traces.set_attribute("http.status_code", response.status_code)
          {:ok, response}

        {:error, reason} ->
          ObservLib.Traces.set_status(:error, "HTTP request failed")
          {:error, reason}
      end
    end)
  end
end
```

## Custom Metrics

### Metric Types

**Counter** - Monotonically increasing:
```elixir
ObservLib.counter("api.requests", 1, %{
  method: "GET",
  endpoint: "/users",
  status: 200
})
```

**Gauge** - Point-in-time value:
```elixir
ObservLib.gauge("queue.depth", Queue.size(), %{
  queue: "emails"
})
```

**Histogram** - Distribution:
```elixir
start = System.monotonic_time()
result = expensive_operation()
duration = System.monotonic_time() - start
          |> System.convert_time_unit(:native, :millisecond)

ObservLib.histogram("operation.duration_ms", duration, %{
  operation: "compute"
})
```

### Label Best Practices

✅ **Good labels** (low cardinality):
```elixir
%{
  method: "GET",           # ~10 values
  status: 200,             # ~20 values
  endpoint: "/users/:id"   # ~50 values
}
```

❌ **Bad labels** (high cardinality):
```elixir
%{
  user_id: 12345,          # Millions of values!
  request_id: "abc123",    # Unique per request
  timestamp: 1234567890    # Unbounded
}
```

**Rule of thumb:** Total label combinations should be < 10,000

### Periodic Metrics

Use telemetry_poller for periodic measurements:

```elixir
defmodule MyApp.Telemetry do
  def periodic_measurements do
    [
      {__MODULE__, :measure_queue_depth, []},
      {__MODULE__, :measure_cache_hit_rate, []}
    ]
  end

  def measure_queue_depth do
    depth = MyApp.Queue.size()
    ObservLib.gauge("queue.depth", depth)
  end

  def measure_cache_hit_rate do
    stats = MyApp.Cache.stats()
    rate = stats.hits / (stats.hits + stats.misses)
    ObservLib.gauge("cache.hit_rate", rate)
  end
end
```

## Error Recording

### With Spans

```elixir
ObservLib.traced("risky_operation", fn ->
  try do
    dangerous_work()
  rescue
    error ->
      # Record exception (adds span event)
      ObservLib.Traces.record_exception(error)

      # Set span status
      ObservLib.Traces.set_status(:error, Exception.message(error))

      # Log with context
      ObservLib.Logs.error("Operation failed",
        error: Exception.message(error),
        stacktrace: Exception.format_stacktrace(__STACKTRACE__)
      )

      reraise error, __STACKTRACE__
  end
end)
```

### With Metrics

```elixir
def handle_request(request) do
  case process(request) do
    {:ok, result} ->
      ObservLib.counter("requests.processed", 1, %{status: "success"})
      {:ok, result}

    {:error, :validation_error} ->
      ObservLib.counter("requests.processed", 1, %{status: "validation_error"})
      {:error, :validation_error}

    {:error, :timeout} ->
      ObservLib.counter("requests.processed", 1, %{status: "timeout"})
      {:error, :timeout}
  end
end
```

## Performance Patterns

### Conditional Instrumentation

Only instrument in production:

```elixir
defmodule MyApp.OptionalTracing do
  @trace Mix.env() == :prod

  def process(data) do
    if @trace do
      ObservLib.traced("process", fn -> do_work(data) end)
    else
      do_work(data)
    end
  end
end
```

### Sampling

Sample high-frequency operations:

```elixir
def log_cache_access(key) do
  # Only log 1% of cache accesses
  if :rand.uniform(100) == 1 do
    ObservLib.Logs.debug("Cache accessed", key: key)
  end
end
```

### Batch Recording

Batch metrics instead of recording individually:

```elixir
# Bad: Records 1000 metric operations
Enum.each(items, fn item ->
  ObservLib.counter("items.processed", 1)
end)

# Good: Single metric operation
count = length(items)
ObservLib.counter("items.processed", count)
```

## Testing Instrumented Code

Instrumentation should not affect tests:

```elixir
defmodule MyAppTest do
  use ExUnit.Case

  test "processes data correctly" do
    # Instrumentation is transparent
    result = MyApp.process_data([1, 2, 3])
    assert result == [2, 4, 6]

    # Optionally verify metrics (advanced)
    # metrics = ObservLib.Metrics.get_all()
    # assert metrics["items.processed"] == 3
  end
end
```

## Complete Example

See the [full custom instrumentation guide](../../../guides/custom-instrumentation.md) for comprehensive examples including:
- Background job instrumentation
- Database query patterns
- HTTP client instrumentation
- Event-driven architectures
- Multi-tenant applications

## API Reference

- [ObservLib.Traces](https://hexdocs.pm/observlib/ObservLib.Traces.html)
- [ObservLib.Metrics](https://hexdocs.pm/observlib/ObservLib.Metrics.html)
- [ObservLib.Logs](https://hexdocs.pm/observlib/ObservLib.Logs.html)

## Next Steps

- [Compile-time Instrumentation](traced-macro.md) - Use @traced for zero-overhead tracing
- [Phoenix Integration](../integrations/phoenix.md) - Instrument Phoenix apps
- [Performance Tuning](../deployment/performance.md) - Optimize for production
