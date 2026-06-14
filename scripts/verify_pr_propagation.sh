#!/usr/bin/env bash
#
# verify_pr_propagation.sh — Assert PRs were opened for eligible WI branches.
#
# Usage:
#   ./scripts/verify_pr_propagation.sh [REPO_DIR]
#

set -euo pipefail

REPO_DIR="${1:-.}"
REPO_DIR="$(cd "${REPO_DIR}" && pwd)"

WI_ID="${WI_ID:-WI-440219}"
PRS_FILE="${PRS_FILE:-${REPO_DIR}/.propagation-logs/pull-requests.txt}"

EXPECTED_PR_BRANCHES=(
  feature/payment-gateway
  feature/ledger-audit
  feature/compliance-reporting
)

EXPECTED_NO_PR=(
  release/v1.0
  feature/database-migration
  infra/kubernetes-config
)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
pass=0
fail=0

check_pass() { echo -e "${GREEN}PASS${NC}  $*"; pass=$((pass + 1)); }
check_fail() { echo -e "${RED}FAIL${NC}  $*" >&2; fail=$((fail + 1)); }

pr_for_branch() {
  local branch="$1"
  if [[ ! -f "${PRS_FILE}" ]]; then
    return 1
  fi
  grep -F "${branch}|" "${PRS_FILE}" 2>/dev/null | head -1 | cut -d'|' -f2-
}

echo "PR Propagation Verification"
echo "==========================="
echo "PR list file: ${PRS_FILE}"
echo ""

if [[ ! -f "${PRS_FILE}" ]]; then
  check_fail "Missing ${PRS_FILE} — run propagate_patch.sh with PROPAGATION_MODE=pr first"
  exit 1
fi

echo "--- Branches that MUST have an open PR ---"
for branch in "${EXPECTED_PR_BRANCHES[@]}"; do
  url="$(pr_for_branch "${branch}" || true)"
  if [[ -n "${url}" ]]; then
    check_pass "${branch} — PR opened (${url})"
  else
    check_fail "${branch} — no PR recorded"
  fi
done

echo ""
echo "--- WI branches that must NOT have a PR (cherry-pick should fail) ---"
for branch in "${EXPECTED_NO_PR[@]}"; do
  url="$(pr_for_branch "${branch}" || true)"
  if [[ -n "${url}" ]]; then
    check_fail "${branch} — unexpected PR ${url}"
  else
    check_pass "${branch} — no PR (expected)"
  fi
done

echo ""
pr_count="$(grep -c '|' "${PRS_FILE}" 2>/dev/null || echo 0)"
if [[ "${pr_count}" -ge 3 ]]; then
  check_pass "At least 3 PRs recorded (${pr_count} total)"
else
  check_fail "Expected ≥3 PRs, found ${pr_count}"
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -gt 0 ]] && exit 1
exit 0
