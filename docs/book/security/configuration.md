# Security Configuration Guide

This guide covers all security-related configuration options in ObservLib and provides examples for common deployment scenarios.

## Table of Contents

- [TLS Configuration](#tls-configuration)
- [Certificate Validation](#certificate-validation)
- [Resource Limits](#resource-limits)
- [Attribute Redaction](#attribute-redaction)
- [Prometheus Security](#prometheus-security)
- [Environment Variables](#environment-variables)
- [Quick Start](#quick-start)

## TLS Configuration

### Basic HTTPS with System CA Store

ObservLib enables TLS verification by default for HTTPS connections:

```elixir
config :observlib,
  # TLS verification enabled by default
  otlp_endpoint: "https://collector.example.com:4318"
```

No additional configuration needed. ObservLib will:
- Use TLS 1.2 and TLS 1.3 only
- Verify certificates against system CA store
- Reject invalid or expired certificates

### Custom TLS Versions

Restrict TLS versions for compliance:

```elixir
config :observlib,
  otlp_endpoint: "https://collector.example.com:4318",
  tls_versions: [:"tlsv1.3"]  # TLS 1.3 only
```

Available versions: `:"tlsv1.2"`, `:"tlsv1.3"`

**Security Note**: TLS 1.0 and TLS 1.1 are not supported due to known vulnerabilities.

### Custom CA Certificates

For internal PKI or self-signed certificates:

```elixir
config :observlib,
  otlp_endpoint: "https://internal-collector.corp:4318",
  tls_ca_cert_file: "/etc/ssl/certs/corporate-ca.pem"
```

The CA certificate file should be in PEM format:

```pem
-----BEGIN CERTIFICATE-----
MIIDXTCCAkWgAwIBAgIJAKJ5...
-----END CERTIFICATE-----
```

### Disabling TLS Verification (Not Recommended)

For testing environments only:

```elixir
config :observlib,
  otlp_endpoint: "https://test-collector:4318",
  tls_verify: false  # ⚠️ NOT FOR PRODUCTION
```

**Warning**: Never disable TLS verification in production. This exposes your observability data to man-in-the-middle attacks.

### Plaintext HTTP Warnings

ObservLib warns when using plaintext HTTP to remote hosts:

```elixir
# This will log a warning:
config :observlib,
  otlp_endpoint: "http://remote-collector.example.com:4318"

# Warning: "Plaintext HTTP connection to remote host: remote-collector.example.com"
```

Localhost connections don't trigger warnings:
```elixir
# No warning - localhost is safe for development
config :observlib,
  otlp_endpoint: "http://localhost:4318"
```

## Certificate Validation

### System CA Store (Default)

ObservLib uses the system CA certificate store by default:

```elixir
# Uses system CAs automatically
config :observlib,
  otlp_endpoint: "https://api.honeycomb.io",
  tls_verify: true
```

This works with certificates from:
- Let's Encrypt
- DigiCert, GlobalSign, etc.
- Any CA trusted by the operating system

### Custom CA Bundles

For environments with custom CAs:

```elixir
config :observlib,
  otlp_endpoint: "https://internal.corp:4318",
  tls_ca_cert_file: "/etc/pki/tls/certs/ca-bundle.crt"
```

You can concatenate multiple CA certificates in one file:

```bash
cat root-ca.pem intermediate-ca.pem > ca-bundle.pem
```

### Certificate Pinning

For maximum security, deploy with a specific CA:

```elixir
config :observlib,
  otlp_endpoint: "https://collector.example.com:4318",
  tls_ca_cert_file: "/app/config/collector-ca.pem",
  tls_verify: true
```

This ensures only certificates signed by your specific CA are accepted.

## Resource Limits

Resource limits prevent denial-of-service attacks and memory exhaustion.

### Metric Cardinality Limits

Limit unique metric variants per metric name:

```elixir
config :observlib,
  # Maximum unique attribute combinations per metric name
  cardinality_limit: 2000  # Default: 2000
```

**Example**:
```elixir
# This metric can have up to 2000 unique combinations:
ObservLib.counter("http.requests", 1, %{
  method: "GET",    # 10 methods
  status: 200,      # 100 status codes
  endpoint: "/api"  # 20 endpoints
})
# Total possible: 10 × 100 × 20 = 20,000 (but limited to 2000)
```

**Security Benefit**: Prevents memory exhaustion from unbounded metric variants.

### Attribute Count Limits

Limit the number of attributes per operation:

```elixir
config :observlib,
  # Maximum attributes per span/metric/log
  max_attribute_count: 128  # Default: 128
```

**Example**:
```elixir
# Only first 128 attributes kept:
ObservLib.traced("operation", %{
  attr1: "value1",
  attr2: "value2",
  # ... 200 total attributes
  attr200: "value200"
}, fn -> work() end)
# Attributes 129-200 are dropped with a warning
```

**Security Benefit**: Prevents CPU exhaustion from processing excessive attributes.

### Attribute Value Size Limits

Limit the size of individual attribute values:

```elixir
config :observlib,
  # Maximum bytes per attribute value
  max_attribute_value_size: 4096  # Default: 4KB
```

**Example**:
```elixir
large_payload = String.duplicate("x", 10_000)

ObservLib.counter("requests", 1, %{
  payload: large_payload  # Truncated to 4KB with "...[TRUNC]" suffix
})
```

**Security Benefit**: Prevents memory exhaustion from oversized values.

### Log Batch Limits

Limit queued logs when OTLP collector is unavailable:

```elixir
config :observlib,
  # Maximum logs in export queue
  log_batch_limit: 1000  # Default: 1000
```

**Security Benefit**: Prevents unbounded memory growth during collector outages.

### All Limits Combined

Recommended production configuration:

```elixir
config :observlib,
  # Metric limits
  cardinality_limit: 2000,

  # Attribute limits
  max_attribute_count: 128,
  max_attribute_value_size: 4096,

  # Log limits
  log_batch_limit: 1000,

  # Batch processing
  batch_size: 512,
  batch_timeout: 5000
```

## Attribute Redaction

Automatically redact sensitive data from attributes.

### Default Redaction

Enabled automatically with sensible defaults:

```elixir
# No configuration needed - these are redacted by default:
ObservLib.counter("login", 1, %{
  password: "secret123",      # Becomes "[REDACTED]"
  api_key: "key-abc123",      # Becomes "[REDACTED]"
  authorization: "Bearer xyz" # Becomes "[REDACTED]"
})
```

### Default Redacted Keys

The following patterns are redacted automatically:
- password, passwd, secret, token
- authorization, auth, bearer
- api_key, apikey, access_key, private_key
- credit_card, creditcard, card_number, cvv
- ssn, social_security, session

**Pattern Matching**: Case-insensitive substring matching.

### Custom Redaction Patterns

Add your own sensitive patterns:

```elixir
config :observlib,
  redacted_attribute_keys: [
    "password",
    "token",
    "customer_id",      # Custom
    "internal_id",      # Custom
    "employee_ssn"      # Custom
  ]
```

### Custom Redaction Pattern

Change the redaction placeholder:

```elixir
config :observlib,
  redaction_pattern: "***REDACTED***"  # Default: "[REDACTED]"
```

### Disabling Redaction (Not Recommended)

To disable redaction:

```elixir
config :observlib,
  redacted_attribute_keys: []  # Empty list disables redaction
```

**Warning**: Only disable redaction if you have alternative data protection mechanisms.

### Redaction Examples

```elixir
# Example 1: Login tracking
ObservLib.Logs.info("User logged in", %{
  username: "alice",           # NOT redacted (not sensitive)
  password: "secret",          # REDACTED
  session_token: "xyz123"      # REDACTED
})
# Output: %{username: "alice", password: "[REDACTED]", session_token: "[REDACTED]"}

# Example 2: API call
ObservLib.traced("api_call", %{
  endpoint: "/users",          # NOT redacted
  api_key: "key-abc123",       # REDACTED
  response_size: 1024          # NOT redacted
}, fn -> make_api_call() end)

# Example 3: Payment processing
ObservLib.counter("payments", 1, %{
  amount: 99.99,               # NOT redacted
  card_number: "4111...",      # REDACTED
  customer_id: "cust_123"      # NOT redacted (unless you add to list)
})
```

## Prometheus Security

Secure the Prometheus metrics endpoint.

### Basic Authentication

Protect metrics with HTTP Basic Auth:

```elixir
config :observlib,
  prometheus_basic_auth: {"username", "strong_password"}
```

Access the endpoint:
```bash
curl -u username:strong_password http://localhost:9568/metrics
```

**Security Note**: Always use Basic Auth with TLS to prevent credential interception.

### Rate Limiting

Limit scrape request rate:

```elixir
config :observlib,
  prometheus_rate_limit: 100  # Max 100 requests per minute (default)
```

**Security Benefit**: Prevents DoS attacks on metrics endpoint.

Exceeded requests receive HTTP 429:
```
HTTP/1.1 429 Too Many Requests
Too Many Requests
```

### Connection Limiting

Limit concurrent scrape connections:

```elixir
config :observlib,
  prometheus_max_connections: 10  # Max 10 concurrent (default)
```

**Security Benefit**: Prevents resource exhaustion from connection flooding.

### Custom Port

Change the Prometheus endpoint port:

```elixir
config :observlib,
  prometheus_port: 9090  # Default: 9568
```

### Complete Prometheus Security

Recommended production configuration:

```elixir
config :observlib,
  # Authentication
  prometheus_basic_auth: {"prometheus", System.get_env("PROMETHEUS_PASSWORD")},

  # Rate and connection limits
  prometheus_rate_limit: 100,
  prometheus_max_connections: 10,

  # Custom port (optional)
  prometheus_port: 9568
```

### Network-Level Security

Additional security best practices:

```elixir
# 1. Bind to localhost only (requires firewall/proxy)
# Configure at network level, not in ObservLib

# 2. Use TLS terminating proxy
# nginx/Caddy in front of Prometheus endpoint

# 3. IP allowlisting
# Firewall rules: only allow Prometheus server IP
```

## Environment Variables

Use `config/runtime.exs` for secure configuration with environment variables:

```elixir
# config/runtime.exs
import Config

# Required settings
config :observlib,
  service_name: System.get_env("SERVICE_NAME") || raise("SERVICE_NAME required"),

  # OTLP endpoints
  otlp_endpoint: System.get_env("OTLP_ENDPOINT"),

  # TLS configuration
  tls_verify: System.get_env("TLS_VERIFY", "true") == "true",
  tls_ca_cert_file: System.get_env("TLS_CA_CERT_FILE"),

  # Prometheus security
  prometheus_basic_auth: prometheus_auth(),

  # Resource attributes
  resource_attributes: %{
    "deployment.environment" => System.get_env("ENVIRONMENT", "production"),
    "service.version" => System.get_env("APP_VERSION", "unknown")
  }

# Helper function for Prometheus auth
defp prometheus_auth do
  username = System.get_env("PROMETHEUS_USERNAME")
  password = System.get_env("PROMETHEUS_PASSWORD")

  if username && password do
    {username, password}
  else
    nil  # No auth if credentials not provided
  end
end
```

### Environment Variable Validation

Always validate security-critical environment variables:

```elixir
# Validate TLS certificate file exists
if tls_ca_file = System.get_env("TLS_CA_CERT_FILE") do
  unless File.exists?(tls_ca_file) do
    raise "TLS CA certificate file not found: #{tls_ca_file}"
  end
end

# Validate password strength (optional)
if password = System.get_env("PROMETHEUS_PASSWORD") do
  if String.length(password) < 12 do
    IO.warn("PROMETHEUS_PASSWORD should be at least 12 characters")
  end
end
```

## Quick Start

### Development Configuration

```elixir
# config/dev.exs
config :observlib,
  service_name: "myapp_dev",
  otlp_endpoint: "http://localhost:4318",
  # Use defaults for everything else
```

### Production Configuration

```elixir
# config/prod.exs
config :observlib,
  service_name: "myapp",

  # HTTPS with TLS verification
  otlp_endpoint: "https://collector.prod.example.com:4318",
  tls_verify: true,

  # Secure Prometheus
  prometheus_basic_auth: {
    System.get_env("PROM_USER"),
    System.get_env("PROM_PASS")
  },
  prometheus_rate_limit: 100,
  prometheus_max_connections: 10,

  # Resource limits
  cardinality_limit: 2000,
  max_attribute_count: 128,
  max_attribute_value_size: 4096,
  log_batch_limit: 1000,

  # Attribute redaction (enabled by default)
  redacted_attribute_keys: [
    "password", "token", "api_key", "secret",
    "customer_ssn", "internal_id"  # Add custom patterns
  ]
```

### High-Security Configuration

```elixir
# config/prod.exs (high-security environment)
config :observlib,
  service_name: "myapp",

  # HTTPS with certificate pinning
  otlp_endpoint: "https://collector.prod.example.com:4318",
  tls_verify: true,
  tls_ca_cert_file: "/etc/ssl/certs/corporate-ca.pem",
  tls_versions: [:"tlsv1.3"],  # TLS 1.3 only

  # Strong Prometheus security
  prometheus_basic_auth: {
    System.fetch_env!("PROM_USER"),
    System.fetch_env!("PROM_PASS")
  },
  prometheus_rate_limit: 60,  # Lower limit
  prometheus_max_connections: 5,  # Lower limit

  # Conservative resource limits
  cardinality_limit: 1000,
  max_attribute_count: 64,
  max_attribute_value_size: 2048,
  log_batch_limit: 500,

  # Aggressive redaction
  redacted_attribute_keys: [
    "password", "passwd", "secret", "token",
    "authorization", "auth", "bearer",
    "api_key", "apikey", "access_key", "private_key",
    "credit_card", "creditcard", "card_number", "cvv",
    "ssn", "social_security", "session",
    # Add all custom sensitive fields
    "customer_id", "employee_id", "account_number",
    "routing_number", "tax_id", "passport"
  ],

  # Batch processing
  batch_size: 256,  # Smaller batches
  batch_timeout: 3000  # More frequent exports
```

## Configuration Validation

ObservLib validates all configuration at startup:

```elixir
# This will raise an error at startup:
config :observlib,
  service_name: ""  # Error: service_name must be non-empty

# This will work:
config :observlib,
  service_name: "myapp"  # Valid
```

## Security Configuration Checklist

Use this checklist for production deployments:

- [ ] **TLS enabled** for all OTLP endpoints
- [ ] **Certificate verification** enabled (default)
- [ ] **Prometheus authentication** configured
- [ ] **Rate limiting** configured for Prometheus
- [ ] **Connection limiting** configured for Prometheus
- [ ] **Cardinality limits** set appropriately
- [ ] **Attribute limits** configured
- [ ] **Sensitive keys** added to redaction list
- [ ] **Environment variables** validated
- [ ] **TLS versions** restricted (1.2+)
- [ ] **Custom CA certificates** deployed if needed
- [ ] **Plaintext HTTP** only for localhost

## Troubleshooting

### TLS Certificate Errors

```
Error: certificate verify failed
```

**Solution**: Verify your CA certificate file is correct and accessible:
```bash
openssl verify -CAfile /etc/ssl/certs/ca.pem collector-cert.pem
```

### Rate Limit Exceeded

```
Warning: Prometheus rate limit exceeded
```

**Solution**: Increase rate limit or reduce scrape frequency:
```elixir
config :observlib,
  prometheus_rate_limit: 200  # Increase limit
```

### Attribute Truncation Warnings

```
Warning: Attribute value truncated (original_size: 10000, truncated_size: 4096)
```

**Solution**: Reduce attribute size or increase limit:
```elixir
config :observlib,
  max_attribute_value_size: 8192  # Increase limit
```

## Additional Resources

- [Security Overview](overview.md)
- [Security Best Practices](best-practices.md)
- [Threat Model](threat-model.md)
- [Main Configuration Guide](../../guides/configuration.md)
