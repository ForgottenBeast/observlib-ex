# Continuous Profiling with Pyroscope

ObservLib integrates with [Pyroscope](https://pyroscope.io) to provide continuous profiling with automatic trace-profile correlation.

## What is Continuous Profiling?

Continuous profiling captures stack traces periodically to understand:
- Which functions consume the most CPU time
- Memory allocation patterns
- Performance bottlenecks in production

Unlike traditional profiling, continuous profiling runs in production with minimal overhead (<1% CPU).

## Setup

### 1. Start Pyroscope Server

Using Docker:

```bash
docker run -p 4040:4040 pyroscope/pyroscope:latest
```

Using Docker Compose:

```yaml
version: '3'
services:
  pyroscope:
    image: pyroscope/pyroscope:latest
    ports:
      - "4040:4040"
    environment:
      - PYROSCOPE_LOG_LEVEL=debug
```

### 2. Configure ObservLib

Add the Pyroscope endpoint to your configuration:

```elixir
# config/config.exs
config :observlib,
  service_name: "my_service",
  otlp_endpoint: "http://localhost:4318",
  pyroscope_endpoint: "http://localhost:4040"
```

That's it! ObservLib will automatically start profiling and correlating profiles with traces.

## How It Works

### Profile Collection

1. Every 5 seconds (configurable), `ObservLib.Pyroscope.Client` collects a profile
2. Profile captured via `:erlang.system_profile/2` and converted to Pyroscope format
3. Profile uploaded to Pyroscope server via HTTP

### Trace Correlation

When a span is active during profiling:
1. `ObservLib.Traces.PyroscopeProcessor` captures the span context
2. Span's trace_id and span_id attached to the profile as labels
3. Pyroscope UI can filter profiles by trace_id

### Example Flow

```elixir
# Start a traced operation
ObservLib.traced("expensive_computation", fn ->
  # This code is profiled
  Enum.reduce(1..1_000_000, 0, fn x, acc ->
    acc + compute_something(x)
  end)
end)
```

In Pyroscope UI:
1. Filter by service: `my_service`
2. See flame graph showing `expensive_computation` consuming CPU
3. Click on trace_id label to see the corresponding trace in Jaeger

## Configuration Options

```elixir
config :observlib,
  pyroscope_endpoint: "http://localhost:4040",
  pyroscope_app_name: "my_service",  # Defaults to service_name
  pyroscope_sample_rate: 100,        # Hz, defaults to 100
  pyroscope_upload_interval: 5000    # ms, defaults to 5000
```

## Manual Profiling

You can manually trigger profiling for specific code sections:

```elixir
# Start profiling
ObservLib.Pyroscope.Client.start_profiling()

# ... code to profile ...

# Stop and upload
profile = ObservLib.Pyroscope.Client.stop_profiling()
ObservLib.Pyroscope.Client.upload_profile(profile)
```

## Production Considerations

### Performance Impact

Continuous profiling has minimal overhead:
- **CPU**: ~0.5-1% overhead
- **Memory**: ~10-20MB for profile buffers
- **Network**: ~100KB/upload (every 5s = ~20KB/s)

### Sampling Rate

Adjust sampling rate based on your needs:

```elixir
config :observlib,
  pyroscope_sample_rate: 50  # Lower rate = less overhead
```

- **High rate (100Hz)**: Better accuracy, higher overhead
- **Low rate (10-50Hz)**: Lower overhead, less detail

### Upload Interval

Adjust upload frequency:

```elixir
config :observlib,
  pyroscope_upload_interval: 10_000  # Upload every 10s
```

- **Shorter interval**: More real-time visibility, more network traffic
- **Longer interval**: Less network traffic, delayed visibility

## Disabling Profiling

To disable profiling in certain environments:

```elixir
# config/test.exs
config :observlib,
  pyroscope_endpoint: nil  # Disables profiling
```

Or conditionally:

```elixir
# config/runtime.exs
config :observlib,
  pyroscope_endpoint:
    if System.get_env("ENABLE_PROFILING") == "true" do
      System.get_env("PYROSCOPE_ENDPOINT")
    else
      nil
    end
```

## Viewing Profiles

### Pyroscope UI

Access Pyroscope at http://localhost:4040

Features:
- **Flame graphs**: Visual CPU consumption
- **Timeline**: Historical profile data
- **Comparison**: Compare two time ranges
- **Filtering**: Filter by labels (trace_id, span_id)

### Filtering by Trace

In Pyroscope UI:
1. Select your application: `my_service`
2. Add label filter: `trace_id = <your-trace-id>`
3. See profiles only from that specific trace

### Common Patterns

**Find slow requests:**
1. In Jaeger, find slow traces
2. Copy trace_id
3. In Pyroscope, filter by trace_id
4. Analyze flame graph

**Find CPU hotspots:**
1. In Pyroscope, view overall flame graph
2. Find widest bars (most CPU time)
3. Drill down to specific functions

## Integration with Tracing

Profiles automatically include span context:

```elixir
defmodule MyApp.DataProcessor do
  use ObservLib.Traced

  @traced attributes: %{"operation" => "process"}
  def process_data(data) do
    # This function is:
    # 1. Traced (span created)
    # 2. Profiled (if Pyroscope enabled)
    # 3. Correlated (trace_id in profile labels)

    Enum.map(data, &expensive_transform/1)
  end
end
```

When analyzing performance:
1. See span duration in Jaeger
2. See flame graph in Pyroscope (filtered by trace_id)
3. Understand *why* the span was slow

## Example: Finding a Performance Issue

**Symptom:** API endpoint `/users` is slow (500ms P95)

**Investigation:**

1. **Find slow trace in Jaeger:**
   - Filter: `service=my_app AND http.route=/users AND duration > 500ms`
   - Copy trace_id: `a1b2c3d4e5f6...`

2. **Find profile in Pyroscope:**
   - Filter: `trace_id=a1b2c3d4e5f6...`
   - See flame graph

3. **Identify bottleneck:**
   - Flame graph shows `Repo.all(User)` taking 80% of CPU
   - Function `User.compute_stats/1` consuming most time

4. **Fix:**
   - Add database index
   - Cache computed stats
   - Re-deploy

5. **Verify:**
   - New traces show <100ms duration
   - Flame graph shows even distribution

## API Reference

See [ObservLib.Pyroscope.Client](https://hexdocs.pm/observlib/ObservLib.Pyroscope.Client.html) for detailed API documentation.

## Next Steps

- [Distributed Tracing](../guides/tracing.md) - Learn about traces
- [Performance Tuning](../deployment/performance.md) - Optimization tips
- [Pyroscope Documentation](https://pyroscope.io/docs/) - Official Pyroscope docs
