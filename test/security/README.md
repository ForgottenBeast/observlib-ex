# Security Test Suite

Comprehensive security tests covering all 14 vulnerabilities remediated in ObservLib.

## Test Files

### 1. `atom_exhaustion_test.exs` - Atom Table Exhaustion Prevention
**Findings Covered:** sec-001, sec-002

**Tests:**
- sec-001: Atom exhaustion prevention in Metrics
  - safe_to_atom/1 prefers existing atoms
  - safe_to_atom/1 warns when creating new atoms
  - VM survives unbounded unique metric names (property test, 1000 runs)
  - Pre-registered metrics avoid atom creation

- sec-002: Atom exhaustion prevention in Telemetry
  - handler_id/1 only accepts atom lists
  - handler_id/1 rejects non-atom elements
  - Telemetry handlers survive many unique prefixes (property test, 100 runs)

### 2. `ets_memory_bounds_test.exs` - Memory Bounds & Resource Limits
**Findings Covered:** sec-003, sec-004, sec-010

**Tests:**
- sec-003: Cardinality limits prevent unbounded ETS growth
  - Cardinality limit prevents unbounded metric variants
  - Existing metric variants can be updated beyond cardinality limit
  - Cardinality limit is per metric name

- sec-004: Log batch limits prevent unbounded queue growth
  - Log batch limit prevents memory exhaustion

- sec-010: Span limits prevent unbounded active spans
  - Active span tracking does not grow unbounded
  - Stale span cleanup prevents memory leaks

### 3. `injection_prevention_test.exs` - Injection Attack Prevention
**Findings Covered:** sec-005, sec-012, sec-014

**Tests:**
- sec-014: Prometheus label injection prevention
  - Escapes CRLF characters in label values
  - Escapes null bytes in label values
  - Escapes control characters in label values
  - Escapes backslashes and quotes in label values
  - Escapes tabs and newlines in label values
  - Comprehensive injection payload is neutralized

- sec-005: Log injection prevention
  - Structured logging prevents log injection
  - Log attributes are properly typed

- sec-012: Header injection prevention
  - OTLP exporter headers are properly structured

### 4. `tls_validation_test.exs` - TLS Security & URL Validation
**Findings Covered:** sec-006, sec-007

**Tests:**
- sec-006: TLS certificate validation
  - TLS verification is enabled by default
  - TLS versions include only secure versions by default
  - Custom CA certificates can be configured
  - HTTPS URLs trigger TLS configuration
  - HTTP to localhost does not trigger TLS warnings
  - HTTP to 127.0.0.1 does not trigger TLS warnings
  - HTTP to remote host triggers security warning
  - HTTP to IPv6 localhost does not trigger warnings

- sec-007: URL validation and SSRF prevention
  - Validates HTTP and HTTPS schemes only
  - Rejects URLs with user info to prevent credential leakage
  - Rejects URLs with missing or empty host
  - Accepts nil and empty string URLs
  - Accepts valid HTTP URLs
  - SSRF payloads are rejected

### 5. `resource_limits_test.exs` - Resource Exhaustion Prevention
**Findings Covered:** sec-003, sec-004, sec-009, sec-010, sec-011

**Tests:**
- sec-009: Attribute value size truncation
  - Truncates oversized string attributes
  - Logs warning when truncating values
  - Preserves values under size limit
  - Does not truncate non-string values
  - Handles arbitrary size strings without crashing (property test, 50 runs)

- sec-011: Attribute count limits
  - Limits number of attributes to configured maximum
  - Preserves attributes under count limit
  - Truncates to first N attributes when limit exceeded
  - Handles arbitrary attribute counts without crashing (property test, 20 runs)

- sec-003: Cardinality limits per metric
  - Enforces cardinality limit per metric name
  - Cardinality limit prevents unbounded growth (property test, 100 runs)

- sec-004: Log batch queue limits
  - Enforces maximum log batch size

- sec-010: Span count limits
  - Span tracking has bounded memory usage

### 6. `access_control_test.exs` - ETS Access Control
**Findings Covered:** sec-013

**Tests:**
- sec-013: ETS table access control
  - Metrics ETS table uses :protected access mode
  - Registry ETS table uses :protected access mode
  - Active spans ETS table uses :protected access mode
  - External processes can read from protected ETS tables
  - External processes cannot write to protected ETS tables
  - External processes cannot delete from protected ETS tables
  - External processes cannot clear protected ETS tables
  - Only MeterProvider process can write to metrics table
  - Only Traces.Provider process can write to spans table
  - ETS tables have read_concurrency enabled for performance

### 7. `header_redaction_test.exs` - Sensitive Header Redaction
**Findings Covered:** sec-012

**Tests:**
- sec-012: Header redaction in error logs
  - Redacts Authorization header in error context
  - Redacts X-API-Key header in error context
  - Redacts X-Auth-Token header in error context
  - Redacts Bearer tokens in various header formats
  - Redacts multiple sensitive headers
  - Handles case-insensitive header name matching
  - Redacts headers with 'token' in the name
  - Redacts headers with 'bearer' in the value
  - Handles non-map error contexts safely
  - Preserves error context structure
  - Error logs use redacted headers
  - Handles atom keys in error context

### 8. `url_validation_test.exs` - URL Validation & SSRF Prevention
**Findings Covered:** sec-007

**Tests:**
- sec-007: URL validation and SSRF prevention
  - Accepts valid HTTP URLs
  - Accepts valid HTTPS URLs
  - Rejects file:// URLs (local file access)
  - Rejects ftp:// URLs
  - Rejects data:// URLs (data URI injection)
  - Rejects gopher:// URLs (gopher protocol injection)
  - Rejects dict:// URLs (dict protocol injection)
  - Rejects ldap:// URLs (LDAP injection)
  - Rejects jar:// URLs (Java archive URLs)
  - Rejects URLs with user info (credentials in URL)
  - Rejects URLs with missing host
  - Accepts nil and empty string (allowing unset endpoints)
  - Comprehensive SSRF payload rejection
  - Allows URLs with query parameters
  - Allows URLs with fragments
  - Allows URLs with custom ports
  - Allows IPv6 addresses

## Test Statistics

- **Total Test Files:** 8
- **Total Test Cases:** 89+ (including property tests with 1000s of runs)
- **Security Findings Covered:** All 14 (sec-001 through sec-014)
- **Property-Based Tests:** 6 (using StreamData for exhaustive testing)

## Running the Tests

Run all security tests:
```bash
mix test --only security
```

Run specific security test file:
```bash
mix test test/security/atom_exhaustion_test.exs
```

Run with verbose output:
```bash
mix test --only security --trace
```

## Test Coverage by Security Finding

- **sec-001:** Atom exhaustion in Metrics → `atom_exhaustion_test.exs`
- **sec-002:** Atom exhaustion in Telemetry → `atom_exhaustion_test.exs`
- **sec-003:** ETS memory bounds (cardinality) → `ets_memory_bounds_test.exs`, `resource_limits_test.exs`
- **sec-004:** Log batch limits → `ets_memory_bounds_test.exs`, `resource_limits_test.exs`
- **sec-005:** Log injection → `injection_prevention_test.exs`
- **sec-006:** TLS validation → `tls_validation_test.exs`
- **sec-007:** URL validation & SSRF → `tls_validation_test.exs`, `url_validation_test.exs`
- **sec-008:** Connection/rate limiting (covered by existing tests in `prometheus_reader_test.exs`)
- **sec-009:** Attribute value size → `resource_limits_test.exs`
- **sec-010:** Span limits → `ets_memory_bounds_test.exs`, `resource_limits_test.exs`
- **sec-011:** Attribute count → `resource_limits_test.exs`
- **sec-012:** Header redaction/injection → `injection_prevention_test.exs`, `header_redaction_test.exs`
- **sec-013:** ETS access control → `access_control_test.exs`
- **sec-014:** Prometheus label injection → `injection_prevention_test.exs`

## Property-Based Testing

The test suite includes property-based tests using StreamData to verify security controls under various inputs:

1. **Atom exhaustion** - 1000+ unique metric names
2. **Attribute sizes** - Arbitrary size strings (0-50KB)
3. **Attribute counts** - Arbitrary counts (0-500)
4. **Cardinality limits** - 100+ unique metric variants
5. **Telemetry handlers** - 100 unique prefixes

These property tests provide much stronger guarantees than example-based tests alone.
