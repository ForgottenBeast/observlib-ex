# Deep Security Audit of ObservLib v0.1.0

**Date**: 2026-04-23
**Mode**: RALPLAN-DR (Deliberate)
**Complexity**: HIGH
**Scope**: Full codebase security audit -- 22 source files, 8 security test files, 4 threat model docs, dependency chain

---

## RALPLAN-DR Summary

### Principles

1. **Defense in Depth** -- Every layer must independently enforce security boundaries; no layer can assume another layer has validated input.
2. **Secure by Default** -- All security features (TLS, redaction, rate limiting) must be enabled without explicit configuration.
3. **Fail Closed** -- Security check failures must block operations, not silently pass them through.
4. **Minimal Attack Surface** -- Library code that handles untrusted input must be minimal and auditable.
5. **Verifiable Coverage** -- Every security claim in documentation must map to a test that exercises the actual defense path.

### Decision Drivers

1. **Remediation Completeness** -- The 14 existing findings were self-reported as "all remediated." An independent audit must verify that each fix actually prevents the stated attack, not just exercises the happy path.
2. **Undiscovered Attack Surface** -- Several code paths (Pyroscope URL building, `gen_tcp`-based Prometheus server, telemetry handler atom creation, log backend handler) process untrusted input without coverage in the existing 14 findings.
3. **Supply Chain Integrity** -- The `telemetry_metrics` major version bump (0.6 -> 1.0) in uncommitted changes could introduce behavioral changes affecting security-relevant metric definitions.

### Viable Options

**Option A: Phased Deep Audit (Recommended)**
- 4-phase audit: Verify existing fixes, discover new attack surfaces, review supply chain + docs, then synthesize and test.
- Pros: Systematic coverage, catches both false positives in existing fixes and unknown gaps. Audit report has clear traceability. Test gaps are filled during the audit.
- Cons: Requires 4-6 focused executor sessions. May surface issues that require code changes before the audit report is finalized.

**Option B: Red-Team Focused Audit**
- Skip verification of existing fixes. Focus entirely on adversarial attack discovery via crafted inputs and exploit chains.
- Pros: Faster to uncover novel vulnerabilities. High-impact findings.
- Cons: Misses regression risk if existing fixes are subtly incomplete (e.g., `escape_control_chars` double-escaping `\n`/`\r`/`\t`). Existing test gaps remain undetected. Does not validate documentation accuracy.

---

## ADR (Architectural Decision Record)

**Decision**: Phased Deep Audit (Option A)
**Drivers**: Remediation completeness, undiscovered attack surface, supply chain integrity
**Alternatives considered**: Red-Team Focused Audit (Option B)
**Why chosen**: The library already claims 14 remediated findings with "89+ security test cases." The highest-risk scenario is that these claims are false or incomplete, which only a verification-first approach can catch. Novel discovery is included in Phase 2.
**Consequences**: Longer audit timeline. Report will include both "verified" and "newly discovered" findings, which provides a clearer picture for stakeholders.
**Follow-ups**: After audit, a security regression test suite should be formalized and run in CI.

---

## Pre-Mortem: 3 Failure Scenarios

### Failure 1: Prometheus Label Escape Double-Processing
The `escape_label_value/1` function in `PrometheusReader` first replaces `\n`/`\r`/`\t` with escape sequences, then calls `escape_control_chars/1` which also matches chars 10 (LF), 13 (CR), 9 (TAB). This means already-escaped sequences like `\\n` get processed again by `escape_control_chars` which sees the original char codes. If the input contains literal `\n` bytes, the replacement in step 1 produces the string `\\n` (two chars: backslash + n), but `escape_control_chars` operates on the charlist of the *already-replaced* string -- so char 10 is no longer present. However, this interplay needs explicit verification to confirm no edge case exists with multi-byte sequences or mixed input.

**Impact**: Corrupted Prometheus output that breaks scraper parsing.
**Detection**: Property-based test with StreamData generating all 256 byte values in label positions.

### Failure 2: Pyroscope URL Injection via Labels
`build_ingest_url/3` in `Pyroscope.Client` constructs a URL by joining label key-value pairs with `=` and `,`, then passes the whole string through `URI.encode/1`. However, label *keys* are not sanitized -- if user-controlled labels contain `&`, `=`, or `/`, the URL structure can be manipulated. An attacker who calls `add_labels(%{"&spyName" => "evil"})` could inject query parameters.

**Impact**: Request routing manipulation on the Pyroscope server.
**Detection**: Test with adversarial label keys containing URL-special characters.

### Failure 3: Timing-Based Auth Bypass on Prometheus Basic Auth
The `authorized?/2` function in `PrometheusReader` uses `==` for credential comparison (`credentials == "#{username}:#{password}"`). The Erlang `==` operator for binaries is *not* constant-time -- it short-circuits on first differing byte. This enables timing attacks against the Basic Auth credentials.

**Impact**: Credential extraction via timing side channel on the Prometheus endpoint.
**Detection**: Code review finding. Recommend `:crypto.hash_equals/2` or `Plug.Crypto.secure_compare/2`.

---

## Work Plan: Detailed Phases

### Phase 1: Verify Existing 14 Findings (sec-001 through sec-014)

**Objective**: For each of the 14 findings, verify that (a) the defense code path is exercised by tests, (b) the test actually asserts the security property (not just "no crash"), and (c) the defense cannot be bypassed.

**Files to audit**:
- `test/security/atom_exhaustion_test.exs` -- verify sec-001/002
- `test/security/ets_memory_bounds_test.exs` -- verify sec-003/004/010
- `test/security/injection_prevention_test.exs` -- verify sec-005/012/014
- `test/security/tls_validation_test.exs` -- verify sec-006
- `test/security/url_validation_test.exs` -- verify sec-007
- `test/security/resource_limits_test.exs` -- verify sec-008/009/011
- `test/security/header_redaction_test.exs` -- verify sec-012
- `test/security/access_control_test.exs` -- verify sec-013

**Specific checks**:
1. sec-001/002 (Atom safety): Does `ObservLib.Telemetry.handler_id/1` actually use `String.to_atom/1` (line 259)? If so, is the input validated to come only from code (not user input)? Verify that the atom table is bounded.
2. sec-003/010 (ETS cardinality): Does `check_cardinality_limit/4` in `MeterProvider` actually count correctly? What happens at exactly limit=2000? Off-by-one? What if two concurrent casts both check simultaneously before either inserts?
3. sec-005 (Log injection): The test at `injection_prevention_test.exs:89-105` only checks `result == :ok` -- it does not verify that the exported payload escapes newlines. This is a test gap.
4. sec-006 (TLS): Does `build_ssl_options/4` actually set `verify: :verify_peer` and include CA certs? What happens when `tls_verify` config is missing (default path)?
5. sec-007 (SSRF/URL validation): The URL `http://169.254.169.254/latest/meta-data/` passes validation because it has scheme=http and a valid host. The SSRF test at line 130 expects it to be rejected, but `validate_endpoint_url/1` only checks scheme/userinfo/host -- it does not block internal IPs. **This is likely a test bug or a false positive in the existing coverage**.
6. sec-008 (Rate limiting): Is the token bucket implementation in `PrometheusReader` thread-safe? The rate limiter state is in the GenServer, but `handle_info({:new_connection, socket}, state)` processes connections sequentially -- this is correct for a single-process model. Verify.
7. sec-009/011 (Attribute limits): Does `truncate_value/2` handle negative `truncate_length` when `max_size < byte_size("...[TRUNC]")`? That would crash with a `MatchError`.
8. sec-012 (Header redaction): Does `redact_sensitive_headers/1` cover the full list? Is `"cookie"` missing from the sensitive patterns?
9. sec-013 (ETS access): Are both tables (`:observlib_metrics`, `:observlib_metric_registry`) created with `:protected`? Verified yes in code, but does the test actually attempt a write from a foreign process?
10. sec-014 (Label injection): Does the `escape_control_chars/1` function produce correct output for all 256 byte values? The double-escape concern from Pre-Mortem 1.

**Acceptance criteria**:
- Each of the 14 findings has a "verified" or "unverified" status with rationale.
- At least 3 specific test gaps identified and documented.
- Any false positive in existing tests is flagged.

---

### Phase 2: Discover New Attack Surfaces

**Objective**: Identify security-relevant code paths not covered by the existing 14 findings.

**Files to audit**:
- `lib/observlib/pyroscope/client.ex` -- URL construction, label injection (lines 439-448)
- `lib/observlib/metrics/prometheus_reader.ex` -- `gen_tcp` server, auth bypass, request parsing (lines 226-264)
- `lib/observlib/telemetry.ex` -- atom creation in `handler_id/1` (line 259), metadata pass-through in `handle_event/4` (lines 217-246)
- `lib/observlib/logs/backend.ex` -- `Handler.log/2` processes arbitrary log messages (lines 341-393)
- `lib/observlib/exporters/otlp_logs_exporter.ex` -- retry logic, exponential backoff bounds (line 428-433)
- `lib/observlib/exporters/otlp_trace_exporter.ex` -- `Application.put_env/3` calls (lines 164-188)
- `lib/observlib/traced.ex` -- macro safety, code generation patterns
- `lib/observlib/config.ex` -- GenServer as single point of failure, config injection

**Specific new findings to investigate**:

**NEW-001: Pyroscope URL Injection**
- `build_ingest_url/3` at line 439-448 of `pyroscope/client.ex` constructs URLs by string interpolation with user-controlled labels.
- Label keys and values are NOT sanitized before URL construction.
- `URI.encode/1` is called on the combined labels string, but this only encodes the `name` parameter value -- keys containing `&` or `=` could break URL structure.
- Check: Can `add_labels(%{"&malicious" => "payload"})` inject query parameters?

**NEW-002: Prometheus gen_tcp Request Smuggling**
- `do_handle_request/2` at line 233 uses `:gen_tcp.recv/3` with `packet: :http_bin`, which is Erlang's built-in HTTP parser.
- Check: Does the parser handle HTTP request smuggling (e.g., `Transfer-Encoding: chunked` with `Content-Length`)? Since the server only reads the request line and headers (no body), this may be low risk.
- Check: What happens with extremely large headers? Is there a receive buffer limit?

**NEW-003: Timing Attack on Basic Auth**
- `authorized?/2` at line 400-413 uses `==` for credential comparison.
- Check: This is not constant-time. Document as a finding with severity based on whether Prometheus endpoint is typically internal-only.

**NEW-004: Metadata Pass-Through in Telemetry Handler**
- `handle_event/4` at line 217-246 passes all metadata keys through `Atom.to_string/1` (safe) but does NOT validate or redact attribute values before setting them on spans.
- Check: If a Phoenix telemetry event emits metadata containing passwords or tokens (e.g., `conn.assigns`), these become span attributes without redaction.

**NEW-005: Config GenServer as SPOF**
- `ObservLib.Config` is a GenServer. If it crashes or becomes unresponsive, all `ObservLib.Config.get/2` calls (used in `Attributes.validate/1`, `MeterProvider`, etc.) will timeout.
- Check: Are there `:timeout` values on the GenServer.call? Default is 5000ms. Could a slow config lookup cascade into attribute validation failures?

**NEW-006: `Application.put_env` in Trace Exporter**
- `configure_exporter_app/1` and `configure_opentelemetry_app/1` in `OtlpTraceExporter` call `Application.put_env/3` at runtime.
- Check: These calls are global and not atomic. If multiple processes call `setup/0` concurrently, configuration could be inconsistent.

**NEW-007: Log Backend Silently Swallows Errors**
- `forward_to_exporter/1` at line 323-331 of `backend.ex` rescues all exceptions and returns `:ok`.
- Check: This means if the exporter is down, logs are silently lost with no indication. Is there a metric or log for "logs dropped"?

**NEW-008: Missing `finch` and `tls_certificate_check` in deps**
- `mix.exs` lists `req ~> 0.4` but does not explicitly list `finch` or `tls_certificate_check` as dependencies.
- The task context says `finch ~> 0.21.0` and `tls_certificate_check ~> 1.18.0` -- these may be transitive through `req`.
- Check: Are security-relevant transitive deps pinned, or could `mix deps.update req` silently pull a compromised version?

**Acceptance criteria**:
- At least 5 new findings documented with severity (Critical/High/Medium/Low/Info).
- Each finding includes: description, affected file:line, attack scenario, recommended fix, test strategy.

---

### Phase 3: Supply Chain + Documentation Review

**Objective**: Review uncommitted changes, dependency versions, example code, and documentation accuracy.

**Files to audit**:
- `mix.exs` (modified) -- `telemetry_metrics` version bump from `~> 0.6` to `~> 1.0`
- `mix.lock` (modified) -- all dependency version changes
- `examples/phoenix_integration.exs` (modified) -- `summary/2` -> `distribution/2` change
- `SECURITY.md` -- claims accuracy
- `docs/book/security/threat-model.md` -- mapping completeness

**Specific checks**:

3a. **Dependency Version Audit**:
- Run `mix hex.audit` (or equivalent) to check for known CVE advisories against all deps.
- Verify `req ~> 0.4` is not affected by any known SSRF or redirect-following vulnerabilities.
- Check if `opentelemetry_exporter ~> 1.6` has any known issues.
- Confirm `jason ~> 1.4` is current.

3b. **telemetry_metrics 1.0 Breaking Change Review**:
- `summary/2` was removed in 1.0. The example was updated to `distribution/2`.
- Check: Does any ObservLib code internally use `summary/2`? If the library transitively depends on the metric type, this is a runtime error.
- Check: Does `distribution/2` have the same security characteristics as `summary/2` for label handling?

3c. **Phoenix Example Security Anti-Patterns**:
- Line 18 in example: `otlp_endpoint: System.get_env("OTLP_ENDPOINT")` -- this is evaluated at compile time in a config file, not runtime. Is there a warning about this?
- Line 133-159: `log_response/1` puts `conn.request_path` directly into log attributes. If the path contains PII or injection payloads, this is logged without redaction.
- Line 147-156: `conn.status` and `conn.method` are used as metric attributes. `conn.method` could be any string from the request -- is there cardinality risk if an attacker sends unusual HTTP methods?

3d. **Documentation Accuracy**:
- Threat model claims "89+ security test cases" -- verify actual count.
- Threat model code examples (e.g., ETS table creation on line 476-483) show `:public` mode, but actual code uses `:protected`. This is a documentation error.
- SECURITY.md line 148 references `test/security/README.md` -- verify this file exists.
- SECURITY.md line 183 references `docs/book/security/threat-model.md` -- verify mapping accuracy.

**Acceptance criteria**:
- Dependency audit results documented (CVEs: yes/no for each dep).
- At least 2 documentation inaccuracies identified.
- Phoenix example security issues documented with recommended fixes.
- `telemetry_metrics` 1.0 impact assessment complete.

---

### Phase 4: Audit Synthesis + Test Gap Remediation

**Objective**: Produce final audit report, write missing security tests, and update threat model.

**Deliverables**:
1. **Audit Report** (`.omc/plans/security-audit-report.md`):
   - Executive summary with overall risk rating
   - Findings table: ID, Severity, Status (New/Verified/Unverified/False Positive), Description, File:Line, Fix Status
   - Recommendations ranked by risk
2. **New/Updated Security Tests** (targeted test files in `test/security/`):
   - Tests for NEW-001 through NEW-008 (new findings)
   - Strengthened tests for any existing findings found to be inadequately tested
3. **Updated Threat Model** if documentation inaccuracies were found

**Acceptance criteria**:
- Audit report covers all 14 existing + all newly discovered findings.
- Every finding rated Critical or High has a corresponding test.
- All existing security tests still pass after any new tests are added.
- `mix test --only security` passes with zero failures.

---

## Expanded Test Plan

### Unit Tests
- **Attribute redaction edge cases**: Empty string keys, non-string keys, nested map values, list attribute values with sensitive-looking strings inside.
- **URL validation bypass attempts**: URLs with encoded characters (`%66%69%6C%65` = "file"), unicode homoglyphs, backslash URLs (`http:\\\\host`), scheme-less URLs.
- **Truncation edge cases**: `max_size` smaller than suffix length, `max_size` of 0, UTF-8 multi-byte characters at truncation boundary.
- **Label escaping completeness**: Property-based test using StreamData to generate all 256 byte values and verify round-trip safety.
- **Pyroscope URL construction**: Adversarial label keys/values with URL metacharacters.
- **Rate limiter**: Boundary testing at exactly `max_tokens`, time-based refill accuracy.

### Integration Tests
- **Prometheus auth timing**: Verify auth check does not leak timing information (or document as accepted risk).
- **TLS handshake**: Verify that `post/3` with an HTTPS URL to a self-signed cert fails when `tls_verify: true`.
- **Config GenServer crash recovery**: Kill Config GenServer, verify that dependent modules either fail gracefully or recover via supervision.
- **OtlpLogsExporter under back-pressure**: Send 10x `batch_limit` logs, verify oldest are dropped and newest retained.
- **Concurrent cardinality enforcement**: Spawn 100 processes simultaneously recording metrics with unique attributes to test ETS race condition in `check_cardinality_limit/4`.

### End-to-End Tests
- **Full telemetry pipeline**: Phoenix event -> telemetry handler -> span creation -> trace export. Verify no sensitive metadata leaks through.
- **Prometheus scrape with injection**: Start PrometheusReader, record metrics with adversarial labels, scrape `/metrics`, parse output and verify no injected metric families appear.
- **Log pipeline with PII**: Send log with sensitive attributes through Backend -> OtlpLogsExporter -> verify redaction applied in exported payload.

### Observability of Security Events
- **Security event logging**: Verify that each security enforcement action (cardinality limit hit, attribute truncation, rate limit triggered, auth failure) produces a structured log event that monitoring can alert on.
- **Metrics for security events**: Check if the library exposes counters for: rejected connections, rate-limited requests, redacted attributes, truncated values.

---

## Success Criteria

1. All 14 existing findings have a verified/unverified status with evidence.
2. At least 5 new security findings documented with severity and recommended fix.
3. Zero false claims in SECURITY.md or threat-model.md (or all inaccuracies documented).
4. Dependency audit shows no known unpatched CVEs.
5. Phoenix example has all security anti-patterns identified and documented.
6. `mix test --only security` passes with expanded test coverage.
7. Final audit report saved to `.omc/plans/security-audit-report.md`.

---

## Guardrails

### Must Have
- Every finding must reference specific file and line number.
- Every finding must have a severity rating (Critical/High/Medium/Low/Info).
- Existing passing tests must not be broken.
- Audit must cover all files in `lib/observlib/` -- no modules skipped.

### Must NOT Have
- No code changes without corresponding test.
- No severity ratings without an attack scenario.
- No "all clear" verdict without evidence (test output, code review notes).
- No changes to production code during Phase 1-3 (observation only). Code changes only in Phase 4.
