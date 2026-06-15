# Phase 1+2 Findings — ObservLib Security Audit
Date: 2026-04-23

## Phase 1: Existing Finding Verification

| ID | Status | Evidence |
|----|--------|----------|
| sec-001 | VERIFIED (weak) | Tests exercise `safe_to_atom/1` path but property test at line 42 only asserts `:ok` return (non-crash), not that atom count stays bounded. Log assertion at line 29 confirms warning emitted but doesn't verify atom table hasn't grown. |
| sec-002 | VERIFIED (weak) | Tests verify `handler_id/1` rejects non-atom elements (line 73). But line 75 uses `send()` to bypass the public API — doesn't prove the public `attach/1` itself validates. Property test (line 80-101) creates atoms via `String.to_atom/1` at line 85 — this *itself* creates atoms, defeating the purpose. |
| sec-003 | VERIFIED | Tests correctly assert cardinality limit is enforced: verifies `length(metrics) == limit` after overflow (line 39), checks warning log (line 34), and verifies per-metric isolation (line 82-84). Covered in both `ets_memory_bounds_test.exs` and `resource_limits_test.exs`. |
| sec-004 | VERIFIED (weak) | Tests assert log warning about batch limit exceeded (line 110-111) and "dropped" text. Does NOT verify the actual batch size post-operation — only that a warning was logged. Missing: `assert length(current_batch) <= batch_limit`. |
| sec-005 | UNVERIFIED | `injection_prevention_test.exs:89-106` — Test creates a log record with injection payload and asserts `result == :ok`. This only tests non-crash, not that the output doesn't contain injected content. No assertion on the actual exported log format. The test doesn't call any format/render function to verify the injection is neutralized. |
| sec-006 | VERIFIED (weak) | Tests verify config values exist (`tls_verify == true`, secure TLS versions). But most tests SET the config first (`Application.put_env` at line 13, 41) then read it back — this is tautological. Line 48 `assert match?({:ok, _}, result) or match?({:error, _}, result)` accepts ANY outcome. The "remote host warns" tests (lines 67-74) are the strongest — they verify actual behavior. |
| sec-007 | UNVERIFIED | **Critical gap**: `validate_endpoint_url/1` in `lib/observlib/http.ex:60-76` only checks scheme, userinfo, and host presence. It does NOT block internal IPs (`169.254.169.254`, `10.x.x.x`, `172.16.x.x`, `192.168.x.x`, `metadata.google.internal`). The test at `url_validation_test.exs:130-131` includes `http://169.254.169.254/latest/meta-data/` and `http://metadata.google.internal/...` in the SSRF test — these have `http` scheme, no userinfo, valid host → they PASS validation and the test assertion `match?({:error, _}, result)` will FAIL. This is either (a) a broken test or (b) tests have never been run. |
| sec-008 | VERIFIED | PrometheusReader implements connection limiting (line 148), rate limiting via token bucket (line 153), and optional Basic Auth (line 240). These are tested in `prometheus_reader_test.exs:198,294`. |
| sec-009 | VERIFIED | `resource_limits_test.exs:10-19` correctly asserts truncation: `String.ends_with?(result["large_data"], "...[TRUNC]")` and `byte_size(result["large_data"]) <= 4096`. Property test verifies arbitrary sizes (line 58-70). |
| sec-010 | VERIFIED (weak) | Tests verify span count tracking and cleanup (start 100, end them, verify 0). But there is no test for a hard UPPER LIMIT on active spans — if 1M spans are started, they all succeed. The "stale span cleanup" test (line 139-153) only checks the span exists, not that cleanup actually fires. |
| sec-011 | VERIFIED | `resource_limits_test.exs:74-87` asserts `map_size(result) <= 128`, checks warning log. Property test covers arbitrary counts. |
| sec-012 | VERIFIED (header redaction) / UNVERIFIED (header injection) | Header redaction tests in `header_redaction_test.exs` thoroughly test `redact_sensitive_headers/1`. BUT: the value-based "bearer" detection test at line 109-119 expects `"Custom-Auth" => "Bearer custom_secret"` to be redacted. Implementation at `http.ex:117` only checks key names, not values. `"custom-auth"` doesn't contain any of the sensitive patterns → this test likely FAILS. The injection test at `injection_prevention_test.exs:126-145` only asserts `:ok` return. |
| sec-013 | VERIFIED | Thorough tests verify `:protected` mode on all 3 ETS tables, verify write/delete/clear failures from external processes, and confirm table owners are the correct GenServer PIDs. |
| sec-014 | UNVERIFIED | **Critical gap**: `injection_prevention_test.exs:7-23` records a metric with CRLF injection and asserts `length(metrics) > 0`. This ONLY checks the metric was stored — it NEVER calls `escape_label_value/1` or `format_prometheus_output/1` to verify the output is safe. The actual escape function exists at `prometheus_reader.ex:520-528` and looks correct, but no test verifies the escape produces safe Prometheus text output. |

### Test Gaps

| File:Line | What It Asserts | What It Should Assert |
|-----------|----------------|----------------------|
| `injection_prevention_test.exs:23` | `length(metrics) > 0` | Format metrics via `PrometheusReader` and assert output doesn't contain raw `\r\n` or injected metric lines |
| `injection_prevention_test.exs:29,33,43,53,63` | `length(metrics) > 0` | Same — all 5 injection tests assert storage success, not output safety |
| `injection_prevention_test.exs:103,122,142` | `result == :ok` | Assert exported payload doesn't contain injected content |
| `tls_validation_test.exs:13-16` | Sets config then reads it back | Test that TLS options are actually applied to HTTP client requests |
| `tls_validation_test.exs:48` | `match?({:ok, _}, result) or match?({:error, _}, result)` | This accepts ANY outcome — vacuously true |
| `url_validation_test.exs:130-131` | `match?({:error, _}, result)` for AWS/GCP metadata URLs | Implementation does NOT block these — test will fail. Internal IP blocking not implemented. |
| `atom_exhaustion_test.exs:85` | Creates atoms via `String.to_atom/1` | Should use the tested `safe_to_atom/1` path, not bypass it |
| `ets_memory_bounds_test.exs:141-153` | Stale span exists | Should trigger cleanup timer and verify span is removed |
| `header_redaction_test.exs:109-119` | `"Custom-Auth"` with Bearer value is redacted | Implementation only checks keys, not values — test will fail |

---

## Phase 2: New Attack Surfaces

### NEW-001: Pyroscope URL Parameter Injection via Label Keys
- **Severity: HIGH**
- **File:Line:** `lib/observlib/pyroscope/client.ex:443-448`
- **Attack scenario:** `build_ingest_url/3` constructs URL as:
  ```elixir
  labels_string =
    labels_with_service
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(",")

  "#{endpoint}/ingest?name=#{URI.encode(labels_string)}&spyName=elixir&sampleRate=#{@default_sample_rate}"
  ```
  The label keys and values are interpolated WITHOUT escaping before `URI.encode/1` is applied to the whole labels_string. However, `URI.encode/1` encodes most special chars EXCEPT `&`, `=`, and `,` which are considered "unreserved" by some URI encode implementations. Let me be precise: Elixir's `URI.encode/1` does NOT encode `&` or `=` characters (it only percent-encodes chars that are not "unreserved" per RFC 3986 — but `&` and `=` ARE reserved and WOULD be encoded by `URI.encode/1`).

  Actually, `URI.encode/1` in Elixir encodes characters that are not in the "unreserved" set (alpha, digit, `-`, `.`, `_`, `~`). So `&` and `=` WILL be percent-encoded inside the `name=` parameter value. This means `URI.encode/1` provides protection against URL parameter injection.

  **However**, the comma separator used in `Enum.join(",")` is also percent-encoded, which means the Pyroscope server would receive `%2C` instead of `,` as label separator. This suggests the encoding may be wrong for Pyroscope's expected format, or there's a custom decoder on the server side.

  **Revised severity: MEDIUM** — `URI.encode/1` does encode `&` and `=`, preventing direct URL parameter injection. But the label key/value content is not validated or sanitized — arbitrary binary content flows in. If Pyroscope has its own parsing logic that handles the comma-separated format, a label value containing `,` could inject additional labels (e.g., value `"foo,admin=true"` → after encoding and potential server-side decoding → extra label).
- **Recommended fix:** Use `URI.encode_www_form/1` for each key and value individually before joining:
  ```elixir
  labels_string =
    labels_with_service
    |> Enum.map(fn {k, v} -> "#{URI.encode_www_form(to_string(k))}=#{URI.encode_www_form(to_string(v))}" end)
    |> Enum.join(",")
  ```
- **Test strategy:** Assert that a label key like `"foo&malicious=evil"` produces a URL where `&` is percent-encoded in the `name=` parameter.

### NEW-002: Prometheus gen_tcp Request Smuggling / DoS
- **Severity: LOW**
- **File:Line:** `lib/observlib/metrics/prometheus_reader.ex:96-101, 234`
- **Attack scenario:** The gen_tcp listener uses `packet: :http_bin` which delegates HTTP parsing to Erlang's built-in HTTP packet parser. This parser:
  - Has built-in limits on header sizes (Erlang's default is ~8KB per header line)
  - Automatically rejects malformed HTTP (handles request smuggling)
  - The `recv` timeout is 5000ms (line 234)
  - Connection limit is enforced (default 10, line 148)
  - Rate limiting is enforced (line 153)

  The main risk vector is slowloris-style attacks: an attacker opens 10 connections (max) and holds them open by sending data slowly. Each connection blocks a `spawn`ed process. With only 10 max connections, legitimate scrapers are blocked.

  **But**: this is an internal metrics endpoint, typically not internet-facing. The 5-second timeout on `recv` limits exposure.
- **Recommended fix:** Consider adding a per-connection total timeout (e.g., 30s) and connection idle timeout. For production, consider using `Ranch` or `Plug.Cowboy` instead of raw gen_tcp.
- **Test strategy:** Open max_connections, hold them, verify 11th connection is rejected.

### NEW-003: Non-Constant-Time Credential Comparison
- **Severity: HIGH**
- **File:Line:** `lib/observlib/metrics/prometheus_reader.ex:400-413`
- **Attack scenario:** The `authorized?/2` function compares credentials using `==`:
  ```elixir
  credentials == "#{username}:#{password}"
  ```
  Elixir's `==` on binaries uses `erlang:'=='/2` which is NOT constant-time — it short-circuits on the first differing byte. An attacker can perform a timing attack to determine the password character-by-character by measuring response times.

  **Practical exploitability:** Requires network-level timing precision (~microseconds). Over a local network this is feasible with enough samples. Over the internet, typically requires thousands of requests per character but has been demonstrated in practice.

  **Blast radius:** Full access to metrics endpoint → information disclosure of all application metrics, potentially including business-sensitive data.
- **Recommended fix:** Use constant-time comparison:
  ```elixir
  # BAD
  credentials == "#{username}:#{password}"

  # GOOD
  :crypto.hash_equals(credentials, "#{username}:#{password}")
  ```
  Note: `:crypto.hash_equals/2` is available in OTP 25+. For older OTP, use `Plug.Crypto.secure_compare/2` if Plug is available, or implement byte-by-byte XOR comparison.
- **Test strategy:** Unit test that verifies `authorized?/2` returns correct results. Timing test is difficult in CI but can verify the function uses `:crypto.hash_equals/2`.

### NEW-004: PII Leakage via Unvalidated Telemetry Metadata in Span Attributes
- **Severity: HIGH**
- **File:Line:** `lib/observlib/telemetry.ex:217-229`
- **Attack scenario:** `handle_event/4` takes ALL metadata keys and passes them directly as span attributes:
  ```elixir
  attributes =
    metadata
    |> Map.take(Map.keys(metadata))  # This is a no-op — takes ALL keys
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
      Map.put(acc, key, v)
    end)
  ```
  `Map.take(Map.keys(metadata))` is equivalent to the identity function — it takes all keys. There is NO call to `ObservLib.Attributes.validate/1` which would apply redaction of sensitive keys like `password`, `token`, `secret`, etc.

  Phoenix telemetry events include metadata like `conn` (which may contain `params` with passwords), Ecto events include query parameters. This means:
  - `[:phoenix, :router_dispatch, :stop]` → metadata contains `conn.params` which may have `%{"password" => "user_secret"}`
  - `[:ecto, :query]` → metadata contains `params` which may have sensitive query values

  All of this flows into OpenTelemetry spans and gets exported to the configured backend (Jaeger, Tempo, etc.) WITHOUT redaction.
- **Recommended fix:**
  ```elixir
  # After building attributes map:
  {:ok, sanitized_attributes} = ObservLib.Attributes.validate(attributes)
  span_opts = %{attributes: sanitized_attributes}
  ```
- **Test strategy:** Emit a telemetry event with `%{password: "secret"}` in metadata, capture the span, assert the `password` attribute is `"[REDACTED]"`.

### NEW-005: Config GenServer as Single Point of Failure
- **Severity: MEDIUM**
- **File:Line:** `lib/observlib/config.ex:23-25`, `lib/observlib/application.ex:31`
- **Attack scenario:** Every hot-path operation (metrics recording, log export, etc.) calls `GenServer.call(__MODULE__, ...)` synchronously with the default 5000ms timeout. The supervision strategy is `:one_for_one` (line 31 of `application.ex`).

  Impact scenarios:
  1. **Config crash**: If Config crashes (e.g., due to a malformed config update), it restarts, but all in-flight `GenServer.call` callers get `{:EXIT, ...}` errors. Since metrics/logs/traces all depend on Config, this cascades.
  2. **Mailbox flooding**: If many processes call Config simultaneously (e.g., high-throughput metric recording), the GenServer mailbox grows unbounded, increasing latency.
  3. **Timeout cascade**: Under load, if Config is slow, callers timeout after 5s, causing upstream timeouts.

  The config values are essentially static after init — they don't change at runtime. Using a GenServer for read-only config is architecturally suboptimal.
- **Recommended fix:** Replace `GenServer.call` with `:persistent_term` for read-heavy config:
  ```elixir
  # In init/1, after building state:
  :persistent_term.put({__MODULE__, :cardinality_limit}, state.cardinality_limit)

  # Public API:
  def cardinality_limit, do: :persistent_term.get({__MODULE__, :cardinality_limit})
  ```
  Or use ETS with `:read_concurrency` for config that may change at runtime.
- **Test strategy:** Benchmark Config calls under concurrent load. Verify system survives Config process crash/restart.

### NEW-006: Non-Atomic Application.put_env in OTLP Trace Exporter Setup
- **Severity: LOW**
- **File:Line:** `lib/observlib/exporters/otlp_trace_exporter.ex:164-187`
- **Attack scenario:** `configure_exporter_app/1` and `configure_opentelemetry_app/1` make multiple sequential `Application.put_env/3` calls:
  ```elixir
  Application.put_env(:opentelemetry_exporter, :otlp_protocol, config.protocol)
  Application.put_env(:opentelemetry_exporter, :otlp_traces_endpoint, config.endpoint)
  Application.put_env(:opentelemetry_exporter, :otlp_traces_compression, config.compression)
  # ...
  Application.put_env(:opentelemetry, :span_processor, :batch)
  Application.put_env(:opentelemetry, :traces_exporter, :otlp)
  ```
  If two processes call `setup/0` concurrently, the config could end up in an inconsistent state (e.g., endpoint from call A, compression from call B).

  **Practical impact:** `setup/0` is called once during `Application.start` (line 61 of `application.ex`), so concurrent calls are unlikely in practice. This is a defense-in-depth concern.
- **Recommended fix:** Add a flag or use `Application.put_all_env/2` if atomicity is needed:
  ```elixir
  Application.put_all_env([
    {:opentelemetry_exporter, [
      otlp_protocol: config.protocol,
      otlp_traces_endpoint: config.endpoint
    ]}
  ])
  ```
- **Test strategy:** Verify setup is idempotent by calling it twice and checking config consistency.

### NEW-007: Silent Log Loss in forward_to_exporter/1
- **Severity: MEDIUM**
- **File:Line:** `lib/observlib/logs/backend.ex:323-331`
- **Attack scenario:** The function rescues ALL exceptions and returns `:ok`:
  ```elixir
  defp forward_to_exporter(log_record) do
    try do
      ObservLib.Exporters.OtlpLogsExporter.add_to_batch([log_record])
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
  ```
  If the OtlpLogsExporter crashes, is unavailable, or raises errors, ALL log records are silently dropped with no metric, no warning, and no indication to operators. This could mask:
  - Exporter configuration errors
  - Network failures to the OTLP collector
  - Memory pressure in the exporter

  For an observability library, silently losing telemetry data is a significant issue — operators lose visibility precisely when they need it most.
- **Recommended fix:** Add a counter for dropped logs and periodic warning:
  ```elixir
  defp forward_to_exporter(log_record) do
    try do
      ObservLib.Exporters.OtlpLogsExporter.add_to_batch([log_record])
    rescue
      e ->
        :telemetry.execute([:observlib, :logs, :drop], %{count: 1}, %{reason: inspect(e)})
        :ok
    catch
      :exit, reason ->
        :telemetry.execute([:observlib, :logs, :drop], %{count: 1}, %{reason: inspect(reason)})
        :ok
    end
  end
  ```
- **Test strategy:** Kill the OtlpLogsExporter, send logs, verify telemetry drop event is emitted.

### NEW-008: Transitive Security Dependencies Not Pinned
- **Severity: LOW**
- **File:Line:** `mix.exs:31-49`
- **Attack scenario:** `finch` (HTTP client) and `tls_certificate_check` (TLS verification) are NOT listed as direct deps in `mix.exs`. They are transitive dependencies pulled in by `req`. The deps are:
  ```elixir
  {:req, "~> 0.4"}
  ```
  If `mix deps.update req` pulls a new `req` version that bumps `finch` to a version with a vulnerability, there's no version constraint to prevent it. The `~> 0.4` constraint allows any 0.4.x or potentially 0.5.x+ update.

  **Practical impact:** `mix.lock` pins exact versions, so this only matters when explicitly running `mix deps.update`. This is standard Elixir dependency management — not a vulnerability per se, but a supply chain hygiene concern.
- **Recommended fix:** Add explicit version constraints for security-critical transitive deps:
  ```elixir
  {:finch, "~> 0.18"},           # HTTP client - pin for security
  {:tls_certificate_check, "~> 1.18"},  # TLS verification
  ```
  Or document in CLAUDE.md that `mix deps.update req` should trigger a security review.
- **Test strategy:** Run `mix deps.audit` or `mix hex.audit` to check for known vulnerabilities.

### NEW-009: PII Leakage — Map.take Identity Operation
- **Severity: HIGH** (same root cause as NEW-004, included for completeness)
- **File:Line:** `lib/observlib/telemetry.ex:222-223`
- **Code:**
  ```elixir
  metadata
  |> Map.take(Map.keys(metadata))
  ```
  This is semantically `metadata |> identity()`. The `Map.take/2` call takes all keys from the metadata — it filters nothing. This appears to be an incomplete implementation where a whitelist of allowed keys was intended but never filled in.
- **Recommended fix:** Either:
  1. Define an explicit allowlist: `Map.take(metadata, @allowed_span_attributes)`
  2. Or pipe through `ObservLib.Attributes.validate/1` for redaction
- **Test strategy:** Same as NEW-004.

### NEW-010: Header Redaction Value Check Missing (discovered during Phase 1)
- **Severity: MEDIUM**
- **File:Line:** `lib/observlib/http.ex:104-127`
- **Attack scenario:** `redact_sensitive_headers/1` only checks header keys against sensitive patterns. It does NOT check header values for sensitive content. A header like `"Custom-Auth" => "Bearer token123"` would NOT be redacted because `"custom-auth"` doesn't match any sensitive pattern.

  The test at `header_redaction_test.exs:109-119` expects value-based redaction to work, but the implementation doesn't support it. This test likely fails.
- **Recommended fix:** Add value-based redaction:
  ```elixir
  # BAD - only checks key
  should_redact = Enum.any?(sensitive_patterns, fn pattern ->
    String.contains?(key_lower, pattern)
  end)

  # GOOD - checks both key and value
  value_str = if is_binary(value), do: String.downcase(value), else: ""
  should_redact = Enum.any?(sensitive_patterns, fn pattern ->
    String.contains?(key_lower, pattern) or String.contains?(value_str, pattern)
  end)
  ```
- **Test strategy:** The existing test at `header_redaction_test.exs:109-119` already covers this — once the fix is applied, it should pass.

---

## Summary of Severity Ratings

| ID | Severity | Category |
|----|----------|----------|
| NEW-004/009 | **HIGH** | PII leakage via unredacted telemetry metadata → spans |
| NEW-003 | **HIGH** | Timing attack on Basic Auth credentials |
| NEW-001 | **MEDIUM** | Pyroscope label injection (partially mitigated by URI.encode) |
| NEW-005 | **MEDIUM** | Config GenServer SPOF on hot path |
| NEW-007 | **MEDIUM** | Silent log loss masks operational failures |
| NEW-010 | **MEDIUM** | Header value-based secrets not redacted |
| sec-007 | **HIGH** | SSRF: internal IPs not blocked, test likely broken |
| sec-014 | **MEDIUM** | Escape function exists but tests don't verify output |
| sec-005 | **MEDIUM** | Log injection tests only assert non-crash |
| NEW-002 | **LOW** | gen_tcp slowloris (mitigated by connection limits + timeout) |
| NEW-006 | **LOW** | Non-atomic config setup (single-call-site in practice) |
| NEW-008 | **LOW** | Transitive deps not pinned (standard mix behavior) |
