# ObservLib Phases 3-9 Implementation Plan

**Date:** 2026-03-27
**Scope:** 27 tasks across 7 phases, ~18 new files, ~12 modified files
**Estimated Complexity:** HIGH
**Recommended Workers:** 3 (parallel tracks below)

---

## Context

### Current State (Phases 1-2 Complete)

The codebase has a working foundation:

- **ObservLib** (`lib/observlib.ex`) -- Top-level convenience API delegating to Traces, Metrics, Logs
- **ObservLib.Application** (`lib/observlib/application.ex`) -- OTP Application with `one_for_one` supervisor, starts Config GenServer and exporters ad-hoc (not supervised)
- **ObservLib.Config** (`lib/observlib/config.ex`) -- GenServer holding all configuration, reads from Application env
- **ObservLib.Traces** (`lib/observlib/traces.ex`) -- Thin wrapper around `:otel_tracer`/`:otel_span` (no GenServer, no supervision)
- **ObservLib.Metrics** (`lib/observlib/metrics.ex`) -- Emits `:telemetry` events, process dictionary registry (no ETS, no GenServer)
- **ObservLib.Logs** (`lib/observlib/logs.ex`) -- Wraps `Logger.log/3` with context, Erlang `:logger` handler attachment
- **ObservLib.Telemetry** (`lib/observlib/telemetry.ex`) -- Bridges `:telemetry` events to OTel spans
- **Exporters** -- Three exporters exist: OtlpTraceExporter (config-only, no GenServer), OtlpMetricsExporter (GenServer), OtlpLogsExporter (GenServer). Metrics and Logs exporters use `Req` for HTTP and are started ad-hoc in Application.start, not under supervision.

### Key Dependencies

```
opentelemetry_api ~> 1.2
opentelemetry ~> 1.3
opentelemetry_exporter ~> 1.6
opentelemetry_telemetry ~> 1.0
telemetry ~> 1.2
telemetry_metrics ~> 0.6
telemetry_poller ~> 1.0
jason ~> 1.4
req ~> 0.4
```

### Architecture Decisions Already Made

1. Config is a named GenServer (`ObservLib.Config`)
2. Metrics API emits `:telemetry` events (not direct ETS writes)
3. OTLP export uses `Req` HTTP client (not gRPC)
4. Trace exporter delegates to `:opentelemetry_exporter` (Erlang)
5. Metrics/Logs exporters are custom GenServers with batch+retry

### Critical Issues in Current Code

1. **Exporters are not supervised** -- OtlpMetricsExporter and OtlpLogsExporter are started with `start_link` but not added to supervision tree. If they crash, they stay dead.
2. **Metrics registry uses process dictionary** -- `ObservLib.Metrics.list_registered_metrics()` stores in calling process's dictionary, making it useless across processes. Phase 4 must replace this with ETS.
3. **Telemetry handler for metrics uses wrong event prefix** -- OtlpMetricsExporter attaches to `[:observlib, :metrics]` but `ObservLib.Metrics.counter/3` emits events like `[:http, :requests]` (from name normalization). These never match.

---

## Work Objectives

1. Add proper OTP supervision trees for Traces, Metrics, and Logs subsystems
2. Implement GenServer-backed providers for span management and metric collection (ETS)
3. Add Prometheus scrape endpoint for metrics
4. Add Logger backend for structured log capture with OTLP forwarding
5. Implement `@traced` macro for function decoration
6. Build Pyroscope HTTP client for continuous profiling
7. End-to-end integration tests with mock OTLP server
8. User-facing documentation

---

## Guardrails

### MUST Have
- All new GenServers must be under a Supervisor (never ad-hoc `start_link`)
- ETS tables owned by their parent GenServer (crash recovery via supervisor)
- All public functions have `@spec` and `@doc`
- Tests for every new module (unit) + integration tests for supervision trees
- Backward compatibility: existing `ObservLib.Traces.with_span/3`, `ObservLib.Metrics.counter/3`, `ObservLib.Logs.log/3` APIs must continue to work

### MUST NOT Have
- No new dependencies (use existing: `req`, `jason`, `telemetry`, `opentelemetry_*`)
- No breaking changes to existing public API
- No ETS tables without a clear owner process
- No blocking calls in hot paths (metric recording, log emission)
- No hard-coded endpoints (everything through Config)

---

## Supervision Tree Architecture

```
ObservLib.Supervisor (one_for_one)
  |-- ObservLib.Config (GenServer)
  |-- ObservLib.Traces.Supervisor (one_for_one)
  |     |-- ObservLib.Traces.Provider (GenServer, owns ETS for active spans)
  |     |-- ObservLib.Traces.PyroscopeProcessor (GenServer, optional)
  |     |-- ObservLib.Exporters.OtlpTraceExporter (worker, config-only)
  |-- ObservLib.Metrics.Supervisor (one_for_one)
  |     |-- ObservLib.Metrics.MeterProvider (GenServer, owns ETS for metrics)
  |     |-- ObservLib.Metrics.PrometheusReader (GenServer, HTTP endpoint)
  |     |-- ObservLib.Exporters.OtlpMetricsExporter (GenServer)
  |-- ObservLib.Logs.Supervisor (one_for_one)
  |     |-- ObservLib.Logs.Backend (gen_event / Logger backend)
  |     |-- ObservLib.Exporters.OtlpLogsExporter (GenServer)
  |-- ObservLib.Pyroscope.Client (GenServer, optional)
```

---

## Task Flow (Dependency Graph)

```
Phase 3 (Traces)  ----+
                      |
Phase 4 (Metrics) ----+--> Phase 6 (Traced Macro) --> Phase 8 (Integration Tests)
                      |                                       |
Phase 5 (Logs)    ----+                                       v
                      |                              Phase 9 (Documentation)
Phase 7 (Pyroscope) --+
```

**Parallel tracks:**
- Track A: Phases 3 + 6 (Traces, then Traced Macro)
- Track B: Phase 4 (Metrics -- independent)
- Track C: Phases 5 + 7 (Logs, then Pyroscope -- Pyroscope needs log context)
- Merge: Phases 8 + 9 (after all tracks complete)

---

## Phase 3: Traces Module

**Complexity:** MEDIUM
**Files to create:** 3
**Files to modify:** 2
**Estimated effort:** ~4 hours

### Task 3.1: Traces.Supervisor

**File:** `lib/observlib/traces/supervisor.ex`

Create a Supervisor that manages the tracing subsystem.

**Implementation:**
- `use Supervisor`
- Children: `[Traces.Provider]` (PyroscopeProcessor added conditionally based on config)
- Strategy: `:one_for_one`
- `child_spec/1` so it can be added to ObservLib.Supervisor

**Acceptance Criteria:**
- [ ] Supervisor starts successfully under ObservLib.Supervisor
- [ ] Restarts Traces.Provider on crash
- [ ] Conditionally starts PyroscopeProcessor only when `pyroscope_endpoint` is configured
- [ ] Test: supervisor starts with default config
- [ ] Test: child process restart verified

### Task 3.2: Traces.Provider

**File:** `lib/observlib/traces/provider.ex`

GenServer managing span lifecycle with optional ETS-backed active span tracking.

**Implementation:**
- `use GenServer`, named `ObservLib.Traces.Provider`
- On `init/1`: create ETS table `:observlib_active_spans` (`:set`, `:public` for read, `:protected` for write)
- API: `start_span/2`, `end_span/1`, `get_active_spans/0`, `get_span/1`
- Spans delegate to `:otel_tracer` (existing pattern) but also track in ETS for observability
- `handle_info(:cleanup, state)` -- periodic cleanup of stale spans (configurable timeout)
- On `terminate/2`: flush active spans, delete ETS table

**Acceptance Criteria:**
- [ ] Provider starts under Traces.Supervisor
- [ ] `start_span/2` creates OTel span AND tracks in ETS
- [ ] `end_span/1` ends OTel span AND removes from ETS
- [ ] `get_active_spans/0` returns list of active spans from ETS
- [ ] Stale span cleanup runs on configurable interval
- [ ] ETS table is cleaned up on terminate
- [ ] Test: span lifecycle (start -> end -> verify removed from ETS)
- [ ] Test: concurrent span tracking (multiple processes)

### Task 3.3: Traces.PyroscopeProcessor

**File:** `lib/observlib/traces/pyroscope_processor.ex`

GenServer that attaches profiling data to spans for Pyroscope correlation.

**Implementation:**
- `use GenServer`, named `ObservLib.Traces.PyroscopeProcessor`
- On `init/1`: read `pyroscope_endpoint` and `pyroscope_sample_rate` from Config
- API: `attach_profile/2` (span_id, profile_data), `get_profile/1` (span_id)
- Links span IDs to profiling labels for Pyroscope
- Only started when Pyroscope is configured (conditional child in Traces.Supervisor)

**Acceptance Criteria:**
- [ ] Starts only when `pyroscope_endpoint` is configured
- [ ] Links profiling labels to span context
- [ ] Test: profile attachment and retrieval
- [ ] Test: not started when pyroscope_endpoint is nil

### Task 3.4: Wire Traces.Supervisor into Application

**File:** `lib/observlib/application.ex` (modify)

**Implementation:**
- Add `{ObservLib.Traces.Supervisor, []}` to children list
- Move OtlpTraceExporter setup into Traces.Supervisor (remove ad-hoc setup from Application)

**Acceptance Criteria:**
- [ ] Application starts with Traces.Supervisor in supervision tree
- [ ] Existing `ObservLib.Traces.with_span/3` still works
- [ ] Existing tests pass without modification

---

## Phase 4: Metrics Module

**Complexity:** HIGH
**Files to create:** 3
**Files to modify:** 2
**Estimated effort:** ~6 hours

### Task 4.1: Metrics.Supervisor

**File:** `lib/observlib/metrics/supervisor.ex`

**Implementation:**
- `use Supervisor`
- Children: `[Metrics.MeterProvider, Metrics.PrometheusReader, OtlpMetricsExporter]`
- Strategy: `:rest_for_one` (MeterProvider must be alive for others)
- PrometheusReader started conditionally based on config

**Acceptance Criteria:**
- [ ] Supervisor starts under ObservLib.Supervisor
- [ ] Uses `:rest_for_one` strategy (MeterProvider restart cascades)
- [ ] Test: supervisor start, child process enumeration

### Task 4.2: Metrics.MeterProvider

**File:** `lib/observlib/metrics/meter_provider.ex`

GenServer owning ETS tables for metric storage and aggregation. This is the core of the metrics subsystem.

**Implementation:**
- `use GenServer`, named `ObservLib.Metrics.MeterProvider`
- On `init/1`:
  - Create ETS table `:observlib_metrics` (`:set`, `:public` read, write via GenServer cast)
  - Create ETS table `:observlib_metric_registry` (`:set`, replaces process dictionary registry)
  - Attach `:telemetry` handler that writes directly to ETS (fix current broken handler pattern)
- API:
  - `register/3` (name, type, opts) -- register metric definition in registry ETS
  - `record/4` (name, type, value, attributes) -- write to metrics ETS (called from telemetry handler)
  - `read_all/0` -- read all current metric values from ETS
  - `read/1` (name) -- read specific metric
  - `reset/0` -- clear all metrics (for testing / export flush)
- Aggregation logic:
  - Counter: `:ets.update_counter` for atomic increment
  - Gauge: `:ets.insert` (last value wins)
  - Histogram: maintain running count, sum, min, max, bucket counts
  - UpDownCounter: `:ets.update_counter` (allows negative)
- Periodic export trigger via `Process.send_after(:export, interval)`

**Acceptance Criteria:**
- [ ] MeterProvider owns ETS tables (tables die with process, recreated on restart)
- [ ] `register/3` stores metric definitions in registry ETS
- [ ] Counter aggregation uses atomic ETS operations
- [ ] Histogram maintains proper statistical aggregation
- [ ] `read_all/0` returns all metrics in a consistent format
- [ ] Telemetry handler correctly routes all `ObservLib.Metrics.*` calls to ETS
- [ ] Test: register metric, record values, read back aggregated result
- [ ] Test: concurrent writes from multiple processes
- [ ] Test: histogram bucket calculation
- [ ] Test: ETS cleanup on process termination

### Task 4.3: Metrics.PrometheusReader

**File:** `lib/observlib/metrics/prometheus_reader.ex`

GenServer that serves a Prometheus-compatible scrape endpoint.

**Implementation:**
- `use GenServer`, named `ObservLib.Metrics.PrometheusReader`
- On `init/1`: start a simple TCP listener (`:gen_tcp`) or use `Plug` if available
- Since no Plug/Phoenix dependency, use `:gen_tcp` + manual HTTP response
- Listen on configurable port (default 9568, config key `:prometheus_port`)
- On scrape request: call `MeterProvider.read_all/0`, format as Prometheus text
- Format: `# HELP`, `# TYPE`, `metric_name{label="value"} value timestamp`

**Acceptance Criteria:**
- [ ] Starts TCP listener on configured port
- [ ] Responds to `GET /metrics` with Prometheus text format
- [ ] Counter -> `counter` type, Gauge -> `gauge` type, Histogram -> `histogram` type
- [ ] Labels from metric attributes formatted correctly
- [ ] Returns 404 for non-metrics paths
- [ ] Test: format output matches Prometheus spec
- [ ] Test: scrape returns registered metrics with correct values

### Task 4.4: Wire Metrics.Supervisor into Application + Fix Metrics Module

**Files:** `lib/observlib/application.ex` (modify), `lib/observlib/metrics.ex` (modify)

**Implementation:**
- Add `{ObservLib.Metrics.Supervisor, []}` to children list in Application
- Move OtlpMetricsExporter into Metrics.Supervisor (remove ad-hoc start)
- Update `ObservLib.Metrics.counter/3` etc. to also call `MeterProvider.record/4` (in addition to `:telemetry.execute` for backward compat)
- Replace process dictionary registry with delegation to `MeterProvider.register/3`
- Fix the broken telemetry handler event matching

**Acceptance Criteria:**
- [ ] Application starts with Metrics.Supervisor
- [ ] `ObservLib.Metrics.counter/3` records to both telemetry and ETS
- [ ] `ObservLib.Metrics.list_registered_metrics/0` reads from ETS (works cross-process)
- [ ] Existing metrics tests pass
- [ ] OtlpMetricsExporter reads from MeterProvider instead of its own internal state

---

## Phase 5: Logs Module

**Complexity:** MEDIUM
**Files to create:** 2
**Files to modify:** 2
**Estimated effort:** ~4 hours

### Task 5.1: Logs.Supervisor

**File:** `lib/observlib/logs/supervisor.ex`

**Implementation:**
- `use Supervisor`
- Children: `[Logs.Backend, OtlpLogsExporter]`
- Strategy: `:one_for_one`

**Acceptance Criteria:**
- [ ] Supervisor starts under ObservLib.Supervisor
- [ ] Test: supervisor start and child enumeration

### Task 5.2: Logs.Backend

**File:** `lib/observlib/logs/backend.ex`

Logger backend (`:gen_event` handler) that captures Elixir Logger output and forwards structured log records to the OtlpLogsExporter for OTLP export.

**Implementation:**
- Implement `:gen_event` behaviour (Logger backend pattern)
- `init/1`: read config, set up state with log level filter
- `handle_event/2`:
  - Receive `{level, group_leader, {Logger, message, timestamp, metadata}}`
  - Filter by configured log level
  - Build structured log record: `%{level:, message:, timestamp:, attributes: metadata}`
  - Forward to `OtlpLogsExporter.add_to_batch/1`
- `handle_call({:configure, opts}, state)`: runtime reconfiguration
- Support for trace context injection (extract span_id/trace_id from process dictionary if available)
- Register as Logger backend: `Logger.add_backend(ObservLib.Logs.Backend)`

**Acceptance Criteria:**
- [ ] Captures Logger events and converts to structured log records
- [ ] Filters by log level
- [ ] Extracts trace context (span_id, trace_id) from OTel process context when available
- [ ] Forwards log records to OtlpLogsExporter batch queue
- [ ] Test: log capture with correct level, message, metadata
- [ ] Test: trace context injection
- [ ] Test: log level filtering

### Task 5.3: Wire Logs.Supervisor into Application

**File:** `lib/observlib/application.ex` (modify)

**Implementation:**
- Add `{ObservLib.Logs.Supervisor, []}` to children list
- Move OtlpLogsExporter into Logs.Supervisor
- Remove ad-hoc `start_logs_exporter/0` from Application
- Add Logger backend registration after supervisor starts

**Acceptance Criteria:**
- [ ] Application starts with Logs.Supervisor
- [ ] OtlpLogsExporter is properly supervised
- [ ] Logger backend is registered during startup
- [ ] Existing `ObservLib.Logs.log/3` still works
- [ ] Existing logs tests pass

---

## Phase 6: Traced Macro

**Complexity:** HIGH
**Files to create:** 1
**Files to modify:** 0
**Estimated effort:** ~5 hours

### Task 6.1: ObservLib.Traced Macro

**File:** `lib/observlib/traced.ex`

Macro module that enables function decoration with automatic span creation via `@traced` attribute or `use ObservLib.Traced`.

**Implementation:**

Two usage patterns:

**Pattern A: Module-level `use`**
```elixir
defmodule MyApp.UserService do
  use ObservLib.Traced

  @traced attributes: %{"service" => "users"}
  def get_user(id) do
    # automatically wrapped in a span named "MyApp.UserService.get_user/1"
  end
end
```

**Pattern B: Explicit wrapping**
```elixir
defmodule MyApp.Worker do
  import ObservLib.Traced

  def process(item) do
    traced "process_item", %{item_id: item.id} do
      # block is wrapped in span
    end
  end
end
```

**AST Manipulation Strategy:**
- `__using__/1` macro: inject `@on_definition {ObservLib.Traced, :__on_definition__}` and `@before_compile {ObservLib.Traced, :__before_compile__}`
- `__on_definition__/6` callback: collect functions marked with `@traced` attribute into module accumulator
- `__before_compile__/1` callback: rewrite collected function bodies to wrap in `ObservLib.Traces.with_span/3`
- `traced/3` macro (for Pattern B): simple AST transform wrapping block in `with_span`
- Span name: `"#{module}.#{function}/#{arity}"` by default, overridable via `@traced name: "custom"`
- Attributes: merged from `@traced attributes: %{}` and runtime attributes

**Edge Cases:**
- Multiple function clauses with pattern matching (each clause gets wrapped)
- Functions with guards
- Private functions (support `@traced` on `defp` too)
- Macro hygiene (avoid variable capture)
- Compile-time validation of `@traced` options

**Acceptance Criteria:**
- [ ] `use ObservLib.Traced` + `@traced` decorates functions with spans
- [ ] Span name defaults to `Module.function/arity`
- [ ] Custom span name via `@traced name: "custom"`
- [ ] Static attributes via `@traced attributes: %{}`
- [ ] Works with multi-clause functions
- [ ] Works with guard clauses
- [ ] Works with `defp` private functions
- [ ] `traced/3` macro works for inline block wrapping
- [ ] Exception in decorated function sets span status to error and re-raises
- [ ] Test: basic decoration
- [ ] Test: multi-clause function
- [ ] Test: guard clause function
- [ ] Test: private function decoration
- [ ] Test: exception handling preserves span error status
- [ ] Test: custom name and attributes

---

## Phase 7: Pyroscope Integration

**Complexity:** MEDIUM
**Files to create:** 1
**Files to modify:** 1
**Estimated effort:** ~3 hours

### Task 7.1: Pyroscope.Client

**File:** `lib/observlib/pyroscope/client.ex`

GenServer that periodically sends profiling data to Pyroscope.

**Implementation:**
- `use GenServer`, named `ObservLib.Pyroscope.Client`
- On `init/1`:
  - Read `pyroscope_endpoint`, `pyroscope_sample_rate` from Config
  - If no endpoint configured, log warning and operate in disabled mode
  - Schedule first profile collection via `Process.send_after`
- Profiling data collection:
  - Use `:erlang.process_info/2` with `:current_stacktrace` for stack sampling
  - Collect from all processes or configurable process list
  - Sample at configured rate (default: every 5 seconds from config)
- HTTP upload:
  - POST to `{endpoint}/ingest` with `Content-Type: application/octet-stream`
  - Include labels: `service_name`, `spy_name: "elixir"`, custom tags from config
  - Use `Req` for HTTP (existing dependency)
- API: `add_labels/1`, `remove_labels/1`, `get_status/0`, `force_flush/0`

**Acceptance Criteria:**
- [ ] Client starts under ObservLib.Supervisor (conditional on pyroscope_endpoint config)
- [ ] Periodic stack sampling at configured rate
- [ ] HTTP upload to Pyroscope ingest endpoint
- [ ] Span correlation via labels (uses trace_id/span_id when available)
- [ ] Graceful degradation when Pyroscope is unreachable
- [ ] Test: client starts and schedules collection
- [ ] Test: stack sampling produces valid data
- [ ] Test: disabled mode when no endpoint configured

### Task 7.2: Wire Pyroscope.Client into Application

**File:** `lib/observlib/application.ex` (modify)

**Implementation:**
- Conditionally add `{ObservLib.Pyroscope.Client, []}` to children when `pyroscope_endpoint` is configured
- Wire up Traces.PyroscopeProcessor to communicate with Pyroscope.Client

**Acceptance Criteria:**
- [ ] Pyroscope.Client only starts when endpoint is configured
- [ ] Application starts normally without Pyroscope configured

---

## Phase 8: Integration & E2E Tests

**Complexity:** MEDIUM
**Files to create:** 4
**Files to modify:** 1
**Estimated effort:** ~5 hours

### Task 8.1: Mock OTLP Server

**File:** `test/support/mock_otlp_server.ex`

A simple GenServer that listens on a TCP port, accepts HTTP POST requests, and stores received OTLP payloads for assertion.

**Implementation:**
- Use `:gen_tcp` to listen on random available port
- Parse HTTP requests, store JSON bodies
- API: `start_link/0`, `get_traces/0`, `get_metrics/0`, `get_logs/0`, `reset/0`, `port/0`

**Acceptance Criteria:**
- [ ] Receives and stores OTLP trace, metrics, and log payloads
- [ ] Returns port for dynamic configuration
- [ ] Thread-safe for concurrent test access

### Task 8.2: Full Telemetry Pipeline Test

**File:** `test/observlib/integration/pipeline_test.exs`

**Implementation:**
- Start full ObservLib application with mock OTLP server
- Exercise: create span -> record metric -> emit log -> wait for export -> assert payloads received
- Test supervision tree recovery: kill Provider, verify restart and continued operation
- Test config reload: change endpoint, verify exports go to new endpoint

**Acceptance Criteria:**
- [ ] End-to-end: span created -> exported to mock server with correct format
- [ ] End-to-end: metric recorded -> exported with correct aggregation
- [ ] End-to-end: log emitted -> exported with trace context
- [ ] Supervision recovery: kill child -> restarts -> continues working
- [ ] Test: all three signal types flow through pipeline simultaneously

### Task 8.3: OTLP Export Tests

**File:** `test/observlib/integration/otlp_export_test.exs`

**Implementation:**
- Test each exporter against mock OTLP server
- Verify OTLP JSON format compliance
- Test retry logic (mock server returns 503 then 200)
- Test batch accumulation and flush

**Acceptance Criteria:**
- [ ] Trace export produces valid OTLP JSON
- [ ] Metrics export produces valid OTLP JSON with correct aggregation types
- [ ] Logs export produces valid OTLP JSON with severity mapping
- [ ] Retry logic works (exponential backoff)
- [ ] Batch flush on size threshold and timeout

### Task 8.4: Prometheus Scraping Tests

**File:** `test/observlib/integration/prometheus_test.exs`

**Implementation:**
- Start PrometheusReader, record metrics, scrape endpoint
- Verify Prometheus text format output
- Test all metric types (counter, gauge, histogram)

**Acceptance Criteria:**
- [ ] Scrape returns valid Prometheus text format
- [ ] Counter, gauge, histogram types formatted correctly
- [ ] Labels rendered correctly
- [ ] Empty metrics returns empty response (not error)

### Task 8.5: Update test_helper.exs

**File:** `test/test_helper.exs` (modify)

**Implementation:**
- Add `Code.require_file("support/mock_otlp_server.ex", __DIR__)`
- Configure test environment with mock server

**Acceptance Criteria:**
- [ ] Mock server available in all test modules
- [ ] Test suite runs clean with no port conflicts

---

## Phase 9: Documentation & Examples

**Complexity:** LOW
**Files to create:** 4
**Files to modify:** 1
**Estimated effort:** ~3 hours

### Task 9.1: Getting Started Guide

**File:** `guides/getting-started.md`

**Content:**
- Installation (mix dependency)
- Basic configuration (config.exs)
- Starting the application
- First trace, metric, and log
- Verifying with OTLP collector

### Task 9.2: Configuration Guide

**File:** `guides/configuration.md`

**Content:**
- All config keys with types, defaults, and descriptions
- Environment variable mapping (runtime.exs)
- Per-signal endpoint configuration
- Prometheus endpoint setup
- Pyroscope integration setup

### Task 9.3: Custom Instrumentation Guide

**File:** `guides/custom-instrumentation.md`

**Content:**
- Using `@traced` macro
- Manual span creation
- Recording custom metrics
- Structured logging with context
- Correlating traces, metrics, and logs

### Task 9.4: Example Scripts

**File:** `examples/basic_usage.exs`

**Content:**
- Standalone script demonstrating all ObservLib features
- Docker compose with OTLP collector for testing

### Task 9.5: Update mix.exs for docs

**File:** `mix.exs` (modify)

**Implementation:**
- Add `docs` config to `project/0` with `extras: ["guides/*.md"]`
- Add `groups_for_modules` organizing modules by subsystem

**Acceptance Criteria:**
- [ ] `mix docs` generates documentation with guides
- [ ] All public modules have complete `@moduledoc` and `@doc`
- [ ] Example scripts run successfully

---

## Success Criteria (Overall)

1. **Supervision tree is complete** -- All GenServers are supervised, crash recovery works
2. **Metrics use ETS** -- No more process dictionary; cross-process reads work
3. **Exporters are supervised** -- OtlpMetricsExporter and OtlpLogsExporter under their respective supervisors
4. **Prometheus endpoint works** -- `GET /metrics` returns valid Prometheus text
5. **Logger backend captures logs** -- Logger output forwarded to OTLP
6. **Traced macro works** -- `@traced` decorates functions with spans
7. **Pyroscope integration works** -- Stack sampling with span correlation
8. **Integration tests pass** -- Full pipeline tested end-to-end
9. **All existing tests still pass** -- No regressions

---

## Worker Allocation

### Track A (Worker 1): Traces + Traced Macro
- Phase 3: Tasks 3.1, 3.2, 3.3, 3.4 (sequential)
- Phase 6: Task 6.1 (depends on Phase 3)
- **Total:** ~9 hours

### Track B (Worker 2): Metrics
- Phase 4: Tasks 4.1, 4.2, 4.3, 4.4 (sequential)
- **Total:** ~6 hours

### Track C (Worker 3): Logs + Pyroscope
- Phase 5: Tasks 5.1, 5.2, 5.3 (sequential)
- Phase 7: Tasks 7.1, 7.2 (sequential, after Phase 5)
- **Total:** ~7 hours

### Merge Phase (All Workers): Integration + Docs
- Phase 8: Tasks 8.1-8.5 (Worker 1: pipeline test, Worker 2: OTLP/Prometheus tests, Worker 3: mock server)
- Phase 9: Tasks 9.1-9.5 (distribute among workers)
- **Total:** ~8 hours shared

---

## Task Dependency Matrix

| Task | Depends On | Blocks |
|------|-----------|--------|
| 3.1 Traces.Supervisor | Config (done) | 3.2, 3.3, 3.4 |
| 3.2 Traces.Provider | 3.1 | 3.4, 6.1 |
| 3.3 Traces.PyroscopeProcessor | 3.1 | 7.2 |
| 3.4 Wire Traces | 3.1, 3.2 | 8.2 |
| 4.1 Metrics.Supervisor | Config (done) | 4.2, 4.3, 4.4 |
| 4.2 Metrics.MeterProvider | 4.1 | 4.3, 4.4 |
| 4.3 Metrics.PrometheusReader | 4.2 | 8.4 |
| 4.4 Wire Metrics | 4.1, 4.2 | 8.2 |
| 5.1 Logs.Supervisor | Config (done) | 5.2, 5.3 |
| 5.2 Logs.Backend | 5.1 | 5.3 |
| 5.3 Wire Logs | 5.1, 5.2 | 8.2 |
| 6.1 Traced Macro | 3.2 | 8.2 |
| 7.1 Pyroscope.Client | Config (done) | 7.2 |
| 7.2 Wire Pyroscope | 7.1, 3.3 | 8.2 |
| 8.1 Mock OTLP Server | None | 8.2, 8.3, 8.4 |
| 8.2 Pipeline Test | 3.4, 4.4, 5.3, 6.1, 8.1 | 9.x |
| 8.3 OTLP Export Tests | 8.1 | 9.x |
| 8.4 Prometheus Tests | 4.3, 8.1 | 9.x |
| 8.5 test_helper update | 8.1 | 8.2, 8.3, 8.4 |
| 9.1-9.5 Documentation | 8.2, 8.3, 8.4 | None |

---

## Open Questions Carried Forward

See `.omc/plans/open-questions.md` for Phase 2 open questions that affect this plan.
