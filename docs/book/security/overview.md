# Security Overview

ObservLib implements comprehensive security controls to protect observability infrastructure from common attacks and misconfigurations. This document provides an overview of the security architecture and features.

## Security Architecture

ObservLib follows a **defense-in-depth** approach with multiple layers of protection:

```
┌─────────────────────────────────────────────┐
│         Input Validation Layer              │
│  - URL validation (SSRF prevention)         │
│  - Scheme validation (http/https only)      │
│  - Credential validation (no URLs with auth)│
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│       Resource Protection Layer             │
│  - Atom table safety (safe_to_atom)         │
│  - Memory limits (cardinality, attributes)  │
│  - Rate limiting (token bucket)             │
│  - Connection limiting (max concurrent)     │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│         Transport Security Layer            │
│  - TLS 1.2+ with certificate verification   │
│  - Custom CA certificate support            │
│  - System CA store integration              │
│  - Plaintext warnings for remote hosts      │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│         Data Protection Layer               │
│  - Sensitive attribute redaction            │
│  - Header redaction in error logs           │
│  - Injection prevention (logs, labels)      │
│  - Value truncation (size limits)           │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│         Access Control Layer                │
│  - ETS table protection (:protected mode)   │
│  - Process ownership enforcement            │
│  - Prometheus endpoint authentication       │
└─────────────────────────────────────────────┘
```

## Threat Model Summary

ObservLib protects against the following threat classes:

### Resource Exhaustion Attacks

**Threats**:
- Atom table exhaustion (VM crash)
- Memory exhaustion (unbounded ETS growth)
- Connection exhaustion (DoS)
- CPU exhaustion (processing floods)

**Mitigations**:
- Safe atom conversion with pre-registration
- Cardinality limits (2,000 variants per metric)
- Attribute count limits (128 per operation)
- Attribute size limits (4KB per value)
- Connection limits (10 concurrent default)
- Rate limiting (100 req/min default)
- Batch limits (1,000 logs default)

### Network-Based Attacks

**Threats**:
- Man-in-the-middle (credential theft)
- Server impersonation
- SSRF (internal network access)
- Credential leakage (URLs with auth)

**Mitigations**:
- TLS 1.2+ with certificate verification
- URL validation (http/https only)
- User info rejection (no credentials in URLs)
- Custom CA certificate support
- Warnings for plaintext connections

### Injection Attacks

**Threats**:
- Log injection (log forging)
- Label injection (Prometheus format breaking)
- Header injection (HTTP response splitting)
- Control character injection

**Mitigations**:
- Structured logging (no string interpolation)
- Comprehensive label escaping (all control chars)
- Header redaction in error contexts
- Input sanitization at boundaries

### Information Disclosure

**Threats**:
- Credential exposure in logs
- Sensitive data in traces/metrics
- Authentication token leakage
- Internal system information disclosure

**Mitigations**:
- Automatic attribute redaction (passwords, tokens, keys)
- Header redaction (Authorization, X-API-Key, etc.)
- Configurable redaction patterns
- Safe error messages

### Access Control Violations

**Threats**:
- Unauthorized ETS table modification
- Process interference
- Metrics endpoint abuse

**Mitigations**:
- ETS tables in `:protected` mode
- Process ownership validation
- Prometheus Basic Auth support
- Rate limiting on scrape endpoint

## Security Features by Component

### 1. Configuration (`ObservLib.Config`)

**Security Features**:
- Runtime validation of all configuration values
- Service name requirement (prevents empty configs)
- Secure defaults for all security settings
- Type validation for security-critical options

**Default Security Settings**:
```elixir
cardinality_limit: 2000           # Max variants per metric
log_batch_limit: 1000             # Max queued logs
max_attribute_value_size: 4096    # 4KB max per attribute
max_attribute_count: 128          # Max attributes per operation
prometheus_max_connections: 10    # Max concurrent scrapes
prometheus_rate_limit: 100        # Max 100 scrapes/minute
tls_verify: true                  # Certificate verification enabled
```

### 2. HTTP Client (`ObservLib.HTTP`)

**Security Features**:
- TLS certificate verification by default
- URL validation and SSRF prevention
- System CA store integration
- Custom CA certificate support
- Plaintext connection warnings
- Header redaction in error logs

**Supported TLS Versions**: TLS 1.2, TLS 1.3 (TLS 1.0/1.1 disabled)

### 3. Attributes (`ObservLib.Attributes`)

**Security Features**:
- Automatic value truncation (prevents memory exhaustion)
- Attribute count limiting
- Sensitive key redaction
- Configurable redaction patterns

**Default Redacted Keys**:
- password, passwd, secret, token
- authorization, auth, bearer
- api_key, apikey, access_key, private_key
- credit_card, creditcard, card_number, cvv
- ssn, social_security, session

### 4. Prometheus Reader (`ObservLib.Metrics.PrometheusReader`)

**Security Features**:
- Connection limiting (prevents resource exhaustion)
- Rate limiting (token bucket algorithm)
- HTTP Basic Authentication support
- Label injection prevention (all control chars escaped)
- Minimal attack surface (only GET /metrics allowed)

**Escaping Coverage**:
- Backslashes, quotes, newlines, carriage returns
- Tabs, null bytes, and all ASCII control characters (0-31, 127)
- Prevents CRLF injection and Prometheus format breaking

### 5. Metrics (`ObservLib.Metrics.MeterProvider`)

**Security Features**:
- Atom table safety (avoids String.to_atom for user input)
- Cardinality limiting per metric name
- ETS table protection (`:protected` mode)
- Bounded memory usage

### 6. Traces (`ObservLib.Traces.Provider`)

**Security Features**:
- Active span count limiting
- Stale span cleanup
- ETS table protection
- Attribute validation on all spans

### 7. Logs (`ObservLib.Logs.Backend`)

**Security Features**:
- Structured logging (injection prevention)
- Batch size limiting
- Attribute validation and redaction
- Safe error handling

## Secure Defaults

ObservLib is secure by default. No additional configuration is required for basic security:

| Feature | Default | Security Benefit |
|---------|---------|------------------|
| TLS Verification | Enabled | Prevents MITM attacks |
| TLS Versions | 1.2, 1.3 | Uses only secure protocols |
| Attribute Redaction | Enabled | Protects sensitive data |
| Cardinality Limit | 2,000 | Prevents memory exhaustion |
| Rate Limiting | 100/min | Prevents DoS |
| Connection Limit | 10 | Prevents resource exhaustion |
| Value Size Limit | 4KB | Prevents memory attacks |
| Attribute Count Limit | 128 | Bounds processing time |

**No insecure features are enabled by default.**

## Defense-in-Depth Approach

ObservLib implements multiple independent security controls:

### Layer 1: Prevention
- Input validation at all entry points
- URL and scheme validation
- Type checking and runtime validation

### Layer 2: Detection
- Logging of security events (truncation, rate limiting)
- Metrics on rejected requests
- Warnings for insecure configurations

### Layer 3: Mitigation
- Resource limits prevent complete exhaustion
- Rate limiting slows down attacks
- Graceful degradation under load

### Layer 4: Recovery
- Supervised processes restart on failure
- No cascading failures from security events
- Metrics continue functioning during attacks

## Security Testing

ObservLib includes comprehensive security test coverage:

- **89+ test cases** covering all security features
- **Property-based tests** (1,270+ executions) for exhaustive validation
- **100% coverage** of all 14 identified security findings

Run security tests:
```bash
mix test --only security
```

See [test/security/README.md](../../../test/security/README.md) for complete test documentation.

## Compliance and Standards

ObservLib security controls align with:

- **OWASP Top 10 (2021)**: Injection, Broken Access Control, Security Misconfiguration, etc.
- **CWE Top 25**: Resource exhaustion, injection, improper access control
- **NIST CSF**: Identify, Protect, Detect, Respond, Recover functions

See [Threat Model](threat-model.md) for detailed mapping.

## Monitoring Security Events

ObservLib logs security-relevant events:

```elixir
# Rate limit exceeded
Logger.warning("Prometheus rate limit exceeded")

# Connection limit exceeded
Logger.warning("Prometheus connection limit exceeded",
  active: 10, max: 10)

# Attribute truncation
Logger.warning("Attribute value truncated",
  original_size: 10000, truncated_size: 4096)

# Attribute count exceeded
Logger.warning("Attribute count exceeded",
  count: 200, limit: 128)

# Plaintext connection
Logger.warning("Plaintext HTTP connection to remote host: example.com")
```

Set up alerts on these warnings for security monitoring.

## Security Roadmap

Planned security enhancements:

- [ ] Mutual TLS (mTLS) support for OTLP endpoints
- [ ] OAuth 2.0/OIDC for Prometheus authentication
- [ ] Enhanced audit logging with tamper protection
- [ ] Automatic security policy validation
- [ ] Security benchmarking and hardening guides

## Getting Help

- **Security vulnerabilities**: See [SECURITY.md](../../../SECURITY.md)
- **Security configuration**: See [Configuration Guide](configuration.md)
- **Best practices**: See [Best Practices](best-practices.md)
- **Threat model**: See [Threat Model](threat-model.md)

## Summary

ObservLib provides production-ready security with:

- ✅ Secure by default
- ✅ Defense in depth
- ✅ Comprehensive testing
- ✅ Standards alignment
- ✅ Minimal configuration required

No security features need to be enabled manually for basic protection.
