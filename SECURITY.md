# Security Policy

## Reporting a Vulnerability

We take the security of ObservLib seriously. If you discover a security vulnerability, please follow these steps:

### How to Report

**Please do NOT report security vulnerabilities through public GitHub issues.**

Instead, please report them via:

- **Email**: security@example.com (replace with your actual security contact)
- **Subject Line**: [SECURITY] ObservLib Vulnerability Report
- **Include**:
  - Description of the vulnerability
  - Steps to reproduce
  - Potential impact
  - Suggested fix (if any)

### What to Expect

- **Acknowledgment**: We will acknowledge receipt within 48 hours
- **Initial Assessment**: We will provide an initial assessment within 5 business days
- **Updates**: We will keep you informed of our progress
- **Disclosure**: We follow coordinated disclosure practices
- **Credit**: We will credit you in the security advisory (unless you prefer to remain anonymous)

### Response Timeline

- **Critical vulnerabilities**: Patched within 7 days
- **High severity**: Patched within 14 days
- **Medium/Low severity**: Patched in next regular release

## Supported Versions

We provide security updates for the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |
| < 0.1   | :x:                |

We recommend always using the latest stable release.

## Security Features

ObservLib implements multiple layers of defense to protect your observability infrastructure:

### Resource Protection

- **Atom Table Safety**: Prevents atom exhaustion attacks through safe conversion and pre-registration
- **Memory Limits**: Enforces cardinality limits (2,000 variants per metric), attribute count limits (128 per operation), and attribute size limits (4KB per value)
- **Rate Limiting**: Token bucket algorithm limits Prometheus scrape requests (100 req/min default)
- **Connection Limiting**: Caps concurrent Prometheus connections (10 connections default)
- **Batch Limits**: Prevents unbounded queue growth in log exporters (1,000 log limit)

### Network Security

- **TLS by Default**: HTTPS connections use certificate verification with system CA store
- **Custom CA Support**: Configure custom CA certificates for internal PKI
- **URL Validation**: Strict validation prevents SSRF attacks (only http/https schemes allowed)
- **Credential Protection**: Rejects URLs with embedded credentials

### Data Protection

- **Attribute Redaction**: Automatic redaction of sensitive attribute keys (passwords, tokens, API keys)
- **Header Redaction**: Sensitive HTTP headers redacted from error logs
- **Injection Prevention**: Escapes control characters in Prometheus labels and log messages
- **Value Truncation**: Oversized attribute values truncated with warnings

### Access Control

- **ETS Protection**: All ETS tables use `:protected` mode with proper ownership
- **Prometheus Authentication**: Optional HTTP Basic Auth for metrics endpoint
- **Process Isolation**: Security-critical operations isolated in supervised processes

### Attack Mitigation

- **SSRF Prevention**: URL validation blocks file://, ftp://, data://, and other dangerous schemes
- **Log Injection Prevention**: Structured logging prevents log injection attacks
- **Label Injection Prevention**: Comprehensive escaping in Prometheus output format
- **DoS Protection**: Multiple layers of resource limits prevent denial of service

## Security Architecture

ObservLib follows a defense-in-depth approach:

1. **Input Validation**: All external inputs validated at boundaries
2. **Resource Limits**: Multiple configurable limits prevent exhaustion
3. **Secure Defaults**: TLS verification, rate limiting, and redaction enabled by default
4. **Fail-Silent**: Security failures do not crash the application. Note: if the OTLP log exporter is unavailable, `ObservLib.Logs.Backend` silently drops log records rather than crashing. This prevents cascading failures but means log loss is not automatically signalled to operators. Monitor for dropped logs using the `:observlib, :logs, :drop` telemetry event (see NEW-007 tracking issue for full observability improvements).
5. **Least Privilege**: Processes operate with minimal required permissions

## Configuration for Security

### Production Recommendations

```elixir
config :observlib,
  # Use HTTPS for OTLP endpoints
  otlp_endpoint: "https://collector.example.com:4318",

  # Enable TLS verification (enabled by default)
  tls_verify: true,

  # Use TLS 1.2+ only
  tls_versions: [:"tlsv1.3", :"tlsv1.2"],

  # Protect Prometheus endpoint
  prometheus_basic_auth: {"username", "strong_password"},
  prometheus_rate_limit: 100,
  prometheus_max_connections: 10,

  # Resource limits
  cardinality_limit: 2000,
  max_attribute_count: 128,
  max_attribute_value_size: 4096,
  log_batch_limit: 1000,

  # Sensitive attribute redaction (enabled by default)
  redacted_attribute_keys: [
    "password", "token", "api_key", "secret", "authorization"
  ]
```

### Network Isolation

- Deploy ObservLib services behind a firewall
- Restrict Prometheus metrics endpoint to monitoring network
- Use TLS for all external communications
- Consider mutual TLS (mTLS) for high-security environments

## Security Testing

ObservLib includes comprehensive security tests covering all 14 identified vulnerabilities:

```bash
# Run all security tests
mix test --only security

# Run specific security test categories
mix test test/security/atom_exhaustion_test.exs
mix test test/security/injection_prevention_test.exs
mix test test/security/tls_validation_test.exs
```

See `test/security/README.md` for complete test documentation.

## Known Limitations

- **Atom exhaustion**: While mitigated, creating unbounded unique metric names should be avoided
- **Memory limits**: High-cardinality metrics can still consume significant memory within limits
- **Rate limiting**: Simple token bucket implementation; not suitable for complex rate limiting scenarios
- **Authentication**: Basic Auth is not encrypted; always use with TLS in production

## Security Updates

Security updates are announced through:

- GitHub Security Advisories
- Release notes in CHANGELOG.md
- Project README

Subscribe to GitHub repository notifications to receive security updates.

## Security Audit History

| Date | Version | Auditor | Findings |
|------|---------|---------|----------|
| 2026-03 | 0.1.0 | Internal | 14 findings (all remediated) |

All findings from the internal security review have been addressed in version 0.1.0.

## Compliance

ObservLib implements security controls aligned with:

- OWASP Top 10 (2021)
- CWE Top 25 Most Dangerous Software Weaknesses
- NIST Cybersecurity Framework

See `docs/book/security/threat-model.md` for detailed mapping.

## Additional Resources

- [Security Overview](docs/book/security/overview.md)
- [Security Configuration Guide](docs/book/security/configuration.md)
- [Security Best Practices](docs/book/security/best-practices.md)
- [Threat Model](docs/book/security/threat-model.md)
- [Security Test Coverage](test/security/COVERAGE.md)

## Contact

For general security questions (non-vulnerabilities):

- GitHub Discussions: Create a discussion in the Security category
- Issues: Use the `security` label for non-sensitive topics

For vulnerability reports, always use the private reporting channels listed above.
