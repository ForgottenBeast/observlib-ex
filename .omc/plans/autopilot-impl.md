# ObservLib Security Audit - Implementation Plan

**Version:** 1.0
**Date:** 2026-03-27
**Status:** Ready for Implementation
**Specification:** `.omc/autopilot/spec.md`

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Phase 1: Critical Fixes (C-01 through C-04)](#phase-1-critical-fixes)
3. [Phase 2: High-Priority Fixes (H-01 through H-05)](#phase-2-high-priority-fixes)
4. [Phase 3: Medium-Priority Fixes (M-01 through M-05)](#phase-3-medium-priority-fixes)
5. [Phase 4: Security Testing and Validation](#phase-4-security-testing-and-validation)
6. [Dependencies Between Tasks](#dependencies-between-tasks)
7. [Risk Mitigation Strategies](#risk-mitigation-strategies)
8. [Success Criteria](#success-criteria)

---

## Executive Summary

This plan remediates 14 security findings (4 CRITICAL, 5 HIGH, 5 MEDIUM) across 19 application source files in the ObservLib codebase. The work is organized into 4 phases with strict ordering: Critical fixes first, then High, then Medium, then comprehensive security testing. Each task includes the exact files/lines to modify, the implementation approach, backward compatibility analysis, and testing requirements.

**Total estimated effort:** ~40-55 hours of implementation
**Files requiring modification:** 14 source files + 3 config files + new modules/tests

---

## Phase 1: Critical Fixes

### Task 1.1: C-01 - TLS Configuration for External HTTP Communications

**Severity:** CRITICAL
**OWASP:** A02:2021 - Cryptographic Failures
**Estimated Complexity:** HIGH (~8 hours)

**Problem:**
All `Req.post` calls transmit data without TLS configuration. Three call sites identified:
- `lib/observlib/exporters/otlp_logs_exporter.ex:232` - OTLP logs export
- `lib/observlib/exporters/otlp_metrics_exporter.ex:290` - OTLP metrics export
- `lib/observlib/pyroscope/client.ex:423` - Pyroscope profile upload

None of these configure TLS options, certificate verification, or minimum TLS version.

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/config.ex` | init/1 (lines 114-154) | Add TLS config fields to state |
| `lib/observlib/exporters/otlp_logs_exporter.ex` | send_to_collector/3 (line 232) | Add TLS options to Req.post |
| `lib/observlib/exporters/otlp_metrics_exporter.ex` | do_http_export/2 (line 290) | Add TLS options to Req.post |
| `lib/observlib/pyroscope/client.ex` | upload_profile/3 (line 423) | Add TLS options to Req.post |
| `config/config.exs` | Top-level config | Add TLS default config keys |
| `config/runtime.exs` | Prod config (lines 6-20) | Add TLS env var support |

**Implementation Approach:**

1. Create a new helper module `lib/observlib/http.ex` that centralizes HTTP client configuration:
   - Accepts an endpoint URL and returns appropriate `Req` options including TLS settings
   - When scheme is `https://`: configure `transport_opts` with `verify: :verify_peer`, `cacerts: :public_key.cacerts_get()` (OTP 25+), configurable `versions: [:"tlsv1.2", :"tlsv1.3"]`
   - When scheme is `http://` and host is NOT localhost/127.0.0.1: emit a `Logger.warning` about plaintext transport
   - Support config overrides: `:tls_verify` (boolean, default true), `:tls_cacertfile` (path), `:tls_versions` (list)

2. Add TLS configuration keys to `ObservLib.Config`:
   - `:tls_verify` - defaults to `true`
   - `:tls_cacertfile` - defaults to `nil` (use system CA store)
   - `:tls_versions` - defaults to `[:"tlsv1.2", :"tlsv1.3"]`

3. Update all three `Req.post` call sites to use the centralized HTTP helper.

**Backward Compatibility:**
- Existing HTTP endpoints continue to work. The new TLS enforcement only applies to `https://` endpoints.
- Plaintext `http://` to non-localhost emits a warning but does NOT fail (opt-in strict mode via `:tls_require_https` config key).
- A new config key `:tls_require_https` (default: `false`) can be set to `true` to reject plaintext entirely.

**Testing Requirements:**
- Unit test: `ObservLib.Http` module correctly builds TLS options for https URLs
- Unit test: Warning is logged for plaintext http to non-localhost
- Unit test: localhost http does not produce a warning
- Unit test: `:tls_require_https` rejects non-https endpoints when enabled
- Integration test: Mock HTTPS endpoint with self-signed cert, verify rejection
- Integration test: Mock HTTPS endpoint with valid cert, verify successful connection

---

### Task 1.2: C-02 - Atom Table Exhaustion via User-Controlled Metric Names

**Severity:** CRITICAL
**OWASP:** A04:2021 - Insecure Design
**Estimated Complexity:** MEDIUM (~4 hours)

**Problem:**
Two locations use `String.to_atom/1` on potentially user-controlled input:
- `lib/observlib/metrics.ex:323` - `normalize_event_name/1` converts metric name segments to atoms via `Enum.map(&String.to_atom/1)`
- `lib/observlib/telemetry.ex:253` - `handler_id/1` converts prefix to atom via `String.to_atom("observlib_" <> suffix)`

The metrics path (line 323) is the critical one: any caller of `ObservLib.Metrics.counter/3`, `gauge/3`, `histogram/3`, or `up_down_counter/3` triggers atom creation from the metric name string. If an application passes user-controlled strings as metric names, this can exhaust the atom table and crash the VM.

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/metrics.ex` | Lines 319-324 (`normalize_event_name/1`) | Replace `String.to_atom` with `String.to_existing_atom` + fallback |
| `lib/observlib/telemetry.ex` | Line 253 (`handler_id/1`) | Replace `String.to_atom` with safe alternative |

**Implementation Approach:**

1. **`lib/observlib/metrics.ex` - `normalize_event_name/1` (line 319-324):**
   Replace:
   ```elixir
   defp normalize_event_name(name) do
     name
     |> normalize_name()
     |> String.split(".")
     |> Enum.map(&String.to_atom/1)
   end
   ```
   With a bounded approach. Since `:telemetry.execute/3` requires atom-based event names, use `String.to_existing_atom/1` with a rescue fallback that either:
   - (a) Maintains a bounded registry (ETS or map in MeterProvider state) of allowed metric name atoms, capped at a configurable limit (default: 1000), OR
   - (b) Uses a pre-registered set of known metric name segments, and rejects unregistered names with a warning log

   Recommended approach (a): Add a metric name registry to `MeterProvider` that tracks registered atom names. When a new metric name segment is encountered:
   - Try `String.to_existing_atom/1` first
   - If it fails (`ArgumentError`), check if the registry count is below the limit
   - If below limit, call `String.to_atom/1` and register it
   - If at limit, log a warning and use a catch-all atom like `:observlib_unknown_metric`

2. **`lib/observlib/telemetry.ex` - `handler_id/1` (line 253):**
   This is lower risk since `attach/2` is called with application-provided prefixes (atoms), not user input. However, replace with `String.to_existing_atom/1` wrapped in try/rescue, or use a deterministic ID scheme that does not create atoms (e.g., store handler IDs as strings and only create atoms for known prefixes).

   Simpler fix: since the prefix is already a list of atoms (see the `when is_list(prefix)` guard on `attach/2` at line 122), the `handler_id/1` function joins known atoms. The only new atom created is the concatenated form. This is bounded by the number of `attach` calls, which is application-controlled. Add a `@max_handlers 100` limit and check before creating the atom.

**Backward Compatibility:**
- `normalize_event_name/1` is private, so the API is unchanged. Callers of `counter/3`, `gauge/3`, etc. continue to work. The only difference is that after the atom registration limit is reached, new unique metric names will be coalesced and a warning logged.
- `handler_id/1` is private. No API change.

**Testing Requirements:**
- Property test: Generate 1,000,000 unique random metric name strings, call `counter/3` for each, verify the VM does NOT crash
- Unit test: After exceeding the metric name atom limit, new names are handled gracefully with warning
- Unit test: `String.to_existing_atom` path works for pre-registered names
- Unit test: Telemetry handler ID creation is bounded

---

### Task 1.3: C-03 - Unbounded ETS Memory Growth (Metrics Cardinality)

**Severity:** CRITICAL
**OWASP:** A04:2021 - Insecure Design
**Estimated Complexity:** MEDIUM (~5 hours)

**Problem:**
`lib/observlib/metrics/meter_provider.ex` stores metrics in ETS keyed by `{name, normalized_attributes}` (line 215). There is no limit on the number of unique attribute combinations (cardinality). High-cardinality labels (e.g., user IDs, request IDs) create unbounded ETS entries.

The `record_metric/3` private functions (lines 265-349) insert into ETS without checking table size. The `handle_cast({:record, ...})` at line 214 delegates directly to `record_metric/3` with no guard.

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/metrics/meter_provider.ex` | Lines 126-152 (init), 214-218 (handle_cast), 265-349 (record_metric) | Add cardinality limits |
| `lib/observlib/config.ex` | Lines 114-154 (init) | Add `:max_metric_cardinality` to state |
| `config/config.exs` | Config block | Add `max_metric_cardinality: 2000` default |

**Implementation Approach:**

1. Add a configurable `:max_metric_cardinality` option (default: 2000) to `Config`.

2. In `MeterProvider.init/1`, store the max cardinality in the GenServer state.

3. In `handle_cast({:record, name, type, value, attributes}, state)` (line 214), before calling `record_metric/3`:
   - Check if the key `{name, normalized_attributes}` already exists in ETS (fast lookup)
   - If it does NOT exist, check the current ETS table size via `:ets.info(@metrics_table, :size)`
   - If size >= `max_metric_cardinality`, log a warning (`Logger.warning("Metric cardinality limit reached (#{max}), dropping metric: #{name}")`) and skip the insert
   - If it exists, allow the update (no new row created)

4. Add a `get_cardinality/0` public function to MeterProvider for monitoring.

**Backward Compatibility:**
- Existing metrics with cardinality below 2000 are unaffected.
- Applications exceeding the limit will see a warning log and dropped metrics. This is a safe degradation vs. OOM crash.
- The limit is configurable, so applications with legitimate high cardinality can raise it.

**Testing Requirements:**
- Unit test: Record 2001 unique attribute combinations, verify the 2001st is dropped with warning
- Unit test: Verify existing keys can still be updated after the limit is reached
- Unit test: Verify configurable limit works (set to 10, test at 11)
- Property test: Generate random attributes at high cardinality, verify ETS size stays bounded
- Load test: 100k metric recordings with random attributes, verify no OOM

---

### Task 1.4: C-04 - Unbounded Log Batch Queue

**Severity:** CRITICAL
**OWASP:** A04:2021 - Insecure Design
**Estimated Complexity:** MEDIUM (~3 hours)

**Problem:**
`lib/observlib/exporters/otlp_logs_exporter.ex:189-207` - The `handle_cast({:add_to_batch, log_records})` handler appends to `state.batch` without any size limit. When the collector is down, `do_export` fails, and on line 203 the failed batch is kept in state (`{:noreply, state}`). Meanwhile, new casts continue appending. The batch grows unbounded until memory is exhausted.

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/exporters/otlp_logs_exporter.ex` | Lines 152-167 (init), 189-207 (handle_cast) | Add max queue size limit |
| `lib/observlib/config.ex` | init/1 | Add `:logs_max_queue_size` to state |
| `config/config.exs` | Config block | Add `logs_max_queue_size: 5000` default |

**Implementation Approach:**

1. Add `:logs_max_queue_size` config key (default: 5000) in `Config`.

2. In `OtlpLogsExporter.init/1` (line 152), read and store `max_queue_size` in state.

3. In `handle_cast({:add_to_batch, log_records}, state)` (line 189):
   - Before appending, check `length(state.batch) + length(log_records)`
   - If exceeding `max_queue_size`, truncate: keep only the newest `max_queue_size` entries by dropping from the head of the existing batch
   - Log a warning: `"Log batch queue limit reached (#{max_queue_size}), dropping #{dropped_count} oldest log records"`

4. Also fix the error path at line 202-203: when export fails and batch is retained, apply the same size limit check.

**Backward Compatibility:**
- Normal operation (collector reachable) is unaffected -- batches flush before hitting the limit.
- When collector is down, logs are dropped with a warning instead of causing OOM. This is strictly better behavior.
- The limit is configurable for applications with specific needs.

**Testing Requirements:**
- Unit test: Add 6000 log records to batch with max_queue_size=5000, verify batch is capped at 5000
- Unit test: Simulate export failure, add more records, verify batch stays bounded
- Unit test: Verify the NEWEST records are retained (oldest dropped)
- Unit test: Verify warning log is emitted when dropping

---

## Phase 2: High-Priority Fixes

### Task 2.1: H-01 - OTLP Headers Leak via `inspect()` in Error Logs

**Severity:** HIGH
**OWASP:** A01:2021 - Broken Access Control (A09 Logging)
**Estimated Complexity:** LOW (~3 hours)

**Problem:**
Multiple `inspect()` calls in error logging paths can expose OTLP headers containing bearer tokens or API keys. The spec calls out `lib/observlib/exporters/otlp_metrics_exporter.ex:296`, but the pattern exists across all exporters. Anywhere `inspect(reason)` or `inspect(body)` is logged after a `Req.post` failure, the Req error/response struct may contain request headers.

Specific locations:
- `lib/observlib/exporters/otlp_metrics_exporter.ex:251` - `inspect(reason)` in retry warning
- `lib/observlib/exporters/otlp_metrics_exporter.ex:296` - `inspect(body)` in error log
- `lib/observlib/exporters/otlp_metrics_exporter.ex:300` - `inspect(reason)` in error log
- `lib/observlib/exporters/otlp_logs_exporter.ex:177` - `inspect(reason)` in error log
- `lib/observlib/exporters/otlp_logs_exporter.ex:201` - `inspect(reason)` in error log
- `lib/observlib/exporters/otlp_logs_exporter.ex:378` - `inspect(reason)` in error log
- `lib/observlib/pyroscope/client.ex:308` - `inspect(reason)` in warning log

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/http.ex` (NEW) | N/A | Add `redact_error/1` helper function |
| `lib/observlib/exporters/otlp_metrics_exporter.ex` | Lines 251, 296, 300 | Use `redact_error` instead of raw `inspect` |
| `lib/observlib/exporters/otlp_logs_exporter.ex` | Lines 177, 201, 378 | Use `redact_error` instead of raw `inspect` |
| `lib/observlib/pyroscope/client.ex` | Line 308 | Use `redact_error` instead of raw `inspect` |

**Implementation Approach:**

1. In the new `ObservLib.Http` module (created in Task 1.1), add a `redact_error/1` function:
   - For `Req.Response` structs: redact headers matching `authorization`, `x-api-key`, `api-key`, or any header key containing `token`, `secret`, `key`, `auth`
   - For `Req.TransportError` / other error tuples: recursively scan for header maps and redact
   - Returns a sanitized string suitable for logging
   - Pattern: replace header values with `"[REDACTED]"`

2. Replace all `inspect(reason)` and `inspect(body)` in error log messages with `ObservLib.Http.redact_error(reason)`.

**Backward Compatibility:**
- Log message format changes slightly (redacted values). This is intentional and security-positive.
- No API changes.

**Testing Requirements:**
- Unit test: `redact_error/1` redacts `authorization` header from a mock Req error
- Unit test: `redact_error/1` passes through non-sensitive errors unchanged
- Unit test: Simulate OTLP export failure with `Authorization: Bearer <token>` header, verify token does NOT appear in Logger output
- Unit test: Cover various error shapes (Req.TransportError, {:error, reason}, HTTP response bodies)

---

### Task 2.2: H-02 - ETS Tables with `:public` Access Control

**Severity:** HIGH
**OWASP:** A01:2021 - Broken Access Control
**Estimated Complexity:** MEDIUM (~4 hours)

**Problem:**
Four ETS tables are created with `:public` access, meaning any process in the VM can read AND write to them:
- `lib/observlib/metrics/meter_provider.ex:128-133` - `:observlib_metrics` table
- `lib/observlib/metrics/meter_provider.ex:135-139` - `:observlib_metric_registry` table
- `lib/observlib/traces/provider.ex:152` - `:observlib_active_spans` table
- `lib/observlib/traces/pyroscope_processor.ex:127` - `:observlib_pyroscope_profiles` table

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/metrics/meter_provider.ex` | Lines 128-139 | Change `:public` to `:protected` |
| `lib/observlib/traces/provider.ex` | Line 152 | Change `:public` to `:protected` |
| `lib/observlib/traces/pyroscope_processor.ex` | Line 127 | Change `:public` to `:protected` |
| `lib/observlib/metrics/prometheus_reader.ex` | Line 213 | Route reads through GenServer API instead of direct ETS |

**Implementation Approach:**

1. Change all four ETS tables from `:public` to `:protected`.

2. With `:protected`, only the owning GenServer process can write, and any process can read. This is actually already sufficient for the current architecture:
   - `MeterProvider` writes are already routed through GenServer casts (line 82: `GenServer.cast`)
   - `PrometheusReader` at line 213 calls `ObservLib.Metrics.MeterProvider.read_all()` which is a GenServer call -- this already works with `:protected`
   - `Traces.Provider` writes are through GenServer casts (lines 74, 98)
   - `PyroscopeProcessor` writes are through GenServer casts (line 61, 91)

3. The key concern is ensuring NO code path performs a direct `:ets.insert` from outside the owning GenServer. Audit confirmed: all ETS writes happen inside `handle_cast` or `handle_call` callbacks (within the owning process). So changing to `:protected` is safe.

4. Keep `read_concurrency: true` since cross-process reads are still needed and valid with `:protected`.

**Backward Compatibility:**
- No API changes. All public functions already route through GenServer.
- Any external code that was directly writing to these named ETS tables (violating encapsulation) will get a `:badarg` error. This is the intended security improvement.

**Testing Requirements:**
- Unit test: Verify ETS tables are created with `:protected` access
- Unit test: Verify reads from other processes still work via GenServer API
- Unit test: Verify direct `:ets.insert` from a non-owner process raises an error
- Integration test: Full metrics pipeline works end-to-end with `:protected` tables

---

### Task 2.3: H-03 - `Process.sleep` in GenServer Callbacks During Retries

**Severity:** HIGH
**OWASP:** A04:2021 - Insecure Design
**Estimated Complexity:** MEDIUM (~5 hours)

**Problem:**
Three locations use `Process.sleep` inside GenServer callback chains, blocking the GenServer process and preventing it from handling other messages:
- `lib/observlib/exporters/otlp_logs_exporter.ex:242` - Inside `send_to_collector` called from `handle_call` and `handle_cast`
- `lib/observlib/exporters/otlp_logs_exporter.ex:251` - Same function, error branch
- `lib/observlib/exporters/otlp_metrics_exporter.ex:254` - Inside `export_with_retry` called from `handle_info`

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/exporters/otlp_logs_exporter.ex` | Lines 225-257 (`send_to_collector`), 189-207 (`handle_cast`) | Replace recursive sleep+retry with `Process.send_after` based retry |
| `lib/observlib/exporters/otlp_metrics_exporter.ex` | Lines 241-260 (`export_with_retry`) | Replace recursive sleep+retry with `Process.send_after` based retry |

**Implementation Approach:**

1. **OtlpLogsExporter** - Refactor `send_to_collector/3` to be non-blocking:
   - Remove the recursive `Process.sleep` + retry pattern
   - On failure in `handle_cast({:add_to_batch, ...})`: schedule a retry via `Process.send_after(self(), {:retry_export, payload, retry_count + 1}, delay)`
   - Add a new `handle_info({:retry_export, payload, retry_count}, state)` clause that attempts the export and either succeeds or schedules another retry
   - Use exponential backoff with jitter: `delay = trunc(:math.pow(2, retry_count) * 100 + :rand.uniform(50))`
   - For the synchronous `handle_call({:export, ...})` path: perform a single attempt, return `{:error, reason}` on failure (no retries -- caller can retry)

2. **OtlpMetricsExporter** - Refactor `export_with_retry/4`:
   - Same pattern: replace `Process.sleep` with `Process.send_after` based scheduling
   - On failure in `handle_info(:export, state)`: schedule retry via `Process.send_after(self(), {:retry_metrics_export, metrics, retries_left - 1}, delay)`
   - Add `handle_info({:retry_metrics_export, metrics, retries_left}, state)` clause

**Backward Compatibility:**
- The public API is unchanged: `export/1`, `flush/0`, `force_export/0` all work the same.
- Behavioral change: retries happen asynchronously instead of blocking. The GenServer remains responsive during retry delays.
- `force_export/0` (synchronous call) does a single attempt and returns immediately on failure (no retries).

**Testing Requirements:**
- Unit test: Export failure does not block the GenServer (send another message during retry delay, verify it is processed)
- Unit test: Retry occurs after the expected delay
- Unit test: Exponential backoff increases delay between retries
- Unit test: Max retries are respected
- Integration test: Collector down for 60 seconds, verify other GenServer operations are not blocked

---

### Task 2.4: H-04 - Unauthenticated Prometheus TCP Endpoint

**Severity:** HIGH
**OWASP:** A01:2021 - Broken Access Control
**Estimated Complexity:** MEDIUM (~5 hours)

**Problem:**
`lib/observlib/metrics/prometheus_reader.ex:73-81` opens a TCP socket accepting connections from any source with no authentication, rate limiting, or connection limits. The `accept_loop/2` (line 149) spawns unlimited processes for each connection.

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/metrics/prometheus_reader.ex` | Lines 68-99 (init), 149-163 (accept_loop), 166-169 (handle_request) | Add connection limit, rate limit, optional IP allowlist |
| `lib/observlib/config.ex` | init/1 | Add prometheus security config keys |
| `config/config.exs` | Config block | Add prometheus security defaults |

**Implementation Approach:**

1. **Connection Limiting** - Add a connection counter to the GenServer state:
   - Track active connections with an atomic counter (`:counters` module) or state field
   - Default max: 10 concurrent connections (configurable via `:prometheus_max_connections`)
   - In `accept_loop`, before spawning handler: check counter, reject with 503 if at limit
   - In `handle_request`, decrement counter after socket close (use try/after)

2. **Rate Limiting** - Simple sliding window counter:
   - Track request count per minute in GenServer state
   - Default max: 100 requests/minute (configurable via `:prometheus_rate_limit`)
   - Return 429 Too Many Requests when exceeded
   - Reset counter via `Process.send_after(self(), :reset_rate_limit, 60_000)`

3. **IP Allowlist (Optional)** - Add `:prometheus_allowed_ips` config:
   - Default: `nil` (allow all -- for backward compatibility)
   - When set to a list of CIDR strings (e.g., `["127.0.0.1/32", "10.0.0.0/8"]`), check `socket.peername` against the allowlist
   - Reject non-matching IPs with 403

4. **Bind Address** - Add `:prometheus_bind_address` config:
   - Default: `{0, 0, 0, 0}` (all interfaces -- backward compatible)
   - Recommend `{127, 0, 0, 1}` for production unless scraped externally

**Backward Compatibility:**
- Default behavior is unchanged (accepts all connections, no auth).
- Rate limiting and connection limits are new but have generous defaults.
- IP allowlist is opt-in (nil by default).
- Bind address defaults to all interfaces.

**Testing Requirements:**
- Unit test: Connection limit rejects the 11th concurrent connection with 503
- Unit test: Rate limit returns 429 after 100 requests within 1 minute
- Unit test: IP allowlist blocks non-matching IPs
- Unit test: IP allowlist allows matching IPs
- Unit test: Default config (no allowlist) accepts all connections
- Integration test: Prometheus scrape works end-to-end with security features enabled

---

### Task 2.5: H-05 - No URL Validation for OTLP Endpoints

**Severity:** HIGH
**OWASP:** A03:2021 - Injection
**Estimated Complexity:** LOW (~3 hours)

**Problem:**
Endpoint URLs from config are used directly without validation. `config/runtime.exs:9-12` reads environment variables directly into endpoint config. No scheme validation, no userinfo rejection, no file:// protection.

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/http.ex` (NEW, from Task 1.1) | N/A | Add `validate_endpoint_url/1` function |
| `lib/observlib/config.ex` | Lines 131-135 (init) | Validate endpoints on startup |
| `config/runtime.exs` | Lines 6-20 | Add URL validation before config |

**Implementation Approach:**

1. In `ObservLib.Http`, add `validate_endpoint_url/1`:
   ```
   - Parse with `URI.parse/1`
   - Reject if scheme is not "http" or "https"
   - Reject if `uri.userinfo` is not nil (prevents credential injection: `http://user:pass@host`)
   - Reject if host is nil or empty
   - Reject file://, ftp://, or other non-HTTP schemes
   - Return `{:ok, validated_url}` or `{:error, reason}`
   ```

2. In `Config.init/1`, validate all endpoint URLs during startup:
   - `otlp_endpoint`, `otlp_traces_endpoint`, `otlp_metrics_endpoint`, `otlp_logs_endpoint`, `pyroscope_endpoint`
   - Invalid URLs cause a startup warning and the endpoint is set to `nil` (disabled), NOT a crash

3. In `runtime.exs`, add inline validation for env var values (defense in depth).

**Backward Compatibility:**
- Valid HTTP/HTTPS URLs continue to work unchanged.
- Invalid URLs that were silently accepted before now produce a warning and the feature is disabled. This prevents SSRF but may surprise users with misconfigured URLs.
- No crash on invalid URL -- graceful degradation to disabled state.

**Testing Requirements:**
- Unit test: `validate_endpoint_url/1` accepts `http://localhost:4318`
- Unit test: `validate_endpoint_url/1` accepts `https://otel.example.com:443/v1/traces`
- Unit test: `validate_endpoint_url/1` rejects `file:///etc/passwd`
- Unit test: `validate_endpoint_url/1` rejects `http://user:pass@host:4318`
- Unit test: `validate_endpoint_url/1` rejects empty string, nil
- Unit test: `validate_endpoint_url/1` rejects `javascript:alert(1)`
- Unit test: Config startup with invalid URL logs warning and sets endpoint to nil

---

## Phase 3: Medium-Priority Fixes

### Task 3.1: M-01 - No Attribute Value Size Limits

**Severity:** MEDIUM
**Estimated Complexity:** LOW (~2 hours)

**Problem:**
Span attributes and metric attributes accept arbitrary-length strings. A malicious caller could pass a 100MB string as an attribute value, consuming excessive memory in ETS and in OTLP payloads.

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/traces.ex` | `start_span/2`, `set_attribute/2`, `with_span/3` | Add attribute value size check |
| `lib/observlib/metrics/meter_provider.ex` | `handle_cast({:record, ...})` (line 214) | Add attribute value size check |
| `lib/observlib/config.ex` | init/1 | Add `:max_attribute_value_length` config |

**Implementation Approach:**

1. Add `:max_attribute_value_length` config (default: 4096 bytes).
2. Create a helper `ObservLib.Attributes` module with `sanitize_attributes/2` that:
   - Truncates string values exceeding the limit (append `"...[truncated]"`)
   - Limits the number of attributes per span/metric (default: 128)
   - Recursively handles nested maps/lists
3. Apply at the entry points: `Traces.start_span`, `Traces.set_attribute`, `MeterProvider.handle_cast`.

**Backward Compatibility:** Transparent truncation. No API change. Very large values will be truncated with a marker.

**Testing Requirements:**
- Unit test: Attribute value exceeding limit is truncated
- Unit test: Attribute count exceeding limit drops excess attributes
- Unit test: Normal-sized attributes pass through unchanged

---

### Task 3.2: M-02 - No Sensitive Attribute Redaction Mechanism

**Severity:** MEDIUM
**Estimated Complexity:** MEDIUM (~4 hours)

**Problem:**
No mechanism exists to prevent PII/secrets from being included in span attributes, metric labels, or log attributes. Applications may inadvertently pass sensitive data (passwords, SSNs, tokens) as attribute values.

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/attributes.ex` (NEW, from Task 3.1) | N/A | Add `redact/2` function |
| `lib/observlib/config.ex` | init/1 | Add `:redacted_attribute_keys` config |

**Implementation Approach:**

1. Add `:redacted_attribute_keys` config (default: `["password", "secret", "token", "authorization", "credit_card", "ssn"]`).
2. Add `:redaction_pattern` config (default: `"[REDACTED]"`).
3. In `ObservLib.Attributes.sanitize_attributes/2` (from Task 3.1), also check attribute keys against the redaction list. Both exact match and substring match (configurable).
4. Apply to spans, metrics, and log attributes.

**Backward Compatibility:** Opt-out via empty redaction list. Default list covers common sensitive keys. Existing attribute data that matches will be redacted in exported telemetry.

**Testing Requirements:**
- Unit test: Attribute with key "password" is redacted
- Unit test: Attribute with key "user_name" is NOT redacted (not in default list)
- Unit test: Custom redaction list works
- Unit test: Empty redaction list disables redaction

---

### Task 3.3: M-03 - Missing Input Validation in `runtime.exs`

**Severity:** MEDIUM
**Estimated Complexity:** LOW (~1 hour)

**Problem:**
`config/runtime.exs:13-14` uses `String.to_integer/1` on environment variables without guards. If `OBSERVLIB_OTLP_TIMEOUT` is set to a non-numeric value (e.g., "abc"), the application crashes at startup with an unhelpful `ArgumentError`.

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `config/runtime.exs` | Lines 13-15 | Add safe parsing with fallback |

**Implementation Approach:**

1. Replace `String.to_integer(System.get_env(...) || "default")` with a helper that uses `Integer.parse/1`:
   ```elixir
   defp parse_int_env(var, default) do
     case System.get_env(var) do
       nil -> default
       val ->
         case Integer.parse(val) do
           {int, ""} when int > 0 -> int
           _ -> default
         end
     end
   end
   ```
2. Apply to `otlp_timeout`, `batch_size`, `batch_timeout`.
3. Also validate ranges (e.g., timeout > 0, batch_size > 0).

**Backward Compatibility:** Same behavior for valid inputs. Invalid inputs now fall back to defaults instead of crashing.

**Testing Requirements:**
- Unit test: Valid integer env var is parsed correctly
- Unit test: Non-integer env var falls back to default
- Unit test: Missing env var uses default
- Unit test: Negative integer falls back to default

---

### Task 3.4: M-04 - No Max Active Span Limit

**Severity:** MEDIUM
**Estimated Complexity:** LOW (~2 hours)

**Problem:**
`lib/observlib/traces/provider.ex` tracks active spans in ETS with no upper limit. A span leak (spans started but never ended) or burst of concurrent operations can fill memory.

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/traces/provider.ex` | Lines 150-168 (init), 171-188 (handle_cast track_span) | Add max active span limit |
| `lib/observlib/config.ex` | init/1 | Add `:max_active_spans` config |
| `config/config.exs` | Config block | Add `max_active_spans: 10000` default |

**Implementation Approach:**

1. Add `:max_active_spans` config (default: 10000).
2. In `handle_cast({:track_span, ...})` (line 171), before inserting:
   - Check `:ets.info(@ets_table, :size)` against limit
   - If at limit, skip ETS tracking (the OTel span itself still works -- we just don't track it in our auxiliary table)
   - Log warning on first occurrence per minute (avoid log spam)

**Backward Compatibility:** Spans still work via OpenTelemetry even when the tracking limit is reached. Only the auxiliary ETS tracking is bounded. No API change.

**Testing Requirements:**
- Unit test: Verify spans beyond limit are not tracked in ETS
- Unit test: Verify the OTel span itself still works (can set attributes, end)
- Unit test: Verify warning is logged

---

### Task 3.5: M-05 - Prometheus Label Injection (Partial Mitigation Exists)

**Severity:** MEDIUM
**Estimated Complexity:** LOW (~2 hours)

**Problem:**
`lib/observlib/metrics/prometheus_reader.ex:355-360` - `escape_label_value/1` handles backslash, double-quote, and newline, but does NOT handle carriage return (`\r`), null bytes (`\0`), or other control characters that could be used for HTTP response splitting or log injection.

**Files to Modify:**

| File | Lines | Change |
|------|-------|--------|
| `lib/observlib/metrics/prometheus_reader.ex` | Lines 343-360 (`sanitize_metric_name`, `sanitize_label_name`, `escape_label_value`) | Enhance escaping |

**Implementation Approach:**

1. Enhance `escape_label_value/1` to also escape:
   - `\r` (carriage return) - prevents HTTP response splitting
   - `\0` (null byte) - prevents null injection
   - All control characters (codepoints 0x00-0x1F except `\n` which is already handled) - replace with `\\u00XX` or strip

2. Enhance `sanitize_metric_name/1` and `sanitize_label_name/1` to also reject:
   - Names longer than 128 characters (truncate with warning)
   - Leading `__` (reserved in Prometheus for internal use)

**Backward Compatibility:** Existing valid label values are unchanged. Only values containing control characters (which are invalid in Prometheus format anyway) are affected.

**Testing Requirements:**
- Unit test: `escape_label_value/1` escapes `\r`, `\0`, control chars
- Unit test: `sanitize_metric_name/1` handles names with control characters
- Unit test: Metric names > 128 chars are truncated
- Unit test: Existing valid names/values pass through unchanged
- Fuzz test: Random binary input to escape functions does not produce invalid Prometheus output

---

## Phase 4: Security Testing and Validation

### Task 4.1: Security Test Suite

**Estimated Complexity:** HIGH (~8 hours)

**Files to Create:**

| File | Purpose |
|------|---------|
| `test/security/atom_exhaustion_test.exs` | Property test with StreamData for C-02 |
| `test/security/ets_bounds_test.exs` | Cardinality and queue limit tests for C-03, C-04 |
| `test/security/tls_test.exs` | TLS configuration validation for C-01 |
| `test/security/header_redaction_test.exs` | Credential leak prevention for H-01 |
| `test/security/prometheus_security_test.exs` | Endpoint security for H-04 |
| `test/security/url_validation_test.exs` | SSRF prevention for H-05 |
| `test/security/injection_test.exs` | Label/log injection for M-05 |
| `test/security/attribute_limits_test.exs` | Size limits for M-01, M-02 |

**Implementation Approach:**

1. **Property-Based Tests (StreamData):**
   - Generate 1M unique metric names, verify no atom table crash (C-02)
   - Generate high-cardinality attribute maps, verify ETS bounds (C-03)
   - Generate large log batches, verify queue bounds (C-04)
   - Fuzz attribute values with arbitrary binaries, verify sanitization (M-01)
   - Fuzz label values, verify Prometheus format validity (M-05)

2. **Integration Tests:**
   - Mock OTLP collector with Req.Test, test TLS negotiation (C-01)
   - Mock collector returning 500s for 60 seconds, verify GenServer responsiveness (H-03)
   - Test Prometheus endpoint with concurrent connections exceeding limit (H-04)
   - Test URL validation with adversarial inputs (H-05)

3. **Regression Tests:**
   - Each finding gets a specific regression test that reproduces the original vulnerability and verifies the fix

### Task 4.2: Static Analysis Validation

**Estimated Complexity:** LOW (~1 hour)

**Implementation:**
1. Run `mix credo --strict` and fix any new warnings
2. Run `mix dialyzer` and fix type errors
3. Verify zero `String.to_atom/1` calls on user-controlled data (grep audit)
4. Verify all ETS tables use `:protected` (grep audit)
5. Verify no `Process.sleep` in GenServer callbacks (grep audit)

### Task 4.3: Dependency Audit

**Estimated Complexity:** LOW (~1 hour)

**Implementation:**
1. Add `{:mix_audit, "~> 2.0", only: :dev, runtime: false}` to `mix.exs` deps
2. Run `mix deps.audit`
3. Address any HIGH/CRITICAL CVEs by updating dependencies
4. Document any accepted risks for LOW/MEDIUM CVEs

### Task 4.4: Security Documentation

**Estimated Complexity:** MEDIUM (~3 hours)

**Files to Create:**

| File | Purpose |
|------|---------|
| `SECURITY.md` | Vulnerability disclosure policy |
| `guides/security.md` | Security configuration guide |

**Content:**
- TLS configuration examples
- Prometheus endpoint isolation guidance
- Attribute redaction configuration
- Secret management best practices
- Deployment topology recommendations

---

## Dependencies Between Tasks

```
Phase 1 (Critical) - All can run in parallel EXCEPT:
  Task 1.1 (TLS) creates lib/observlib/http.ex -- must complete before Task 2.1 and 2.5

Phase 2 (High) - Dependencies:
  Task 2.1 (Header Redaction) DEPENDS ON Task 1.1 (shared http.ex module)
  Task 2.5 (URL Validation) DEPENDS ON Task 1.1 (shared http.ex module)
  Tasks 2.2, 2.3, 2.4 can run in parallel with no dependencies

Phase 3 (Medium) - Dependencies:
  Task 3.1 (Attribute Limits) creates lib/observlib/attributes.ex
  Task 3.2 (Attribute Redaction) DEPENDS ON Task 3.1 (shared attributes.ex module)
  Tasks 3.3, 3.4, 3.5 can run in parallel with no dependencies

Phase 4 (Testing) - Dependencies:
  ALL Phase 4 tasks DEPEND ON Phases 1-3 completion
  Task 4.1 (Tests) should run last after all fixes are in place
```

**Execution Order (critical path):**
```
1.1 (TLS) --> 2.1 (Header Redaction) --> 2.5 (URL Validation)
1.2 (Atom Safety) -- parallel
1.3 (ETS Bounds) -- parallel
1.4 (Log Queue) -- parallel
2.2 (ETS Access) -- after Phase 1
2.3 (Process.sleep) -- after Phase 1
2.4 (Prometheus) -- after Phase 1
3.1 (Attr Limits) --> 3.2 (Attr Redaction)
3.3 (runtime.exs) -- parallel
3.4 (Span Limit) -- parallel
3.5 (Label Injection) -- parallel
4.1-4.4 (Testing/Docs) -- after all fixes
```

---

## Risk Mitigation Strategies

### Risk 1: Breaking Changes in Metric Event Names
**Risk:** Task 1.2 changes how metric event names become atoms. Existing `:telemetry.attach` handlers that rely on specific atom event names may break.
**Mitigation:** The atom creation still works for names under the limit. Add the default metric name atoms at startup for well-known OTel metric names. Document the limit in configuration guide.

### Risk 2: TLS Certificate Issues in Production
**Risk:** Task 1.1 enables TLS verification. Production environments with self-signed certificates or missing CA bundles will fail to export.
**Mitigation:** Provide `:tls_verify` config option (can be set to `false` for development). Log a clear error message explaining the TLS failure. Document CA bundle configuration.

### Risk 3: Prometheus Scrape Failures Due to Rate Limiting
**Risk:** Task 2.4 adds rate limiting. Aggressive scrape intervals (<1s) from monitoring infrastructure may hit the limit.
**Mitigation:** Default rate limit of 100/min is generous (supports <1s intervals for short bursts). Make limit configurable. Return 429 with `Retry-After` header.

### Risk 4: Data Loss from Queue Limits
**Risk:** Tasks 1.3 and 1.4 drop data when limits are reached. Operators may lose telemetry during outages.
**Mitigation:** Log clear warnings when data is dropped, including counts. Make limits configurable. The alternative (OOM crash) loses ALL data, so bounded loss is strictly better.

### Risk 5: Performance Impact of Attribute Sanitization
**Risk:** Tasks 3.1 and 3.2 add processing to the hot path (every metric recording, span creation).
**Mitigation:** Use efficient string length checks (`byte_size/1` is O(1)). Only do full sanitization when limits are exceeded. Benchmark the overhead -- target <1 microsecond per attribute check.

---

## Success Criteria

### Phase 1 Complete When:
- [ ] All `Req.post` calls use centralized HTTP config with TLS support
- [ ] Zero `String.to_atom/1` calls on unbounded user input
- [ ] ETS metric cardinality is bounded (default: 2000)
- [ ] Log batch queue is bounded (default: 5000)
- [ ] All existing tests pass
- [ ] New unit tests for each fix pass

### Phase 2 Complete When:
- [ ] No OTLP headers appear in any log output under error conditions
- [ ] All ETS tables use `:protected` access
- [ ] Zero `Process.sleep` calls in GenServer callbacks
- [ ] Prometheus endpoint has connection limits and optional auth
- [ ] All endpoint URLs are validated on startup
- [ ] All existing tests pass
- [ ] New unit tests for each fix pass

### Phase 3 Complete When:
- [ ] Attribute values are size-limited (default: 4096 bytes)
- [ ] Sensitive attribute redaction is available and on by default
- [ ] `runtime.exs` handles invalid env vars gracefully
- [ ] Active span tracking is bounded (default: 10000)
- [ ] Prometheus label escaping handles all control characters
- [ ] All existing tests pass
- [ ] New unit tests for each fix pass

### Phase 4 Complete When:
- [ ] Security test suite passes (all property-based and integration tests)
- [ ] `mix credo --strict` passes with zero warnings
- [ ] `mix dialyzer` passes with zero errors
- [ ] `mix deps.audit` reports zero HIGH/CRITICAL CVEs
- [ ] Security documentation is complete
- [ ] Grep audit confirms zero `String.to_atom/1` on user data, zero `:public` ETS, zero `Process.sleep` in GenServer

### Overall Audit Complete When:
- [ ] All CRITICAL findings (C-01 through C-04) remediated
- [ ] All HIGH findings (H-01 through H-05) remediated
- [ ] All MEDIUM findings (M-01 through M-05) remediated
- [ ] Security test suite passes at 1000+ iterations for property tests
- [ ] Documentation updated with security guidance
- [ ] No regressions in existing test suite
