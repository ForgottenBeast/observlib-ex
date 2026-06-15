# Phase 2: Telemetry Foundation - Implementation Plan

**Beads issue:** `elixir_rs-19o` (Implement ObservLib.Telemetry) and `elixir_rs-29z` (Phase 2: Telemetry Foundation)
**Estimated effort:** 2h - LOW complexity
**Files to create:** `lib/observlib/telemetry.ex`, `test/observlib/telemetry_test.exs`
**Files to modify:** `lib/observlib/application.ex`, `.beads/issues.jsonl`

---

## Context

Phase 1 (Core Infrastructure) is complete. The project has:
- `ObservLib` facade module with convenience wrappers (`traced/3`, `counter/3`, `gauge/3`, `histogram/3`, `log/3`)
- `ObservLib.Config` GenServer reading from application environment
- `ObservLib.Application` supervision tree starting Config + OTLP exporters
- `ObservLib.Traces` wrapping `:otel_tracer` / `:otel_span` directly
- `ObservLib.Metrics` emitting events via `:telemetry.execute/3` with `normalize_event_name/1`
- `ObservLib.Logs` using Elixir `Logger` with context via process dictionary

Key dependencies already in `mix.exs`:
- `{:telemetry, "~> 1.2"}` - Erlang telemetry library
- `{:telemetry_metrics, "~> 0.6"}` - Metric definitions
- `{:telemetry_poller, "~> 1.0"}` - Periodic metric polling
- `{:opentelemetry_telemetry, "~> 1.0"}` - Bridge between :telemetry and OpenTelemetry

The Metrics module already uses `:telemetry.execute/3` to emit events, but there is **no central module** that:
1. Attaches handler functions to `:telemetry` events
2. Bridges `:telemetry` events to OpenTelemetry spans/metrics via `:opentelemetry_telemetry`
3. Provides a way to subscribe to arbitrary telemetry event prefixes (e.g., `[:phoenix, :endpoint]`, `[:ecto, :repo]`)
4. Manages handler lifecycle (attach on startup, detach on shutdown)

## Work Objectives

Build `ObservLib.Telemetry` as the central telemetry event handler module that:
- Attaches to `:telemetry` events and forwards them to OpenTelemetry traces/metrics
- Uses `:opentelemetry_telemetry` for span creation from telemetry events
- Supports subscribing to library event prefixes (Phoenix, Ecto, etc.)
- Integrates into the existing Application supervision tree
- Provides a clean public API for handler management

## Guardrails

### Must Have
- All public functions have `@doc`, `@spec`, and clear return types
- Tests use `async: false` (telemetry handlers are global state)
- Handler IDs are namespaced with `:observlib_` prefix to avoid collisions
- Idempotent attach/detach (matching pattern from `ObservLib.Logs`)
- Integration with `ObservLib.Config` for configuration
- Proper cleanup in tests (detach handlers in `on_exit`)

### Must NOT Have
- GenServer for this module (handlers are stateless; use module functions + `:telemetry.attach`)
- Direct dependency on Phoenix/Ecto/Plug (support their event prefixes, but do not require them)
- Changes to existing `ObservLib.Metrics` event emission logic
- Breaking changes to any existing public API

---

## Task Flow

### Step 1: Create `lib/observlib/telemetry.ex` - Core Module

**File:** `/home/urist/observlib-ex/lib/observlib/telemetry.ex`

**Public API to implement:**

```elixir
defmodule ObservLib.Telemetry do
  @moduledoc """
  Telemetry event handler integration for ObservLib.

  Bridges Erlang :telemetry events to OpenTelemetry traces and metrics.
  Supports attaching handlers for library instrumentation (Phoenix, Ecto, etc.)
  and custom application events.
  """
end
```

**Functions:**

1. `setup/0` - Attach all configured default handlers. Called during application startup.
   - Reads `:telemetry_events` from `ObservLib.Config` (or application env)
   - Attaches handlers for each configured event prefix
   - Returns `:ok | {:error, term()}`

2. `setup/1` - Attach handlers with explicit options (list of event prefixes).
   - Accepts `opts` keyword list with `:events` key
   - Returns `:ok | {:error, term()}`

3. `attach/2` - Attach a handler for a specific telemetry event prefix.
   - `attach(prefix, opts \\ [])` where prefix is like `[:phoenix, :endpoint]`
   - Generates handler ID as `:observlib_<prefix_joined>`
   - opts can include `:handler` (custom handler function) or uses default span-creating handler
   - Returns `:ok | {:error, :already_attached | term()}`

4. `detach/1` - Detach a handler by event prefix.
   - `detach(prefix)` removes the handler for the given prefix
   - Idempotent (returns `:ok` even if not attached)
   - Returns `:ok`

5. `list_handlers/0` - List all ObservLib-managed telemetry handlers.
   - Filters `:telemetry.list_handlers/1` results for `:observlib_` prefixed IDs
   - Returns list of handler info maps

6. `handle_event/4` - Default handler callback.
   - Creates OpenTelemetry span from telemetry event via `:opentelemetry_telemetry`
   - Also records metrics (histogram for duration measurements if present)
   - Signature: `handle_event(event_name, measurements, metadata, config)`

**Internal/private functions:**

- `handler_id/1` - Generate deterministic handler ID from event prefix
- `default_handler_config/0` - Default config map passed to handler callbacks
- `span_name/1` - Convert event name atoms to span name string (e.g., `[:phoenix, :endpoint, :stop]` -> `"phoenix.endpoint.stop"`)
- `extract_duration/1` - Extract duration from measurements map (handles `:duration` in native time units, converts to milliseconds)

**Acceptance criteria:**
- [ ] Module compiles without warnings
- [ ] All 6 public functions have `@doc` and `@spec`
- [ ] `setup/0` reads from application config and attaches handlers
- [ ] `attach/2` uses `:telemetry.attach/4` under the hood
- [ ] `detach/1` uses `:telemetry.detach/1` and is idempotent
- [ ] `handle_event/4` creates spans via `:opentelemetry_telemetry` or direct `:otel_tracer` calls
- [ ] Handler IDs follow `:observlib_*` naming convention

### Step 2: Create `test/observlib/telemetry_test.exs` - Comprehensive Tests

**File:** `/home/urist/observlib-ex/test/observlib/telemetry_test.exs`

**Test groups to implement:**

1. **`describe "setup/0"`** (3-4 tests)
   - Returns `:ok` with no configured events
   - Attaches handlers for configured event prefixes
   - Is idempotent (calling twice does not error)

2. **`describe "setup/1"`** (3-4 tests)
   - Attaches handlers for given event prefixes
   - Returns `:ok` with empty events list
   - Handles invalid event prefix format gracefully

3. **`describe "attach/2"`** (5-6 tests)
   - Attaches handler for a telemetry event prefix
   - Handler receives telemetry events when emitted
   - Returns error when prefix already attached (or handles idempotently)
   - Supports custom handler function via `:handler` option
   - Generates correct handler ID from prefix

4. **`describe "detach/1"`** (3-4 tests)
   - Detaches previously attached handler
   - Is idempotent (detaching non-existent handler returns `:ok`)
   - Handler no longer receives events after detach

5. **`describe "list_handlers/0"`** (3-4 tests)
   - Returns empty list when no handlers attached
   - Returns all ObservLib-managed handlers
   - Does not include non-ObservLib handlers

6. **`describe "handle_event/4"`** (4-5 tests)
   - Creates span from telemetry event
   - Extracts duration from measurements and records it
   - Handles events without duration measurement
   - Passes metadata as span attributes
   - Handles various measurement key formats (`:duration`, `:total_time`, `:system_time`)

7. **`describe "integration"`** (3-4 tests)
   - Full lifecycle: setup -> emit telemetry event -> verify span created -> detach
   - Multiple event prefixes attached and firing
   - Works with ObservLib.Metrics events (existing `:telemetry.execute` calls)

**Test patterns to follow (from existing tests):**
- Use `async: false` (telemetry handlers are global)
- Use `:telemetry.execute/3` to emit test events
- Use `:telemetry.attach/4` with test PID + `send/2` to capture events
- Cleanup handlers in `on_exit` callback
- Use unique handler IDs per test (pattern from `metrics_test.exs`)

**Acceptance criteria:**
- [ ] All tests pass with `mix test test/observlib/telemetry_test.exs`
- [ ] At least 25 test cases covering all public functions
- [ ] Tests clean up after themselves (no leaked handlers)
- [ ] No flaky tests (proper use of `assert_receive` with timeouts)

### Step 3: Integrate with Application Startup

**File to modify:** `/home/urist/observlib-ex/lib/observlib/application.ex`

**Changes:**
- Add `ObservLib.Telemetry.setup()` call in the `start/2` function, after `setup_exporters()` completes
- This ensures Config GenServer is available when Telemetry reads configuration
- Follow the existing pattern of logging success/failure (matching `setup_exporters` style)

**Specific change location:** After line 31 in `application.ex` (after `setup_exporters()` call), add:

```elixir
# Setup telemetry event handlers
setup_telemetry()
```

And add the private function:

```elixir
defp setup_telemetry do
  case ObservLib.Telemetry.setup() do
    :ok ->
      Logger.debug("Telemetry event handlers attached")
    {:error, reason} ->
      Logger.warning("Telemetry setup failed: #{inspect(reason)}")
  end
end
```

**Acceptance criteria:**
- [ ] `ObservLib.Telemetry.setup/0` is called during application startup
- [ ] Telemetry setup failure does not crash the application (warning only)
- [ ] Existing application startup tests still pass
- [ ] Setup happens after Config GenServer is running

### Step 4: Add Configuration Support and Convenience API

**File to modify:** `/home/urist/observlib-ex/config/config.exs`

Add default telemetry configuration:
```elixir
telemetry_events: []
```

**File to modify (optional):** `/home/urist/observlib-ex/lib/observlib.ex`

Consider adding a convenience function to the facade:
```elixir
@doc "Attach telemetry handlers for a library event prefix."
@spec attach_telemetry(list(atom()), keyword()) :: :ok | {:error, term()}
def attach_telemetry(prefix, opts \\ []) do
  ObservLib.Telemetry.attach(prefix, opts)
end
```

**Acceptance criteria:**
- [ ] Default config includes `telemetry_events: []`
- [ ] Convenience wrapper follows existing facade patterns (like `traced/3`, `counter/3`)
- [ ] Existing config tests still pass

### Step 5: Update Beads Database

**File to modify:** `/home/urist/observlib-ex/.beads/issues.jsonl`

Update the status of these issues to `"completed"`:
- `elixir_rs-19o` (Implement ObservLib.Telemetry)
- `elixir_rs-29z` (Phase 2: Telemetry Foundation)

Update the `updated_at` timestamp to the current ISO 8601 time.

**Acceptance criteria:**
- [ ] Both issue records have `"status": "completed"` in `issues.jsonl`
- [ ] `updated_at` timestamps are current
- [ ] No other issues modified

---

## Key Design Decisions

### Why not a GenServer?

Telemetry handlers in Erlang/Elixir are registered globally via `:telemetry.attach/4`. The handler function runs in the caller's process (the process that calls `:telemetry.execute/3`). There is no need for a GenServer to hold state -- the `:telemetry` library itself manages the handler registry. This matches the approach used by `opentelemetry_telemetry` and other BEAM telemetry libraries.

### Why use `:opentelemetry_telemetry`?

The `opentelemetry_telemetry` library (already a dependency) provides `OpentelemetryTelemetry.setup/1` and `OpentelemetryTelemetry.start_telemetry_span/3` which handle the bridging between `:telemetry` start/stop event pairs and OpenTelemetry spans. Rather than reimplementing this, `ObservLib.Telemetry` should delegate to it for span creation and provide a higher-level API on top.

### Handler ID naming

All handler IDs will be atoms of the form `:observlib_<prefix>` (e.g., `:observlib_phoenix_endpoint`). This avoids collisions with handlers from other libraries and makes `list_handlers/0` filtering straightforward.

---

## Success Criteria

- [ ] `mix test` passes with all new and existing tests
- [ ] `mix compile --warnings-as-errors` succeeds
- [ ] `ObservLib.Telemetry.setup/0` works during application startup
- [ ] Telemetry events can be subscribed to and forwarded to OpenTelemetry
- [ ] Handler lifecycle (attach/detach/list) works correctly
- [ ] No regressions in existing modules
- [ ] Beads issues marked completed
