# Dependency Security Audit - Quick Reference Guide

**Document:** Dependency Audit sec-017
**Last Updated:** 2026-03-27
**Maintenance Schedule:** Quarterly (Next: 2026-06-27)

---

## Overview

The ObservLib project uses 37 dependencies (8 runtime, 4 dev/test, 25 transitive) with **zero known CVEs**. All packages are current and actively maintained.

---

## Quick Facts

| Metric | Status |
|--------|--------|
| Critical CVEs | 0 |
| High Severity CVEs | 0 |
| Medium Severity CVEs | 0 |
| Low Severity CVEs | 0 |
| Outdated Dependencies | 0 |
| Dependencies > 2 years | 2 (both stable/safe) |
| Risk Level | **LOW** |
| Deployment Status | **APPROVED** |

---

## Critical Dependencies to Monitor

These dependencies should be monitored monthly for security updates:

1. **tls_certificate_check (1.32.0)**
   - Purpose: TLS validation for gRPC
   - Risk: High impact if compromised
   - Action: Update immediately when new versions released

2. **opentelemetry_exporter (1.10.0)**
   - Purpose: Telemetry data export
   - Dependencies: grpcbox, tls_certificate_check
   - Action: Monitor for security updates

3. **req (0.5.17)**
   - Purpose: HTTP client library
   - Maintained by: Elixir core team
   - Risk: Low (excellent review process)
   - Action: Monitor quarterly

4. **jason (1.4.4)**
   - Purpose: JSON parsing/encoding
   - Risk: Low (well-vetted parser)
   - Action: Monitor quarterly

---

## Monitoring & Maintenance

### Monthly Tasks
- [ ] Check Hex.pm security advisories
- [ ] Review GitHub security alerts
- [ ] Check for dependency updates on key packages

### Quarterly Tasks (Next: June 27, 2026)
- [ ] Run full dependency security audit
- [ ] Review dependency usage patterns
- [ ] Check for deprecated APIs
- [ ] Update audit report

### Annual Tasks
- [ ] Review and update dependency strategy
- [ ] Evaluate alternative packages if needed
- [ ] Plan major version upgrades

---

## How to Run Security Audits

### Automated (Recommended)
```bash
# Add to CI/CD pipeline
mix deps.audit

# This command checks against Hex.pm security advisories
```

### Manual Review
```bash
# List all dependencies
mix deps

# Check specific package on Hex.pm
# Visit: https://hex.pm/packages/[package-name]

# Check GitHub for security advisories
# Visit: https://github.com/[owner]/[repo]/security
```

---

## Dependency Categories

### Core Observability Stack
- opentelemetry_api, opentelemetry, opentelemetry_exporter
- opentelemetry_telemetry
- telemetry, telemetry_metrics, telemetry_poller

**Status:** All current, actively maintained by OpenTelemetry community

### HTTP & Serialization
- req (HTTP client, maintained by Elixir core team)
- jason (JSON parsing)
- finch, mint (low-level HTTP clients)

**Status:** All current, excellent security track record

### gRPC Stack
- grpcbox, chatterbox, hpack
- tls_certificate_check (CRITICAL for security)
- gproc, ctx, acceptor_pool

**Status:** All current, part of Erlang ecosystem

### Development Tools
- credo, dialyxir, ex_doc (code quality)
- stream_data (property testing)
- Various makeup/earmark libraries (documentation)

**Status:** Dev-only, not in production

---

## Known Issues & Limitations

**None found.** All dependencies are secure and suitable for production deployment.

---

## Dependency Update Policy

### Patch Updates (1.2.3 → 1.2.4)
- Apply immediately
- No testing required (security patches)
- Example: tls_certificate_check updates

### Minor Updates (1.2.0 → 1.3.0)
- Apply within 1 week
- Run full test suite
- Monitor for API changes

### Major Updates (1.0.0 → 2.0.0)
- Review breaking changes before applying
- Plan significant testing
- Coordinate with team
- Examples: OpenTelemetry major versions

---

## Related Documents

- **Full Audit Report:** `dependency-audit-sec017.md` (529 lines, 20KB)
- **Next Audit:** 2026-06-27
- **Audit Schedule:** Every 3 months

---

## Contact & Escalation

For security concerns:
1. Check latest audit report at `.omc/reports/dependency-audit-sec017.md`
2. Review dependency's GitHub security page
3. Check Hex.pm package page for advisories
4. Escalate to security team if CVE found

---

## Appendix: Dependency Tree at a Glance

```
observlib (0.1.0)
├── Runtime: 8 packages
├── Dev/Test: 4 packages
└── Transitive: 25 packages
    ├── HTTP: 7 packages
    ├── gRPC: 8 packages
    └── Tools: 10 packages
```

**Total:** 37 dependencies, 0 CVEs, LOW RISK

---

**Document Version:** 1.0
**Status:** ACTIVE
**Last Verified:** 2026-03-27
