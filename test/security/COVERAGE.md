# Security Test Coverage Matrix

This document maps each of the 14 security findings to their corresponding test coverage.

## Complete Coverage Map

| Finding | Description | Test File(s) | Test Count | Property Tests |
|---------|-------------|--------------|------------|----------------|
| sec-001 | Atom exhaustion in Metrics | `atom_exhaustion_test.exs` | 4 | ✓ (1000 runs) |
| sec-002 | Atom exhaustion in Telemetry | `atom_exhaustion_test.exs` | 3 | ✓ (100 runs) |
| sec-003 | ETS memory bounds (cardinality) | `ets_memory_bounds_test.exs`<br>`resource_limits_test.exs` | 5 | ✓ (100 runs) |
| sec-004 | Log batch limits | `ets_memory_bounds_test.exs`<br>`resource_limits_test.exs` | 2 | - |
| sec-005 | Log injection prevention | `injection_prevention_test.exs` | 2 | - |
| sec-006 | TLS certificate validation | `tls_validation_test.exs` | 8 | - |
| sec-007 | URL validation & SSRF | `tls_validation_test.exs`<br>`url_validation_test.exs` | 24 | - |
| sec-008 | Connection/rate limiting | *(covered in existing `prometheus_reader_test.exs`)* | - | - |
| sec-009 | Attribute value size limits | `resource_limits_test.exs` | 5 | ✓ (50 runs) |
| sec-010 | Span count limits | `ets_memory_bounds_test.exs`<br>`resource_limits_test.exs` | 3 | - |
| sec-011 | Attribute count limits | `resource_limits_test.exs` | 4 | ✓ (20 runs) |
| sec-012 | Header redaction/injection | `injection_prevention_test.exs`<br>`header_redaction_test.exs` | 13 | - |
| sec-013 | ETS access control | `access_control_test.exs` | 10 | - |
| sec-014 | Prometheus label injection | `injection_prevention_test.exs` | 6 | - |

## Summary Statistics

- **Total Security Findings:** 14
- **Findings with Tests:** 14 (100% coverage)
- **Total Test Files:** 8
- **Total Test Cases:** 89+
- **Property-Based Tests:** 6 tests covering 5 findings
- **Total Property Test Runs:** 1,270+ executions

## Test Execution Strategy

### Quick Verification
```bash
mix test test/security/ --max-failures 1
```

### Full Security Suite
```bash
mix test --only security
```

### Individual Finding Verification
```bash
# Test atom exhaustion (sec-001, sec-002)
mix test test/security/atom_exhaustion_test.exs

# Test memory bounds (sec-003, sec-004, sec-010)
mix test test/security/ets_memory_bounds_test.exs

# Test injection prevention (sec-005, sec-012, sec-014)
mix test test/security/injection_prevention_test.exs

# Test TLS & URL validation (sec-006, sec-007)
mix test test/security/tls_validation_test.exs

# Test resource limits (sec-003, sec-004, sec-009, sec-010, sec-011)
mix test test/security/resource_limits_test.exs

# Test access control (sec-013)
mix test test/security/access_control_test.exs

# Test header redaction (sec-012)
mix test test/security/header_redaction_test.exs

# Test URL validation (sec-007)
mix test test/security/url_validation_test.exs
```

## Property-Based Test Details

Property-based tests use StreamData to generate random inputs and verify security controls:

1. **Atom Exhaustion (sec-001)**
   - Generates 1000 unique alphanumeric metric names
   - Verifies VM stability under unbounded atom creation attempts

2. **Telemetry Handlers (sec-002)**
   - Tests 100 unique event prefixes
   - Ensures handler attachment/detachment works correctly

3. **Attribute Sizes (sec-009)**
   - Tests strings from 0 to 50KB
   - Verifies truncation logic at all sizes

4. **Attribute Counts (sec-011)**
   - Tests 0 to 500 attributes
   - Ensures count limiting works correctly

5. **Cardinality Limits (sec-003)**
   - Tests 5000 unique metric variants
   - Verifies cardinality enforcement across many IDs

6. **Resource Limits (various)**
   - Multiple property tests verify bounded resource usage

## Integration with CI/CD

Add to your CI pipeline:

```yaml
# .github/workflows/security.yml
name: Security Tests

on: [push, pull_request]

jobs:
  security-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.14'
          otp-version: '25'
      - run: mix deps.get
      - run: mix test --only security
```

## Maintenance Notes

- All tests are tagged with `@moduletag :security`
- Property tests have extended timeouts (60-120 seconds)
- Some tests use `async: false` to avoid interference
- Tests verify both positive cases (security working) and negative cases (attacks prevented)
