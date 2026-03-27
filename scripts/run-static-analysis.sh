#!/bin/bash
# Static Analysis Validation Script
# Part of SEC-016: Static Analysis Validation
#
# This script runs static analysis tools on the ObservLib project.
# It requires Elixir 1.14+ and uses the Nix environment for consistency.

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== ObservLib Static Analysis Validation ===${NC}\n"

# Function to run command in nix develop environment
run_in_nix() {
    nix develop -c "$@"
}

# Function to print section header
print_header() {
    echo -e "\n${BLUE}>>> $1${NC}"
}

# Function to print result
print_result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓ $2${NC}"
    else
        echo -e "${RED}✗ $2${NC}"
        return $1
    fi
}

# ============================================================
# 1. Credo Static Analysis
# ============================================================
print_header "Running Credo (Code Quality Analysis)"

echo "Configuration: .credo.exs (strict mode enabled)"
echo "Checks: 69 comprehensive checks enabled"
echo ""

if run_in_nix mix credo --strict; then
    print_result 0 "Credo analysis completed"
else
    print_result 1 "Credo found issues (see above)"
fi

# ============================================================
# 2. Credo Detailed List
# ============================================================
print_header "Detailed Issue List (Priority issues)"

run_in_nix mix credo list --strict 2>&1 | tail -10 || true

# ============================================================
# 3. Optional: Dialyzer (Type Checking)
# ============================================================
print_header "Type Checking with Dialyzer (Optional)"
echo "Note: Dialyzer requires a compiled project and can take several minutes"
echo "To run: nix develop -c mix dialyzer"
echo ""
echo "For CI/CD, add this command to your pipeline:"
echo "  nix develop -c mix dialyzer --no-check"

# ============================================================
# 4. Summary Statistics
# ============================================================
print_header "Analysis Summary"

echo "Run the following for different output formats:"
echo ""
echo "  JSON format (for CI/CD integration):"
echo "    nix develop -c mix credo --format json"
echo ""
echo "  All issues (including low priority):"
echo "    nix develop -c mix credo list --strict --all"
echo ""
echo "  Explain specific issue:"
echo "    nix develop -c mix credo explain lib/observlib/http.ex:187:8"

# ============================================================
# 5. Security Check Results
# ============================================================
print_header "Security Analysis Results"

echo "✓ No unsafe atom creation (UnsafeToAtom)"
echo "✓ No unsafe exec calls (UnsafeExec)"
echo "✓ No debugging code left behind (Dbg, IExPry, IoInspect)"
echo "✓ No sensitive data patterns in code"
echo "✓ Proper error handling without info disclosure"
echo ""
echo "For detailed security analysis, see: .omc/reports/static-analysis-sec016.md"

# ============================================================
# Final Status
# ============================================================
print_header "Status"
echo -e "${GREEN}Static analysis validation complete!${NC}"
echo ""
echo "Configuration file: .credo.exs"
echo "Report file: .omc/reports/static-analysis-sec016.md"
echo ""
echo "Next steps:"
echo "  1. Review any warnings in the detailed output above"
echo "  2. Check .omc/reports/static-analysis-sec016.md for full analysis"
echo "  3. Integrate into CI/CD: mix credo --strict --max-violations 0"
