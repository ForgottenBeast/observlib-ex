# Security Best Practices

This guide provides actionable security recommendations for deploying and operating ObservLib in production environments.

## Production Deployment Checklist

Use this checklist before deploying to production:

### Network Security

- [ ] **Use HTTPS** for all OTLP endpoints
- [ ] **Enable TLS verification** (default: enabled)
- [ ] **Use TLS 1.2+** only (default: 1.2 and 1.3)
- [ ] **Deploy custom CA certificates** if using internal PKI
- [ ] **Isolate metrics endpoint** to monitoring network only
- [ ] **Use firewall rules** to restrict Prometheus scraper IPs
- [ ] **Deploy TLS terminating proxy** (nginx/Caddy) for Prometheus endpoint

### Access Control

- [ ] **Enable Prometheus Basic Auth** with strong passwords
- [ ] **Rotate credentials** quarterly or per policy
- [ ] **Use unique credentials** per environment
- [ ] **Store credentials in secrets manager** (not in code)
- [ ] **Apply principle of least privilege** to observability data access

### Resource Protection

- [ ] **Set cardinality limits** appropriate for your scale
- [ ] **Configure attribute limits** (count and size)
- [ ] **Enable rate limiting** on Prometheus endpoint
- [ ] **Set connection limits** on Prometheus endpoint
- [ ] **Monitor resource usage** (memory, connections)

### Data Protection

- [ ] **Configure attribute redaction** for sensitive keys
- [ ] **Add custom redaction patterns** specific to your domain
- [ ] **Verify no credentials** in observability data
- [ ] **Review exported metrics** for sensitive information
- [ ] **Test redaction** before production deployment

### Operational Security

- [ ] **Keep dependencies updated** (mix deps.update)
- [ ] **Run security tests** in CI/CD pipeline
- [ ] **Monitor security warnings** in application logs
- [ ] **Set up alerts** for rate limiting and resource exhaustion
- [ ] **Review security configuration** quarterly
- [ ] **Document incident response** procedures

## Network Isolation

### Architecture Overview

```
┌─────────────────────────────────────────────────┐
│                 Public Internet                 │
└─────────────────────────────────────────────────┘
                        │
                 ┌──────▼──────┐
                 │  Firewall   │
                 └──────┬──────┘
                        │
┌───────────────────────┼────────────────────────┐
│  Application Network  │                        │
│                       │                        │
│  ┌────────────┐      │      ┌──────────────┐  │
│  │  App Node  │──────┼─────▶│ OTLP Collector│  │
│  │ (ObservLib)│      │      │   (HTTPS)     │  │
│  └────────────┘      │      └──────────────┘  │
│         │            │                         │
│         │ localhost  │                         │
│         ▼            │                         │
│  ┌────────────┐     │                         │
│  │ Prometheus │◀────┼──────────────┐          │
│  │  Endpoint  │     │              │          │
│  │   :9568    │     │              │          │
│  └────────────┘     │              │          │
└─────────────────────┼──────────────┼──────────┘
                      │              │
              ┌───────▼────┐  ┌──────▼─────────┐
              │ Monitoring │  │  Log Analysis  │
              │  Network   │  │    Network     │
              └────────────┘  └────────────────┘
```

### Firewall Configuration

**Ingress Rules** (Application Node):
```bash
# Allow HTTPS to OTLP collector
iptables -A OUTPUT -p tcp --dport 4318 -d collector.internal -j ACCEPT

# Allow Prometheus scraper (monitoring network only)
iptables -A INPUT -p tcp --dport 9568 -s 10.0.1.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 9568 -j DROP

# Default deny
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
```

**Security Groups** (AWS/Cloud):
```yaml
# Application Security Group
ingress:
  - port: 9568
    protocol: tcp
    source: prometheus-sg  # Only Prometheus server
    description: "Prometheus metrics scrape"

egress:
  - port: 4318
    protocol: tcp
    destination: otlp-collector-sg  # Only OTLP collector
    description: "OTLP export"
```

### Network Segmentation

**Best Practice**: Separate observability traffic by function.

```elixir
# config/prod.exs
config :observlib,
  # Traces to dedicated backend
  otlp_traces_endpoint: "https://traces.internal.corp:4318",

  # Metrics to different backend
  otlp_metrics_endpoint: "https://metrics.internal.corp:4318",

  # Logs to separate backend
  otlp_logs_endpoint: "https://logs.internal.corp:4318",

  # Prometheus on internal network only
  prometheus_port: 9568
```

### VPC/VLAN Isolation

Deploy ObservLib in isolated network segments:

- **Application VPC**: Where ObservLib runs
- **Monitoring VPC**: Where Prometheus/Grafana run
- **Collector VPC**: Where OTLP collectors run
- **VPC Peering**: Controlled connections between segments

## Monitoring and Alerting

### Security Event Monitoring

Set up alerts for security-relevant events:

```elixir
# Example: Alert on rate limiting
def handle_event([:observlib, :prometheus, :rate_limited], _measurements, _metadata, _config) do
  AlertManager.send_alert(
    severity: :warning,
    title: "ObservLib Prometheus rate limit exceeded",
    description: "Possible DoS attack or misconfigured scraper"
  )
end

# Example: Alert on attribute truncation
def handle_event([:observlib, :attributes, :truncated], measurements, metadata, _config) do
  if measurements.truncated_count > 100 do
    AlertManager.send_alert(
      severity: :info,
      title: "High attribute truncation rate",
      description: "Application may be sending oversized attributes"
    )
  end
end
```

### Key Metrics to Monitor

Monitor these metrics for security insights:

```
# Connection health
observlib_prometheus_active_connections
observlib_prometheus_connection_limit_exceeded_total

# Rate limiting
observlib_prometheus_rate_limit_exceeded_total
observlib_prometheus_requests_total

# Resource usage
observlib_metrics_cardinality_limit_exceeded_total
observlib_attributes_truncated_total
observlib_attributes_count_exceeded_total

# TLS health
observlib_http_tls_errors_total
observlib_http_certificate_validation_failures_total
```

### Alerting Rules (Prometheus)

```yaml
# prometheus-rules.yml
groups:
  - name: observlib_security
    interval: 30s
    rules:
      # Rate limit exceeded
      - alert: ObservLibRateLimitExceeded
        expr: rate(observlib_prometheus_rate_limit_exceeded_total[5m]) > 0
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "ObservLib rate limit exceeded"
          description: "Prometheus endpoint is being rate limited"

      # Connection limit reached
      - alert: ObservLibConnectionLimitReached
        expr: observlib_prometheus_active_connections >= observlib_prometheus_max_connections
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "ObservLib connection limit reached"

      # High cardinality
      - alert: ObservLibHighCardinality
        expr: rate(observlib_metrics_cardinality_limit_exceeded_total[10m]) > 0
        for: 10m
        labels:
          severity: info
        annotations:
          summary: "High metric cardinality detected"

      # TLS errors
      - alert: ObservLibTLSErrors
        expr: rate(observlib_http_tls_errors_total[5m]) > 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "TLS connection errors detected"
```

### Log Monitoring

Monitor application logs for security warnings:

```bash
# Example: Monitor for security warnings
tail -f /var/log/app/production.log | grep -E "rate limit|connection limit|truncated|plaintext HTTP"

# Example: Count security events
grep "Prometheus rate limit exceeded" /var/log/app/production.log | wc -l
```

Set up log aggregation with alerts:

```
# Elasticsearch/Kibana query
level: "warning" AND message: ("rate limit" OR "connection limit" OR "truncated")

# Splunk query
index=production level=warning (message="*rate limit*" OR message="*connection limit*")

# CloudWatch Logs Insights
fields @timestamp, @message
| filter @message like /rate limit|connection limit|truncated/
| sort @timestamp desc
```

## Incident Response

### Security Incident Types

**Type 1: Resource Exhaustion Attack**
- Symptoms: High memory usage, rate limiting triggered, connection limits reached
- Response: Temporarily lower limits, block attacking IPs, scale horizontally

**Type 2: Credential Compromise**
- Symptoms: Unauthorized Prometheus access, unusual scrape patterns
- Response: Rotate credentials immediately, audit access logs, review firewall rules

**Type 3: Data Exfiltration**
- Symptoms: Large data exports, unusual OTLP traffic patterns
- Response: Verify OTLP endpoints, check for sensitive data in exports, rotate API keys

**Type 4: TLS/Certificate Issues**
- Symptoms: Certificate validation failures, TLS errors in logs
- Response: Verify certificate validity, check CA bundle, update certificates

### Incident Response Playbook

#### 1. Detection Phase

```bash
# Check current security status
mix observlib.security_status

# Review recent logs
tail -n 1000 /var/log/app/production.log | grep -i "warning\|error"

# Check metrics
curl -u user:pass http://localhost:9568/metrics | grep observlib_security
```

#### 2. Containment Phase

```elixir
# Immediately lower limits (hot reload if supported)
config :observlib,
  prometheus_rate_limit: 10,           # Reduce rate limit
  prometheus_max_connections: 2,       # Reduce connections
  cardinality_limit: 500               # Reduce cardinality

# Or restart with new config
```

```bash
# Block attacking IPs at firewall level
iptables -A INPUT -s 203.0.113.0/24 -j DROP

# Temporarily disable Prometheus endpoint if needed
iptables -A INPUT -p tcp --dport 9568 -j DROP
```

#### 3. Investigation Phase

```bash
# Review access logs
grep "9568" /var/log/nginx/access.log | tail -100

# Check connection sources
netstat -an | grep :9568

# Audit authentication attempts (if using Basic Auth)
grep "401 Unauthorized" /var/log/app/production.log

# Review exported data
curl -u user:pass http://localhost:9568/metrics > metrics_dump.txt
grep -i "password\|token\|secret" metrics_dump.txt
```

#### 4. Recovery Phase

```elixir
# Rotate compromised credentials
config :observlib,
  prometheus_basic_auth: {"prometheus", "NEW_SECURE_PASSWORD"}

# Update OTLP endpoints if compromised
config :observlib,
  otlp_endpoint: "https://new-collector.internal.corp:4318"

# Restore normal limits
config :observlib,
  prometheus_rate_limit: 100,
  prometheus_max_connections: 10,
  cardinality_limit: 2000
```

#### 5. Post-Incident Phase

- Document incident timeline
- Review and update security configuration
- Implement additional monitoring/alerting
- Conduct blameless post-mortem
- Update incident response procedures

## Regular Security Updates

### Dependency Management

**Weekly**:
```bash
# Check for dependency updates
mix hex.outdated

# Review security advisories
mix hex.audit
```

**Monthly**:
```bash
# Update dependencies
mix deps.update --all

# Run security tests
mix test --only security

# Review CHANGELOG for security fixes
```

**Quarterly**:
```bash
# Full security review
mix deps.audit
mix credo --strict
mix dialyzer

# Update Elixir/OTP versions
asdf install erlang latest
asdf install elixir latest
```

### Security Patch Process

1. **Monitor Security Advisories**
   - Subscribe to ObservLib security notifications
   - Monitor OWASP/NIST vulnerability databases
   - Track Elixir security mailing list

2. **Evaluate Patches**
   - Review CVE severity (Critical, High, Medium, Low)
   - Assess impact on your deployment
   - Plan patch deployment timeline

3. **Test in Staging**
   ```bash
   # Update to patched version
   mix deps.update observlib

   # Run all tests
   mix test

   # Run security tests specifically
   mix test --only security

   # Smoke test in staging environment
   ```

4. **Deploy to Production**
   - Deploy during maintenance window
   - Use blue-green or canary deployment
   - Monitor for issues post-deployment
   - Have rollback plan ready

### Configuration Review Schedule

**Monthly**:
- Review resource limits effectiveness
- Check for new sensitive attribute patterns
- Verify TLS certificate expiration dates
- Audit Prometheus access credentials

**Quarterly**:
- Full security configuration review
- Update redaction patterns
- Review and update firewall rules
- Audit access control policies
- Update security documentation

**Annually**:
- Security architecture review
- Penetration testing (if required)
- Compliance audit (SOC2, ISO 27001, etc.)
- Update incident response procedures

## Secure Configuration Management

### Secrets Management

**Never commit secrets to version control**:

```elixir
# ❌ BAD - hardcoded credentials
config :observlib,
  prometheus_basic_auth: {"admin", "password123"}

# ✅ GOOD - environment variables
config :observlib,
  prometheus_basic_auth: {
    System.get_env("PROM_USER"),
    System.get_env("PROM_PASS")
  }

# ✅ BETTER - secrets manager
config :observlib,
  prometheus_basic_auth: SecretManager.get_credentials("observlib/prometheus")
```

### Vault/Secrets Manager Integration

```elixir
# config/runtime.exs
import Config

# Fetch secrets from HashiCorp Vault
defmodule SecretsLoader do
  def load_from_vault(path) do
    case Vault.read(path) do
      {:ok, %{"data" => data}} -> data
      {:error, reason} -> raise "Failed to load secrets: #{reason}"
    end
  end
end

secrets = SecretsLoader.load_from_vault("secret/observlib/prod")

config :observlib,
  otlp_endpoint: secrets["otlp_endpoint"],
  prometheus_basic_auth: {
    secrets["prom_username"],
    secrets["prom_password"]
  }
```

### Configuration Validation

Implement validation in application startup:

```elixir
# lib/myapp/application.ex
defmodule MyApp.Application do
  def start(_type, _args) do
    # Validate security configuration
    validate_security_config!()

    # ... rest of application start
  end

  defp validate_security_config! do
    # Check TLS enabled for production
    if prod?() and not tls_enabled?() do
      raise "TLS must be enabled in production"
    end

    # Check Prometheus auth configured
    if prod?() and not prometheus_auth_configured?() do
      IO.warn("Prometheus endpoint is not authenticated in production")
    end

    # Check for plaintext endpoints
    if plaintext_endpoint?() do
      IO.warn("Plaintext OTLP endpoint detected. Use HTTPS in production.")
    end
  end

  defp prod?, do: Application.get_env(:myapp, :environment) == :prod
  defp tls_enabled?, do: Application.get_env(:observlib, :tls_verify, true)
  defp prometheus_auth_configured? do
    Application.get_env(:observlib, :prometheus_basic_auth) != nil
  end
  defp plaintext_endpoint? do
    endpoint = Application.get_env(:observlib, :otlp_endpoint)
    endpoint && String.starts_with?(endpoint, "http://")
  end
end
```

## Compliance and Auditing

### Audit Logging

Log security-relevant configuration and events:

```elixir
# Log security configuration at startup
Logger.info("Security configuration loaded",
  tls_verify: true,
  prometheus_auth: true,
  cardinality_limit: 2000,
  rate_limit: 100
)

# Log security events
Logger.warning("Rate limit exceeded", client_ip: remote_ip)
Logger.warning("Invalid authentication attempt", client_ip: remote_ip)
Logger.info("Attribute redacted", key: "password")
```

### Compliance Mapping

**SOC 2 Controls**:
- CC6.1: Logical access controls → Prometheus Basic Auth
- CC6.6: Encryption in transit → TLS configuration
- CC6.7: Encryption at rest → (handled by backend)
- CC7.2: System monitoring → Security metrics and alerts

**ISO 27001**:
- A.9.4.1: Access control → ETS protection, Prometheus auth
- A.10.1.1: Cryptographic controls → TLS 1.2+
- A.12.6.1: Security event logging → Security warnings
- A.14.2.1: Secure development → Security tests

**PCI DSS** (if handling payment data):
- Req 2.2.4: Configure security parameters → Secure defaults
- Req 4.1: Encrypt transmission → TLS configuration
- Req 6.5.3: Insecure crypto → TLS 1.2+ only
- Req 10.2: Log security events → Security event logging

## Additional Security Measures

### Rate Limiting Beyond Prometheus

Consider adding application-level rate limiting:

```elixir
# Use a rate limiting library
plug Plug.RateLimit,
  interval_seconds: 60,
  max_requests: 1000,
  trust_proxy_headers: true
```

### Web Application Firewall (WAF)

Deploy a WAF in front of your application:
- AWS WAF
- Cloudflare WAF
- ModSecurity

### DDoS Protection

Use DDoS mitigation services:
- Cloudflare
- AWS Shield
- Fastly

### Security Scanning

Run regular security scans:

```bash
# Dependency vulnerability scanning
mix deps.audit

# Static code analysis
mix credo --strict

# Type checking
mix dialyzer
```

## Summary Checklist

Quick reference for security best practices:

- ✅ **TLS everywhere** in production
- ✅ **Strong authentication** on Prometheus endpoint
- ✅ **Network isolation** for observability traffic
- ✅ **Resource limits** configured appropriately
- ✅ **Sensitive data redaction** enabled
- ✅ **Security monitoring** and alerting active
- ✅ **Incident response** procedures documented
- ✅ **Regular updates** scheduled
- ✅ **Secrets management** implemented
- ✅ **Compliance requirements** mapped and met

## Additional Resources

- [Security Overview](overview.md)
- [Security Configuration](configuration.md)
- [Threat Model](threat-model.md)
- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks/)
