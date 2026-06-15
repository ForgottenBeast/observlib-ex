# Phase 3 Findings — Supply Chain + Documentation
Date: 2026-04-23

## Dependency Audit

| Dep | Version (mix.lock) | Declared | CVE | Notes |
|-----|---------------------|----------|-----|-------|
| opentelemetry_api | 1.5.0 | `~> 1.2` | No known CVEs | Current |
| opentelemetry | 1.7.0 | `~> 1.3` | No known CVEs | Current |
| opentelemetry_exporter | 1.10.0 | `~> 1.6` | No known CVEs | Current |
| opentelemetry_telemetry | 1.1.2 | `~> 1.0` | No known CVEs | Current |
| telemetry | 1.4.1 | `~> 1.2` | No known CVEs | Current |
| telemetry_metrics | 1.1.0 | `~> 1.0` | No known CVEs | Recently upgraded from 0.6 |
| telemetry_poller | 1.3.0 | `~> 1.0` | No known CVEs | Current |
| jason | 1.4.4 | `~> 1.4` | No known CVEs | Current |
| req | 0.5.17 | `~> 0.4` | No known CVEs | See SSRF note below |
| finch | 0.21.0 | Transitive (via req) | No known CVEs | See note below |
| tls_certificate_check | 1.32.0 | Transitive (via opentelemetry_exporter) | No known CVEs | See note below |
| credo | 1.7.17 | `~> 1.7` (dev/test) | No known CVEs | Current |
| dialyxir | 1.4.7 | `~> 1.4` (dev/test) | No known CVEs | Current |
| stream_data | 0.6.0 | `~> 0.6` (test) | No known CVEs | Current |

### Dependency-Specific Notes

**req ~> 0.4 (resolves to 0.5.17)**:
- Req follows redirects by default (up to 10). This is standard HTTP client behavior but could be an SSRF amplifier if ObservLib takes user-controlled URLs. ObservLib validates URLs via `lib/observlib/http.ex` (scheme/credential checks), which mitigates this. No known CVEs against req 0.5.x.

**finch 0.21.0 (transitive via req)**:
- Should it be a direct dep? **No.** ObservLib doesn't use Finch directly — it's consumed only through Req. Adding it as a direct dep would create version coupling. Current arrangement is correct.

**tls_certificate_check 1.32.0 (transitive via opentelemetry_exporter)**:
- Should it be a direct dep? **No.** It's used internally by the OTel exporter for certificate verification. ObservLib's own TLS handling in `lib/observlib/http.ex` uses Erlang's `:public_key.cacerts_get()` (line 230). Adding it directly would duplicate responsibility.

## mix hex.audit Output

```
No retired packages found
```

`mix hex.audit` ran successfully via nix-shell (Elixir 1.18.4 / OTP 28). **No retired or vulnerable packages found.** Also produced a warning about undefined `@version` module attribute in `mix.exs:62` — cosmetic issue, not security-relevant.

## telemetry_metrics 1.0 Assessment

### summary/2 usage found: **NO**
- Grep of `lib/` and `config/` for `summary(` returned zero matches.
- The `examples/phoenix_integration.exs` was already updated to use `distribution/2` (commit `92fe4bf`).
- No internal ObservLib code uses `Telemetry.Metrics.summary/2`.
- **Assessment: Safe.** No runtime crash risk from the 1.0 upgrade.

### distribution/2 security characteristics
- `distribution/2` accepts the same options as the removed `summary/2` including `tags`, `tag_values`, `reporter_options`.
- Label handling is identical — both use the same `Telemetry.Metrics` tag extraction pipeline.
- **No security regression** from switching summary → distribution. Both are metric type definitions; neither performs input sanitization (that's the reporter's job).

### mix.lock changes (commit 92fe4bf)
- `telemetry_metrics`: `0.6.3` → `1.1.0` (major version bump)
- No other dependency versions changed in that commit.
- No unexpected dependencies added.

## Phoenix Example Anti-Patterns

| Line | Issue | Severity | Recommended Fix |
|------|-------|----------|----------------|
| `examples/phoenix_integration.exs:142` | `conn.request_path` logged without redaction — paths can contain user IDs, tokens in query strings, PII (e.g., `/users/john@example.com/profile`) | MEDIUM | Sanitize path before logging: strip query params, replace dynamic segments with placeholders. E.g., `URI.parse(conn.request_path).path` to drop query strings, and pattern-match known routes to redact IDs. |
| `examples/phoenix_integration.exs:141,148,154` | `conn.method` used as metric label attribute — HTTP method is partially user-controlled. Non-standard methods (e.g., `MALICIOUS_METHOD_AAAA...`) create unbounded cardinality, exhausting metric storage. | MEDIUM | Allowlist HTTP methods: `method = if conn.method in ~w(GET POST PUT PATCH DELETE HEAD OPTIONS), do: conn.method, else: "OTHER"`. This caps cardinality to 8 values. |
| `examples/phoenix_integration.exs:17` | `System.get_env("OTLP_ENDPOINT")` inside `config/config.exs` block — the example shows this in a `config :observlib` block labeled "Add to config/config.exs". In Elixir, `config.exs` is evaluated at **compile time**, not runtime. The env var value is baked into the release. | LOW | Add a comment warning users: `# WARNING: Move to config/runtime.exs for runtime evaluation`. Better: show the example under `config/runtime.exs` instead. |
| `examples/phoenix_integration.exs:216` | `changeset.errors \|> inspect()` logged as attribute — `inspect/1` on changeset errors can expose validation messages containing PII (email formats, phone patterns) or internal field names | LOW | Log error keys only, not values: `errors: changeset.errors \|> Keyword.keys() \|> inspect()`. Or redact the values before logging. |

## Documentation Inaccuracies

| File:Line | Claim | Actual | Severity |
|-----------|-------|--------|----------|
| `docs/book/security/threat-model.md:476-483` | ETS table creation example shows `:public` mode with comment "Anyone can read" | Actual code uses `:protected` mode everywhere: `lib/observlib/traces/provider.ex:152`, `lib/observlib/traces/pyroscope_processor.ex:127`, `lib/observlib/metrics/meter_provider.ex:130,137`. The doc example is **misleading** — it shows a less secure mode than what's implemented. The comment on line 483 says "Default :protected means only owner can write" but the explicit option on line 479 is `:public`. | MEDIUM |
| `SECURITY.md:92` | "Fail-Safe: Security failures logged but don't crash the application" | `lib/observlib/logs/backend.ex:323-331` — `forward_to_exporter/1` does a bare `rescue _ -> :ok` and `catch :exit, _ -> :ok`. This silently drops logs with **no signal at all** — no warning, no metric, no telemetry event. This is "fail-silent", not "fail-safe". Logs are permanently lost with no indication. The claim is **partially misleading**. | MEDIUM |
| `SECURITY.md:148` | References `test/security/README.md` | File **exists** at `test/security/README.md`. Reference is accurate. | None |
| `test/security/README.md:166` and `test/security/COVERAGE.md:29` | Claims "89+ security test cases" | Actual count via `grep -c 'test "'`: **83 test cases** (atom_exhaustion: 5, ets_memory: 6, injection: 9, tls: 14, url: 17, access_control: 10, header_redaction: 12, resource_limits: 10). The claim of "89+" is **inflated by 6+**. The "+" qualifier and note about property tests generating thousands of runs may be used to justify the count, but the discrete `test` blocks total 83. | LOW |
| `docs/book/security/threat-model.md:496` | OWASP mapping claims "ETS `:protected` mode (sec-013)" for A01 | This is accurate — actual code does use `:protected`. But the same file's example at line 479 contradicts this by showing `:public`. Internal inconsistency within the threat model document. | LOW |

## test/security/ Test Count

```
test/security/access_control_test.exs:     10
test/security/atom_exhaustion_test.exs:      5
test/security/ets_memory_bounds_test.exs:    6
test/security/header_redaction_test.exs:    12
test/security/injection_prevention_test.exs: 9
test/security/resource_limits_test.exs:     10
test/security/tls_validation_test.exs:      14
test/security/url_validation_test.exs:      17
─────────────────────────────────────────────
Total:                                      83
```

**Actual count: 83** (claim: "89+")

The 6-test gap may be explained by tests that were removed or consolidated since the README was written, or by counting property test sub-cases as individual tests. Regardless, the documentation should be updated to reflect the actual count.

## Secrets Scan Summary

- No hardcoded API keys, passwords, or tokens found in `lib/` or `config/`.
- `config/config.exs:32` contains `prometheus_basic_auth: {"username", "password"}` but it is **commented out** (example only). Acceptable.
- `lib/observlib/metrics/prometheus_reader.ex:14` contains `prometheus_basic_auth: {"username", "password"}` in a `@moduledoc` example. Acceptable (documentation).
- `lib/observlib/attributes.ex:33` contains `"password" => "secret123"` in a doctest. Acceptable (test data).
- No `.env` files, no hardcoded tokens in source.

## Overall Risk Assessment

**Risk Level: LOW**

All dependencies are at current versions with no known CVEs. The telemetry_metrics 1.0 upgrade is safe — no `summary/2` usage in library code. Documentation has several inaccuracies (ETS mode example, test count, fail-safe claim) that should be corrected but pose no direct security risk. The Phoenix example anti-patterns are informational (example code, not library code) but could lead users to introduce vulnerabilities in their applications.
