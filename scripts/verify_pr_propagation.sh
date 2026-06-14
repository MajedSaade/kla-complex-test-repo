#!/usr/bin/env bash
#
# verify_pr_propagation.sh — Assert PRs were opened for eligible WI branches.
#
# A branch passes if either:
#   - a PR was opened/recorded this run, OR
#   - the definitive fix is already present on the branch (merged previously)
#
# Usage:
#   ./scripts/verify_pr_propagation.sh [REPO_DIR]
#

set -euo pipefail

REPO_DIR="${1:-.}"
REPO_DIR="$(cd "${REPO_DIR}" && pwd)"

WI_ID="${WI_ID:-WI-440219}"
AFFECTED_FILE="${AFFECTED_FILE:-src/payment/transaction_queue.py}"
FIX_MARKER="${FIX_MARKER:-threading.RLock()  # WI-440219: definitive thread-safe fix}"
PRS_FILE="${PRS_FILE:-${REPO_DIR}/.propagation-logs/pull-requests.txt}"
SUMMARY_FILE="${SUMMARY_FILE:-${REPO_DIR}/.propagation-logs/propagation-summary.txt}"

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
satisfied=0

check_pass() { echo -e "${GREEN}PASS${NC}  $*"; pass=$((pass + 1)); }
check_fail() { echo -e "${RED}FAIL${NC}  $*" >&2; fail=$((fail + 1)); }

branch_ref() {
  local branch="$1"
  if git -C "${REPO_DIR}" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
    echo "${branch}"
  elif git -C "${REPO_DIR}" show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
    echo "origin/${branch}"
  else
    echo "${branch}"
  fi
}

branch_has_fix() {
  git -C "${REPO_DIR}" show "$(branch_ref "$1"):${AFFECTED_FILE}" 2>/dev/null \
    | grep -Fq "${FIX_MARKER}" || return 1
}

pr_for_branch() {
  local branch="$1"
  [[ -f "${PRS_FILE}" ]] || return 1
  grep -F "${branch}|" "${PRS_FILE}" 2>/dev/null | head -1 | cut -d'|' -f2-
}

open_pr_from_summary() {
  local branch="$1"
  [[ -f "${SUMMARY_FILE}" ]] || return 1
  grep -E "^PR[[:space:]]+${branch//\//\\/}[[:space:]]—" "${SUMMARY_FILE}" 2>/dev/null \
    | head -1 \
    | grep -oE 'https://github.com/[^[:space:]]+' \
    | head -1
}

echo "PR Propagation Verification"
echo "==========================="
echo "Repository : ${REPO_DIR}"
echo "PR list    : ${PRS_FILE}"
echo ""

if [[ ! -f "${PRS_FILE}" && ! -f "${SUMMARY_FILE}" ]]; then
  check_fail "Missing propagation logs — run propagate_patch.sh with PROPAGATION_MODE=pr first"
  exit 1
fi

echo "--- Branches that MUST have a PR or the fix already ---"
for branch in "${EXPECTED_PR_BRANCHES[@]}"; do
  url="$(pr_for_branch "${branch}" || true)"
  if [[ -z "${url}" ]]; then
    url="$(open_pr_from_summary "${branch}" || true)"
  fi

  if [[ -n "${url}" ]]; then
    check_pass "${branch} — PR recorded (${url})"
    satisfied=$((satisfied + 1))
  elif branch_has_fix "${branch}"; then
    check_pass "${branch} — fix already on branch (no new PR needed)"
    satisfied=$((satisfied + 1))
  else
    check_fail "${branch} — no PR recorded and fix not present on branch"
  fi
done

echo ""
echo "--- WI branches that must NOT have a PR (cherry-pick should fail) ---"
for branch in "${EXPECTED_NO_PR[@]}"; do
  url="$(pr_for_branch "${branch}" || true)"
  if [[ -n "${url}" ]]; then
    check_fail "${branch} — unexpected PR ${url}"
  elif branch_has_fix "${branch}"; then
    check_fail "${branch} — unexpected fix present on branch"
  else
    check_pass "${branch} — no PR and no fix (expected)"
  fi
done

echo ""
if [[ "${satisfied}" -ge 3 ]]; then
  check_pass "All 3 payment branches have PR or fix (${satisfied}/3 satisfied)"
else
  check_fail "Expected 3 satisfied branches, got ${satisfied}"
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -gt 0 ]] && exit 1
exit 0
