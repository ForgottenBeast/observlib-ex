# ObservLib Security Audit Specification

**Version:** 1.0
**Date:** 2026-03-27
**Audit Type:** Comprehensive Security Assessment
**Project:** ObservLib - OpenTelemetry Observability Library for Elixir

---

## Executive Summary

ObservLib is a production observability library handling sensitive telemetry data from Elixir applications. This specification defines a comprehensive security audit covering OWASP Top 10 relevance, Elixir/OTP-specific vulnerabilities, supply chain security, and telemetry-specific attack vectors.

**Codebase Scope:**
- 3,500+ lines of application code
- 20 library modules (Traces, Metrics, Logs, Telemetry, Exporters, Pyroscope)
- 8 direct runtime dependencies, 30+ transitive dependencies
- External integrations: OTLP collectors, Pyroscope, Prometheus

**Critical Risk Areas Identified:**
1. No TLS/SSL configuration for external communications
2. Atom table exhaustion via `String.to_atom/1` on user input
3. Unbounded ETS memory growth (metrics cardinality, log batches)
4. Unauthenticated Prometheus TCP endpoint
5. Potential credential leakage in OTLP headers via error logging

---

## 1. Security Objectives

### 1.1 Primary Objectives

**Confidentiality:**
- Prevent exposure of sensitive data in telemetry attributes (PII, credentials, secrets)
- Protect authentication tokens in OTLP headers from leaking to logs
- Ensure secure transmission of telemetry data to collectors

**Integrity:**
- Prevent injection attacks (log injection, attribute injection, header injection)
- Protect ETS data from unauthorized modification
- Ensure telemetry data accuracy under adversarial conditions

**Availability:**
- Prevent denial-of-service via resource exhaustion (atom table, ETS memory, TCP connections)
- Ensure graceful degradation under backpressure
- Prevent cascading failures from external service unavailability

### 1.2 Compliance Considerations

While no specific compliance framework is mandated, the audit will identify:
- GDPR relevance (PII in traces/logs)
- SOC2 considerations (data handling, encryption in transit)
- HIPAA applicability (PHI in telemetry attributes)

---

## 2. Threat Model

### 2.1 Trust Boundaries

```
┌─────────────────────────────────────────────────────┐
│                Untrusted Zone                       │
│  ┌──────────────┐    ┌──────────────┐             │
│  │ Application  │───>│  ObservLib   │             │
│  │  (Caller)    │    │   Library    │             │
│  └──────────────┘    └───────┬──────┘             │
│                              │                      │
└──────────────────────────────┼──────────────────────┘
                               │
                               │ (Network Boundary)
                               │
┌──────────────────────────────▼──────────────────────┐
│              External Services                       │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐│
│  │ OTLP         │  │  Pyroscope   │  │Prometheus ││
│  │ Collector    │  │   Server     │  │  Scraper  ││
│  └──────────────┘  └──────────────┘  └───────────┘│
└─────────────────────────────────────────────────────┘
```

**Trust Assumptions:**
- Application code calling ObservLib may be malicious or compromised
- External services (OTLP, Pyroscope, Prometheus) are semi-trusted (network may be hostile)
- BEAM VM isolation prevents cross-tenant attacks within the same node

**Attack Vectors:**
1. Malicious application passes crafted attributes/logs to trigger DoS
2. Man-in-the-middle on OTLP/Pyroscope connections (no TLS)
3. Prometheus scraper from untrusted network abuses TCP endpoint
4. Supply chain attack via compromised dependency

### 2.2 Threat Actors

| Actor | Capability | Motivation |
|-------|-----------|------------|
| **Malicious App Code** | Can call any ObservLib API | DoS, data exfiltration via logs |
| **Network Attacker** | MITM on unencrypted connections | Intercept telemetry data, credential theft |
| **Compromised Dependency** | Execute arbitrary code at build/runtime | Supply chain compromise |
| **Unauthenticated Scraper** | Access Prometheus endpoint | Information disclosure, DoS |

---

## 3. Security Audit Scope

### 3.1 In-Scope Areas

**Code Modules:**
- ✅ `lib/observlib/*.ex` - Core API and configuration
- ✅ `lib/observlib/traces/*.ex` - Span management and tracking
- ✅ `lib/observlib/metrics/*.ex` - Metrics collection and Prometheus export
- ✅ `lib/observlib/logs/*.ex` - Log handling and OTLP export
- ✅ `lib/observlib/exporters/*.ex` - OTLP exporters for traces/metrics/logs
- ✅ `lib/observlib/pyroscope/*.ex` - Profiling integration
- ✅ `lib/observlib/telemetry.ex` - Event handler bridge
- ✅ `config/*.exs` - Configuration files

**Security Domains:**
1. **Input Validation** - All public API entry points
2. **Output Encoding** - Log formatting, Prometheus exposition format
3. **Cryptographic Transport** - TLS configuration for HTTP clients
4. **Resource Limits** - ETS memory, atom table, TCP connections
5. **Error Handling** - Information disclosure in error messages
6. **Dependency Security** - Direct and transitive dependency CVEs
7. **Configuration Security** - Secrets management, default values
8. **Process Isolation** - ETS access control, GenServer boundaries

### 3.2 Out-of-Scope

- ❌ Application-level security (how consumers use ObservLib)
- ❌ OpenTelemetry SDK security (delegated to upstream `opentelemetry` library)
- ❌ Infrastructure security (Kubernetes, Docker, network policies)
- ❌ Performance optimization (unless directly related to DoS)

---

## 4. Critical Findings from Initial Review

### 4.1 CRITICAL Severity

**C-01: No TLS Configuration for External HTTP Communications**
- **Location:** All `Req.post` calls in exporters and Pyroscope client
- **Impact:** Credentials and telemetry data sent in plaintext
- **Risk:** High probability, high impact = CRITICAL
- **OWASP:** A02:2021 - Cryptographic Failures

**C-02: Atom Table Exhaustion via User-Controlled Metric Names**
- **Location:** `lib/observlib/metrics.ex:323` - `String.to_atom/1`
- **Impact:** VM crash via atom table overflow
- **Risk:** Medium probability (requires malicious app), high impact = CRITICAL
- **OWASP:** A04:2021 - Insecure Design

**C-03: Unbounded ETS Memory Growth (Metrics Cardinality)**
- **Location:** `lib/observlib/metrics/meter_provider.ex:81`
- **Impact:** Memory exhaustion, OOM kills
- **Risk:** High probability (high-cardinality labels common), high impact = CRITICAL
- **OWASP:** A04:2021 - Insecure Design

**C-04: Unbounded Log Batch Queue**
- **Location:** `lib/observlib/exporters/otlp_logs_exporter.ex:189-207`
- **Impact:** Memory exhaustion when collector is down
- **Risk:** Medium probability, high impact = CRITICAL
- **OWASP:** A04:2021 - Insecure Design

### 4.2 HIGH Severity

**H-01: OTLP Headers Leak via `inspect()` in Error Logs**
- **Location:** `lib/observlib/exporters/otlp_metrics_exporter.ex:296`
- **Impact:** Bearer tokens/API keys exposed in log files
- **Risk:** Medium probability, medium impact = HIGH
- **OWASP:** A01:2021 - Broken Access Control

**H-02: ETS Tables with `:public` Access Control**
- **Location:** `lib/observlib/metrics/meter_provider.ex:130`
- **Impact:** Any process can corrupt metrics data
- **Risk:** Low probability (requires malicious code in VM), high impact = HIGH
- **OWASP:** A01:2021 - Broken Access Control

**H-03: `Process.sleep` in GenServer Callbacks During Retries**
- **Location:** Exporters retry logic
- **Impact:** GenServer blocked, potential cascading failures
- **Risk:** Medium probability, medium impact = HIGH
- **OWASP:** A04:2021 - Insecure Design

**H-04: Unauthenticated Prometheus TCP Endpoint**
- **Location:** `lib/observlib/metrics/prometheus_reader.ex:73`
- **Impact:** Information disclosure to unauthorized clients
- **Risk:** High probability (if exposed), medium impact = HIGH
- **OWASP:** A01:2021 - Broken Access Control

**H-05: No URL Validation for OTLP Endpoints**
- **Location:** Config accepts arbitrary endpoint strings
- **Impact:** SSRF, credential injection in URLs
- **Risk:** Low probability, high impact = HIGH
- **OWASP:** A03:2021 - Injection

### 4.3 MEDIUM Severity

**M-01: No Attribute Value Size Limits**
**M-02: No Sensitive Attribute Redaction Mechanism**
**M-03: Missing Input Validation in `runtime.exs`**
**M-04: No Max Active Span Limit**
**M-05: Prometheus Label Injection (partial mitigation exists)**

### 4.4 LOW Severity

**L-01: Dependency Vulnerability Assessment Needed**
**L-02: `erl_crash.dump` Present in Working Directory**
**L-03: No Log Message Size Limits**

---

## 5. Audit Testing Methodology

### 5.1 Static Analysis

**Tools:**
- `mix credo --strict` - Code quality and style issues
- `mix dialyzer` - Type safety analysis
- `mix deps.audit` - Known CVE scanning
- Manual code review of security-critical paths

**Focus Areas:**
- Input validation at all public API boundaries
- Error handling and information disclosure
- Resource cleanup and limit enforcement
- Atom usage patterns (`String.to_atom` vs `String.to_existing_atom`)

### 5.2 Dynamic Testing

**Property-Based Testing (StreamData):**
- Fuzz attribute maps with extreme values (very large, very long, special characters)
- Generate high-cardinality metric labels to verify ETS bounds
- Test atom table exhaustion with 1M unique metric names
- Test concurrent ETS access patterns

**Integration Tests:**
- Mock OTLP collector with adversarial responses (500s, timeouts, malformed JSON)
- Simulate network failures and verify retry behavior
- Test Prometheus endpoint with malformed HTTP requests
- Verify TLS certificate validation (once implemented)

**Penetration Testing:**
- Log injection payloads (newlines, ANSI codes, null bytes)
- Prometheus label injection (metric name/label manipulation)
- HTTP request smuggling on Prometheus endpoint
- SSRF via crafted OTLP endpoint URLs

### 5.3 Security Code Review Checklist

**For Each Module:**
- [ ] All public functions validate input size and type
- [ ] No `String.to_atom/1` on user-controlled data
- [ ] ETS tables use `:protected` or document why `:public` is needed
- [ ] All HTTP clients configure TLS explicitly
- [ ] Error messages don't leak credentials or internal paths
- [ ] Resource limits are enforced (memory, connections, batch sizes)
- [ ] Retry logic uses exponential backoff and jitter
- [ ] No `Process.sleep` in GenServer callbacks
- [ ] All string interpolation uses parameterized queries (SQL) or safe encoders

---

## 6. Acceptance Criteria

### 6.1 Security Requirements (Must Pass)

**SEC-01: TLS Required for Remote Endpoints**
- ✅ OTLP endpoints with `https://` scheme use verified TLS
- ✅ Certificate validation can be configured (CA bundle, pinning)
- ✅ Plaintext HTTP to non-localhost produces a warning
- ✅ Configuration options for TLS version, ciphers

**SEC-02: Atom Table Protection**
- ✅ Property test with 1M unique metric names doesn't crash VM
- ✅ All `String.to_atom/1` replaced with safe alternatives or bounded input
- ✅ Documentation warns about atom safety if user can control metric names

**SEC-03: Bounded ETS Memory Usage**
- ✅ Configurable max cardinality per metric (default: 2000)
- ✅ Configurable max active spans (default: 10000)
- ✅ Configurable max log batch size (default: 1000)
- ✅ When limits hit, oldest entries are dropped with a warning log

**SEC-04: OTLP Headers Never Logged**
- ✅ Test scenario: OTLP export failure with `Authorization: Bearer <token>`
- ✅ Verify: token does not appear in Logger output or error messages
- ✅ Redaction function for sensitive headers in error contexts

**SEC-05: Prometheus Endpoint Security**
- ✅ Documentation states endpoint must be network-isolated
- ✅ Optional: Basic auth or IP allowlist configuration
- ✅ Connection limit enforced (default: 10 concurrent)
- ✅ Request rate limit (default: 100 req/min)

**SEC-06: ETS Access Control**
- ✅ All ETS tables use `:protected` access (writes only via owner)
- ✅ Or: document performance requirement and risk for `:public` tables

**SEC-07: No Blocking Retry Logic**
- ✅ Exporters use `Process.send_after` for retry scheduling
- ✅ Test: collector down for 60s doesn't block other operations
- ✅ Retry backoff is exponential with jitter

**SEC-08: URL Validation**
- ✅ OTLP endpoint URLs validated for scheme (http/https only)
- ✅ Reject URLs with user info (`http://user:pass@host`)
- ✅ Reject file:// and other non-HTTP schemes

**SEC-09: Injection Prevention**
- ✅ Prometheus label escaping covers all control characters
- ✅ Log messages escape ANSI codes and newlines
- ✅ Span attributes are properly JSON-encoded for OTLP

**SEC-10: Dependency Security**
- ✅ `mix deps.audit` passes with zero HIGH/CRITICAL CVEs
- ✅ Direct dependencies reviewed for known issues
- ✅ Lockfile pinned and reproducible builds ensured

### 6.2 Quality Gates

**Automated:**
- All unit tests pass (including new security tests)
- Property-based tests pass (1000 iterations minimum)
- `mix credo --strict` passes with zero warnings
- `mix dialyzer` passes with zero type errors
- `mix deps.audit` reports zero HIGH/CRITICAL vulnerabilities

**Manual:**
- Security code review checklist 100% complete
- Threat model reviewed and approved
- All CRITICAL and HIGH findings remediated
- All MEDIUM findings documented with mitigation plan or risk acceptance

---

## 7. Remediation Plan (High-Level)

### Phase 1: Critical Fixes (Priority 1)
1. Implement TLS configuration for all HTTP clients (C-01)
2. Replace `String.to_atom/1` with safe alternatives (C-02)
3. Add metric cardinality limits (C-03)
4. Add log batch queue limits (C-04)

### Phase 2: High-Risk Fixes (Priority 2)
5. Implement OTLP header redaction in error logging (H-01)
6. Change ETS access to `:protected` (H-02)
7. Refactor retry logic to use `Process.send_after` (H-03)
8. Add auth/rate limiting to Prometheus endpoint (H-04)
9. Implement URL validation for endpoints (H-05)

### Phase 3: Medium-Risk Fixes (Priority 3)
10. Add attribute value size limits
11. Implement sensitive attribute redaction
12. Add input validation to runtime.exs
13. Add max active span limit
14. Enhance Prometheus label escaping

### Phase 4: Hardening (Priority 4)
15. Run dependency audit and update vulnerable packages
16. Add log message size limits
17. Document security model and deployment requirements
18. Create security testing suite

---

## 8. Documentation Requirements

**Security Guide (NEW):**
- Threat model and trust boundaries
- TLS configuration examples
- Secrets management best practices
- Attribute redaction configuration
- Prometheus endpoint isolation requirements
- Incident response guidance

**Configuration Reference Updates:**
- Document all security-related config options
- Provide secure defaults
- Warn about insecure configurations

**README Updates:**
- Add security considerations section
- Link to security policy (SECURITY.md)
- Disclosure process for vulnerabilities

---

## 9. Risk Classification Framework

| Severity | Likelihood | Impact | Action Required |
|----------|-----------|--------|-----------------|
| **CRITICAL** | High or Medium | High | Fix before next release |
| **HIGH** | Any | Medium-High | Fix in current sprint |
| **MEDIUM** | Low-Medium | Medium | Fix in next 2 sprints |
| **LOW** | Low | Low-Medium | Backlog, document workaround |

**Likelihood:**
- High: Exploit is trivial, no special conditions needed
- Medium: Exploit requires specific configuration or malicious app code
- Low: Exploit requires rare conditions or compromised dependencies

**Impact:**
- High: Data loss, credential theft, VM crash, service outage
- Medium: Performance degradation, partial data exposure
- Low: Information disclosure with limited value

---

## 10. Open Questions for Clarification

1. **Data Classification:** What is the sensitivity level of telemetry data? (PII, confidential, public)
2. **Compliance:** Are there specific frameworks to audit against? (GDPR, SOC2, HIPAA)
3. **Deployment Topology:** Are OTLP/Pyroscope on the same network or crossing trust boundaries?
4. **OTP Version:** What is the minimum OTP version for production? (affects TLS defaults)
5. **Publication Intent:** Is Hex.pm publication planned? (affects supply chain requirements)
6. **Prometheus Exposure:** Is the endpoint expected to be internet-facing?
7. **Authentication Model:** Should OTLP headers support OAuth2 or API keys?
8. **Cardinality Limits:** What is the expected max metric cardinality in production?

---

## 11. Success Criteria

**Audit Complete When:**
- ✅ All CRITICAL findings remediated
- ✅ All HIGH findings remediated or documented risk acceptance
- ✅ Security test suite passes
- ✅ Documentation updated with security guidance
- ✅ `mix deps.audit` shows zero HIGH/CRITICAL CVEs
- ✅ Independent security code review completed (if required)
- ✅ Sign-off from security-reviewer, architect, and code-reviewer agents

---

## Appendix A: OWASP Top 10 Relevance

| OWASP Category | Relevance | Findings |
|----------------|-----------|----------|
| A01: Broken Access Control | HIGH | H-02, H-04 |
| A02: Cryptographic Failures | CRITICAL | C-01 |
| A03: Injection | MEDIUM | H-05, M-05 |
| A04: Insecure Design | CRITICAL | C-02, C-03, C-04, H-03 |
| A05: Security Misconfiguration | MEDIUM | Default configs |
| A06: Vulnerable Components | MEDIUM | L-01 |
| A07: Auth Failures | LOW | N/A (no auth in library) |
| A08: Data Integrity Failures | MEDIUM | H-02 |
| A09: Logging Failures | HIGH | H-01 |
| A10: SSRF | MEDIUM | H-05 |

---

**Specification Approved For Planning Phase**
