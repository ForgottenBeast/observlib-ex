# Architecture Overview

ObservLib is built on OTP principles with proper supervision trees and process-based state management.

## High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     ObservLib.Application                    │
│                    (Main Supervisor)                         │
└──────────────┬──────────────┬──────────────┬────────────────┘
               │              │              │
       ┌───────▼──────┐ ┌────▼─────┐ ┌─────▼──────┐
       │   Traces     │ │ Metrics  │ │   Logs     │
       │  Supervisor  │ │Supervisor│ │ Supervisor │
       └───────┬──────┘ └────┬─────┘ └─────┬──────┘
               │              │              │
    ┌──────────┴─────┐  ┌────┴─────┐  ┌────┴─────┐
    │                │  │          │  │          │
┌───▼────┐   ┌──────▼──▼──┐  ┌────▼──▼──┐  ┌────▼────┐
│Provider│   │Pyroscope    │  │Meter     │  │Backend  │
│        │   │Processor    │  │Provider  │  │         │
└────────┘   └─────────────┘  └──────────┘  └─────────┘
     │             │                │             │
     │             │                │             │
┌────▼─────────────▼────────────────▼─────────────▼─────┐
│                  OpenTelemetry SDK                     │
│            (Spans, Metrics, Logs)                      │
└────────────────────────┬───────────────────────────────┘
                         │
                ┌────────▼────────┐
                │  OTLP Exporter  │
                │   (HTTP/gRPC)   │
                └────────┬────────┘
                         │
            ┌────────────▼────────────┐
            │   Observability Stack   │
            │ (Jaeger, Grafana, etc.) │
            └─────────────────────────┘
```

## Component Breakdown

### Application Supervisor

The root supervisor (`ObservLib.Application`) uses a **one-for-one** strategy:

```elixir
children = [
  ObservLib.Config,                    # Configuration GenServer
  ObservLib.Traces.Supervisor,         # Traces subsystem
  ObservLib.Metrics.Supervisor,        # Metrics subsystem
  ObservLib.Logs.Supervisor,           # Logs subsystem
  {ObservLib.Pyroscope.Client, []}     # Optional profiling
]
```

If one subsystem crashes, others continue operating.

### Traces Subsystem

**Supervision Strategy:** One-for-one

```
ObservLib.Traces.Supervisor
├── ObservLib.Traces.Provider (GenServer)
│   └── ETS: :observlib_active_spans
└── ObservLib.Traces.PyroscopeProcessor (GenServer, optional)
    └── ETS: :observlib_pyroscope_profiles
```

**Key Components:**

- **Provider**: Manages span lifecycle, tracks active spans in ETS
- **PyroscopeProcessor**: Span processor for profile correlation

**Data Flow:**
1. User calls `ObservLib.traced/2` or `ObservLib.Traces.start_span/2`
2. Provider creates OpenTelemetry span via `:opentelemetry` SDK
3. Span context stored in ETS for cross-process access
4. On span end, context removed and span exported via OTLP

### Metrics Subsystem

**Supervision Strategy:** Rest-for-one (critical ordering!)

```
ObservLib.Metrics.Supervisor
├── ObservLib.Metrics.MeterProvider (GenServer)
│   ├── ETS: :observlib_metrics (metric values)
│   └── ETS: :observlib_metric_registry (metric definitions)
├── ObservLib.Metrics.PrometheusReader (GenServer)
│   └── TCP: Port 9568 (Prometheus scraping)
└── ObservLib.Metrics.OtlpMetricsExporter (GenServer)
    └── HTTP: OTLP export
```

**Why rest-for-one?**

If `MeterProvider` crashes, all metrics are lost. Exporters must restart to re-read the new metric state. Rest-for-one ensures dependent services restart together.

**Data Flow:**
1. User calls `ObservLib.counter/3`, `ObservLib.gauge/3`, or `ObservLib.histogram/3`
2. MeterProvider updates ETS tables atomically
3. PrometheusReader reads from ETS on HTTP scrape
4. OtlpMetricsExporter periodically batches and exports via OTLP

### Logs Subsystem

**Supervision Strategy:** One-for-one

```
ObservLib.Logs.Supervisor
├── ObservLib.Logs.Backend (Erlang :logger handler)
└── ObservLib.Logs.OtlpLogsExporter (GenServer)
```

**Data Flow:**
1. User calls `ObservLib.Logs.info/2` (or any log level)
2. Elixir `Logger` emits log event
3. Backend handler intercepts, injects trace context
4. Log forwarded to OpenTelemetry SDK
5. OtlpLogsExporter batches and exports via OTLP

### Configuration Management

`ObservLib.Config` is a GenServer that:
- Reads application environment on startup
- Provides runtime configuration access
- Supports dynamic updates (optional)

## ETS Tables

ObservLib uses ETS for cross-process data sharing:

| Table | Type | Owner | Purpose |
|-------|------|-------|---------|
| `:observlib_active_spans` | `set` | Traces.Provider | Track active spans by process |
| `:observlib_pyroscope_profiles` | `set` | Traces.PyroscopeProcessor | Correlate spans with profiles |
| `:observlib_metrics` | `set` | Metrics.MeterProvider | Store metric values |
| `:observlib_metric_registry` | `set` | Metrics.MeterProvider | Store metric metadata |

All tables use `public` read access with `protected` write access for safe concurrent reads.

## Process-Level Instrumentation

ObservLib avoids the process dictionary for span tracking. Instead:

1. Spans created via `:opentelemetry` SDK (which uses process dictionary internally)
2. Additional metadata stored in ETS, keyed by span context
3. Process crashes don't leak span data (ETS cleanup via monitor)

## Concurrency Model

- **GenServers**: Synchronous configuration access, asynchronous metric recording
- **ETS**: Lock-free reads for metrics and span lookup
- **Atomic Operations**: Counter increments use `:ets.update_counter/3`
- **No Bottlenecks**: No single process handles all telemetry

## Error Handling

Each subsystem has proper error handling:

- **Traces**: Span creation errors logged, don't crash provider
- **Metrics**: Invalid metric operations return `{:error, reason}`
- **Logs**: Backend failures don't crash logger
- **Export**: Network errors trigger retry with exponential backoff

## Performance Characteristics

| Operation | Latency | Notes |
|-----------|---------|-------|
| `ObservLib.counter/3` | ~1μs | ETS atomic update |
| `ObservLib.traced/2` | ~10μs | Span creation overhead |
| `ObservLib.Logs.info/2` | ~5μs | Logger overhead |
| Prometheus scrape | ~1ms | Read from ETS, no computation |
| OTLP export | ~10-50ms | Batched HTTP request |

## Memory Usage

Approximate memory per signal:

- **Span**: 200-500 bytes (depends on attributes)
- **Metric**: 100-200 bytes (per unique label set)
- **Log**: 300-800 bytes (depends on message size)

Batching and export keep memory bounded.

## Next Steps

- [OpenTelemetry Primer](opentelemetry.md) - Learn OpenTelemetry concepts
- [Supervision Trees](supervision.md) - Deep dive into OTP supervision
- [Context Propagation](context-propagation.md) - How traces flow across processes
