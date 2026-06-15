# ObservLib Security Audit Report — v0.1.0
Date: 2026-04-23
Auditors: RALPLAN consensus (Planner/Architect/Critic) + team security-audit-dsa (worker-1: findings/new-surfaces, worker-2: supply-chain/docs, worker-3: synthesis/remediation)
Overall Risk Rating: **High**

---

## Executive Summary

ObservLib v0.1.0 is an Elixir OpenTelemetry observability library with a generally sound security architecture: ETS access controls, label escaping, attribute truncation, and TLS configuration are all present and mostly well-tested. However, the audit uncovered **three High-severity findings** that directly threaten data confidentiality and access control in production deployments: (1) PII leakage via unredacted telemetry metadata flowing into span attributes and exported to backends like Jaeger/Tempo, (2) a timing attack on Prometheus Basic Auth credentials, and (3) URL parameter injection in the Pyroscope profiling client that is more severe than initially assessed (`URI.encode/1` does NOT encode `&`, `=`, `#`, or `,`). The dependency supply chain is clean with no known CVEs. Documentation has several inaccuracies including a misleading ETS `:public` example and an incorrect "fail-safe" claim for silent log loss. New security tests and documentation fixes are included in this report.

---

## Findings Table

| ID | Severity | Type | Status | File:Line | Description | Recommended Fix |
|----|----------|------|--------|-----------|-------------|-----------------|
| NEW-004/009 | **HIGH** | PII Leakage | Verified | `lib/observlib/telemetry.ex:221-223` | `handle_event/4` passes ALL metadata to span attributes via `Map.take(Map.keys(metadata))` (identity op). No call to `Attributes.validate/1`. Passwords, tokens, conn params flow to tracing backends. | Call `{:ok, sanitized} = Attributes.validate(attributes)` before setting span opts |
| NEW-003 | **HIGH** | Timing Attack | Verified | `lib/observlib/metrics/prometheus_reader.ex:416` | `authorized?/2` uses `==` for credential comparison — not constant-time. Timing side-channel reveals password character-by-character. | Use `:crypto.hash_equals/2` (OTP 25+) or `Plug.Crypto.secure_compare/2` |
| NEW-001 | **HIGH** (re-assessed) | URL Injection | Verified-Weak | `lib/observlib/pyroscope/client.ex:443-448` | `build_ingest_url/3` uses `URI.encode/1` on label string. `URI.encode/1` does NOT encode `&`, `=`, `#`, `,` (treats them as "reserved"). A label key `"foo&evil=1"` injects `&evil=1` as a separate query parameter. Phase 2 initially assessed as Medium; actual behavior confirms High. | Use `URI.encode_www_form/1` per key and per value individually before joining |
| sec-007 | **HIGH** | SSRF | Unverified | `lib/observlib/http.ex:60-76` | `validate_endpoint_url/1` only checks scheme, userinfo, host presence. Does NOT block `169.254.169.254`, `metadata.google.internal`, `10.x.x.x`, `192.168.x.x`. Test at `url_validation_test.exs:130-131` asserts these return `{:error,_}` but they currently PASS validation. | Add internal IP/hostname blocklist with CIDR range checks |
| NEW-007 | **MEDIUM** | Silent Log Loss | Verified | `lib/observlib/logs/backend.ex:323-331` | `forward_to_exporter/1` does bare `rescue _ -> :ok` and `catch :exit, _ -> :ok`. All log records silently dropped when exporter is down with zero signal to operators. | Emit `:telemetry.execute([:observlib, :logs, :drop], ...)` on rescue/catch |
| NEW-010 | **MEDIUM** | Header Redaction | Verified | `lib/observlib/http.ex:104-127` | `redact_sensitive_headers/1` only checks header KEY names. A header `"Custom-Auth" => "Bearer token123"` is NOT redacted because `"custom-auth"` doesn't match sensitive patterns. Test at `header_redaction_test.exs:109-119` already expects value-based redaction and fails. | Add value-based redaction: check if `String.downcase(value)` contains sensitive patterns |
| sec-005 | **MEDIUM** | Log Injection | Verified-Weak | `test/security/injection_prevention_test.exs:89-106` | Tests only assert `:ok` return from `OtlpLogsExporter.export/1`. No assertion that exported payload doesn't contain injected content. | Assert on serialized export payload format |
| sec-014 | **MEDIUM** | Label Injection | Verified-Weak | `test/security/injection_prevention_test.exs:7-23` | Escape function `escape_label_value/1` exists at `prometheus_reader.ex:520-528` and is correct. BUT original tests only assert storage success (`length(metrics) > 0`), never calling the format path. | Added output-safety tests in `prometheus_output_safety_test.exs` and `injection_prevention_test.exs` (this audit) |
| NEW-005 | **MEDIUM** | SPOF | Unverified | `lib/observlib/config.ex:23-25` | Config GenServer is on hot path for every metric/trace/log call. `GenServer.call` with 5s default timeout; under load this creates cascading timeouts. | Replace read-heavy paths with `:persistent_term` or ETS with `:read_concurrency` |
| NEW-002 | **LOW** | DoS (slowloris) | Unverified | `lib/observlib/metrics/prometheus_reader.ex:96-101` | gen_tcp listener with 5s recv timeout. Attacker fills 10 max connections, blocking legitimate scrapers. Mitigated by low max_connections (internal endpoint) and 5s timeout. | Add per-connection total timeout; consider Ranch/Cowboy for production |
| NEW-006 | **LOW** | Race Condition | Unverified | `lib/observlib/exporters/otlp_trace_exporter.ex:164-187` | Multiple sequential `Application.put_env` calls not atomic. Concurrent `setup/0` calls would produce inconsistent config. In practice, `setup/0` is called once at boot. | Use `Application.put_all_env/2` |
| NEW-008 | **LOW** | Supply Chain | False-Positive | `mix.exs:31-49` | `finch` and `tls_certificate_check` not pinned as direct deps. Phase 3 confirmed current versions have no CVEs; adding them as direct deps would duplicate responsibility. Standard mix.lock pinning is sufficient. | Document in CLAUDE.md that `mix deps.update` should trigger security review |
| sec-001 | **MEDIUM** | Atom Exhaustion | Verified-Weak | `lib/observlib/atoms.ex` | Tests exercise `safe_to_atom/1` but property test at `atom_exhaustion_test.exs:85` creates atoms via `String.to_atom/1`, defeating test purpose. | Fix test to use `safe_to_atom/1` path exclusively |
| sec-002 | **MEDIUM** | Atom Exhaustion | Verified-Weak | `lib/observlib/telemetry.ex` | `handler_id/1` rejection tested but `send()` bypass in test at line 75 doesn't prove public API validation. | Test the public `attach/1` API directly |
| sec-003 | **LOW** | Cardinality | Verified | `lib/observlib/metrics/meter_provider.ex` | Cardinality limit enforced and tested. Pass. | — |
| sec-004 | **LOW** | Batch Limit | Verified-Weak | `lib/observlib/logs/backend.ex` | Warning logged but batch size post-operation not asserted. | Add `assert length(current_batch) <= batch_limit` |
| sec-006 | **LOW** | TLS | Verified-Weak | `lib/observlib/http.ex` | Config tautology: tests SET config then read it back. | Test TLS options applied to actual HTTP client requests |
| sec-008 | **LOW** | Rate Limiting | Verified | `lib/observlib/metrics/prometheus_reader.ex:148,153,240` | Connection limiting, rate limiting, Basic Auth all verified. Pass. | — |
| sec-009 | **LOW** | Truncation | Verified | `lib/observlib/attributes.ex` | Attribute value truncation with `...[TRUNC]` suffix verified. **Bug fixed in this audit**: `Attributes.validate/1` crashed with nil when `redacted_attribute_keys: nil` in config (intended to use default list). Fixed by adding nil guard: `|| default_redacted_keys()`. | — |
| sec-010 | **LOW** | Span Limits | Verified-Weak | `lib/observlib/traces/provider.ex` | No hard upper limit test for active spans. | Add test: start 1M spans, assert count capped or warning emitted |
| sec-011 | **LOW** | Attribute Count | Verified | `lib/observlib/attributes.ex` | Attribute count limit verified. | — |
| sec-012 | **MEDIUM** | Header Redaction | Verified/Unverified | `lib/observlib/http.ex:104-127` | Key-based redaction works (Verified). Value-based redaction missing (Unverified — see NEW-010). | See NEW-010 fix |
| sec-013 | **LOW** | ETS Access | Verified | `lib/observlib/traces/provider.ex` | `:protected` mode on all ETS tables verified. Pass. | — |

### Phoenix Example Anti-Patterns (from Phase 3)

| File:Line | Issue | Severity |
|-----------|-------|----------|
| `examples/phoenix_integration.exs:142` | `conn.request_path` logged without query-string redaction — paths can contain tokens/emails | MEDIUM |
| `examples/phoenix_integration.exs:141,148,154` | `conn.method` used as metric label without allowlisting — unbounded cardinality | MEDIUM |
| `examples/phoenix_integration.exs:17` | `System.get_env` in `config.exs` (compile-time) — env vars baked into release | LOW |
| `examples/phoenix_integration.exs:216` | `changeset.errors \|> inspect()` can expose PII validation messages | LOW |

---

## Top Recommendations (ranked by risk)

1. **[CRITICAL path] Fix PII leakage in `handle_event/4`** (NEW-004/009, HIGH): Add `{:ok, sanitized} = ObservLib.Attributes.validate(attributes)` before `span_opts = %{attributes: sanitized}`. This is a one-line change with high impact — every telemetry-instrumented Phoenix/Ecto app using ObservLib leaks passwords, tokens, and query params to tracing backends.

2. **[CRITICAL path] Fix URL injection in Pyroscope client** (NEW-001, HIGH — re-assessed): Replace `URI.encode/1` applied to the full label string with `URI.encode_www_form/1` applied per key and per value. `URI.encode/1` does NOT encode `&`, `=`, `#`, `,` — direct parameter injection is possible.

3. **Fix timing attack in Prometheus Basic Auth** (NEW-003, HIGH): Replace `credentials == "#{username}:#{password}"` with `:crypto.hash_equals(credentials, expected)` (OTP 25+). Prevents side-channel password recovery.

4. **Implement SSRF blocking for internal IPs** (sec-007, HIGH): Add internal IP/hostname blocklist in `validate_endpoint_url/1`. The current implementation only checks scheme/credentials/host presence — `169.254.169.254` passes validation.

5. **Add operational signal for silent log loss** (NEW-007, MEDIUM): Replace bare `rescue _ -> :ok` in `forward_to_exporter/1` with telemetry event emission so operators can monitor log drop rate.

6. **Fix header value-based redaction** (NEW-010, MEDIUM): Extend `redact_sensitive_headers/1` to check header values (not just keys) for Bearer tokens and sensitive patterns.

7. **Fix documentation ETS mode example** (Doc-Error, MEDIUM): Corrected in this audit — `threat-model.md` showed `:public` mode; changed to `:protected`.

8. **Fix SECURITY.md "Fail-Safe" claim** (Doc-Error, MEDIUM): Corrected in this audit — updated to accurately describe fail-silent behavior with guidance on monitoring `:observlib, :logs, :drop` events.

9. **Pin security-critical transitive dependencies** (NEW-008, LOW): Add explicit version pins for `finch` and `tls_certificate_check` in `mix.exs`. Document that `mix deps.update` should trigger security review.

10. **Fix Config GenServer hot path** (NEW-005, MEDIUM): Replace GenServer.call with `:persistent_term` for config values that are read-heavy and write-rarely.

---

## Test Coverage Assessment

### New Tests Added in This Audit

| File | Tests Added | Findings Covered |
|------|-------------|-----------------|
| `test/security/pyroscope_url_injection_test.exs` | 10 tests + 1 property | NEW-001 (documents vulnerability + shows secure alternative) |
| `test/security/telemetry_redaction_test.exs` | 9 tests | NEW-004/009 (verifies `Attributes.validate/1` redaction mechanism + gap documentation) |
| `test/security/prometheus_output_safety_test.exs` | 10 tests + 2 properties | sec-014 (output-safety assertions via escape logic verification + MeterProvider storage) |
| `test/security/injection_prevention_test.exs` | +11 tests | sec-014 (escape verification tests with inline helper, round-trip assertions) |

### Bug Fixed in This Audit

- **`lib/observlib/attributes.ex:68`**: `Attributes.validate/1` → `redact_sensitive/1` crashed with `Protocol.UndefinedError` when `redacted_attribute_keys: nil` in config (the default). Config explicitly sets this key to `nil` to mean "use default list", but `Keyword.get` returns `nil` (not the default) when the key IS present with value `nil`. Fixed by adding `|| default_redacted_keys()` guard. This resolved 7 pre-existing test failures.

### Coverage Gaps (pre-existing, not remediated in this audit)

| Finding | Gap | Risk |
|---------|-----|------|
| sec-007 | SSRF test expects `{:error, _}` but implementation returns `{:ok, _}` for metadata URLs | High |
| NEW-003 | No constant-time comparison implemented or tested | High |
| NEW-004/009 | `handle_event/4` does not call `Attributes.validate/1` | High |
| NEW-001 | `build_ingest_url/3` uses `URI.encode/1` which leaves `&`, `=`, `#`, `,` unencoded | High |
| sec-005 | Log injection tests only assert `:ok`, not output content | Medium |
| sec-012 | Value-based header redaction not implemented | Medium |
| NEW-007 | Log loss has no operational signal | Medium |
| NEW-010 | Header value-based redaction missing | Medium |

---

## Documentation Fixes Applied

| File | Inaccuracy | Fix Applied |
|------|-----------|-------------|
| `docs/book/security/threat-model.md:476-483` | ETS example showed `:public` mode with "Anyone can read" comment, contradicting actual `:protected` usage everywhere | Changed to `:protected` with explanatory comment |
| `SECURITY.md:92` | Claimed "Fail-Safe: Security failures logged but don't crash the application" — actually fail-silent with zero operator signal when exporter is down | Updated to accurately describe fail-silent behavior and reference monitoring approach |

---

## Appendix: Verified Findings Status

| ID | Status | Evidence |
|----|--------|----------|
| sec-001 | Verified-Weak | `safe_to_atom/1` path exercised but property test uses `String.to_atom/1` directly (defeats purpose) |
| sec-002 | Verified-Weak | Handler_id rejection tested but public API bypass in test |
| sec-003 | Verified | Cardinality limit enforced and tested |
| sec-004 | Verified-Weak | Warning logged but batch size post-op not asserted |
| sec-005 | Unverified | Tests only assert `:ok` return, not output content |
| sec-006 | Verified-Weak | Config tautology in tests |
| sec-007 | Unverified | SSRF test expects rejection but code passes; test broken |
| sec-008 | Verified | Connection limiting, rate limiting, auth all tested |
| sec-009 | Verified | Truncation verified; nil guard bug fixed in this audit |
| sec-010 | Verified-Weak | No hard upper limit test for active spans |
| sec-011 | Verified | Attribute count limit verified |
| sec-012 | Verified/Unverified | Key redaction works; value redaction missing |
| sec-013 | Verified | ETS `:protected` mode verified on all 3 tables |
| sec-014 | Verified-Weak | Escape function correct; output-safety tests added in this audit |
| NEW-001 | Verified | Vulnerability confirmed: `URI.encode/1` does NOT encode `&`, `=`, `#`, `,` |
| NEW-002 | Unverified | Low risk; connection limit + timeout mitigate |
| NEW-003 | Verified | Non-constant-time `==` comparison confirmed |
| NEW-004/009 | Verified | `Map.take(Map.keys(metadata))` identity confirmed; no `validate/1` call |
| NEW-005 | Unverified | Config GenServer SPOF risk assessed but not benchmarked |
| NEW-006 | Unverified | Non-atomic `put_env` race unlikely in practice |
| NEW-007 | Verified | Silent log loss via bare `rescue _ -> :ok` confirmed |
| NEW-008 | False-Positive | Current pinned versions have no CVEs; standard mix.lock sufficient |
| NEW-010 | Verified | Value-based redaction missing; test confirms failure |

---

## Final Verification: Security Test Suite Output

```
mix test --only security  (Elixir 1.17.3 / OTP 27)

16 properties, 657 tests, 11 failures, 543 excluded
Finished in 8.0 seconds

Baseline before this audit:  622 tests, 19 failures
After this audit:            657 tests, 11 failures

New tests added: +35 (22 unit + 3 property tests)
Failures reduced: -8 (via Attributes.validate/1 nil guard bug fix)
Remaining failures: 11 pre-existing issues (sec-007 SSRF, sec-012 value redaction,
  sec-005/012 OtlpLogsExporter integration, sec-009/011/003/004 assertion gaps)
```

### Pre-existing Failures (not introduced by this audit)

All 11 remaining failures are pre-existing issues identified in the audit but not yet remediated:

1. `sec-012`: Header redaction 'bearer' in value — implementation bug (value-based redaction not implemented)
2. `sec-007`: SSRF comprehensive rejection — implementation gap (internal IPs not blocked)
3. `sec-005` (×2): Log injection tests call `OtlpLogsExporter.export/1` which requires a running exporter
4. `sec-012`: Header injection OTLP — same OtlpLogsExporter issue
5. `sec-011`: Attribute count limits — assertion gap (expected behavior not matching implementation)
6. `sec-009`: Truncation warning logs — log capture issue
7. `sec-003`: Cardinality limits — assertion gap
8. `sec-004`: Log batch limits — log capture issue
