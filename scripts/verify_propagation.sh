#!/usr/bin/env bash
#
# verify_propagation.sh — Assert cross-branch patch propagation outcomes.
#
# Usage:
#   ./scripts/verify_propagation.sh [REPO_DIR]
#

set -euo pipefail

REPO_DIR="${1:-.}"
WI_ID="${WI_ID:-WI-440219}"
AFFECTED_FILE="${AFFECTED_FILE:-src/payment/transaction_queue.py}"
FIX_MARKER="${FIX_MARKER:-threading.RLock()  # WI-440219: definitive thread-safe fix}"
ENQUEUE_MARKER="${ENQUEUE_MARKER:-def enqueue(self, txn: dict) -> None:}"
BRANCH_SELECT_MODE="${BRANCH_SELECT_MODE:-wi-history}"

EXPECTED_FIXED=(
  bugfix/payment-patch
  feature/payment-gateway
  feature/ledger-audit
  feature/compliance-reporting
)

EXPECTED_WI_BUT_NO_FIX=(
  release/v1.0
  feature/database-migration
  infra/kubernetes-config
)

EXPECTED_NO_WI=(
  main
  feature/user-auth
  feature/ui-ux
  feature/analytics-pipeline
  feature/notifications
  feature/mobile-api
  feature/admin-dashboard
)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass=0
fail=0

check_pass() {
  echo -e "${GREEN}PASS${NC}  $*"
  pass=$((pass + 1))
}

check_fail() {
  echo -e "${RED}FAIL${NC}  $*" >&2
  fail=$((fail + 1))
}

branch_has_file() {
  git -C "${REPO_DIR}" cat-file -e "$1:${AFFECTED_FILE}" 2>/dev/null
}

branch_content() {
  git -C "${REPO_DIR}" show "$1:${AFFECTED_FILE}" 2>/dev/null
}

branch_has_fix() {
  branch_content "$1" | grep -Fq "${FIX_MARKER}" 2>/dev/null
}

branch_mentions_wi() {
  local count
  count="$(git -C "${REPO_DIR}" rev-list "$1" --grep="${WI_ID}" --count 2>/dev/null || echo 0)"
  [[ "${count}" -gt 0 ]]
}

echo "Propagation Verification"
echo "======================"
echo "Repository: ${REPO_DIR}"
echo "Mode      : ${BRANCH_SELECT_MODE}"
echo ""

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  echo "Error: ${REPO_DIR} is not a Git repository." >&2
  exit 1
fi

echo "--- Branches that MUST have the fix ---"
for branch in "${EXPECTED_FIXED[@]}"; do
  if ! branch_has_file "${branch}"; then
    check_fail "${branch} — expected file '${AFFECTED_FILE}' missing"
    continue
  fi
  content="$(branch_content "${branch}")"
  if echo "${content}" | grep -Fq "${FIX_MARKER}" \
    && echo "${content}" | grep -Fq "${ENQUEUE_MARKER}"; then
    check_pass "${branch} — definitive fix present"
  else
    check_fail "${branch} — fix marker or enqueue method missing"
  fi
done

if [[ "${BRANCH_SELECT_MODE}" == "wi-history" ]]; then
  echo ""
  echo "--- WI branches that should NOT receive the fix (no affected file) ---"
  for branch in "${EXPECTED_WI_BUT_NO_FIX[@]}"; do
    if ! branch_mentions_wi "${branch}"; then
      check_fail "${branch} — expected WI mention in history"
      continue
    fi
    if branch_has_fix "${branch}"; then
      check_fail "${branch} — should not have fix (no ${AFFECTED_FILE})"
    else
      check_pass "${branch} — WI history match, fix correctly not applied"
    fi
  done

  echo ""
  echo "--- Branches with no WI in history (should be untouched) ---"
  for branch in "${EXPECTED_NO_WI[@]}"; do
    if branch_mentions_wi "${branch}"; then
      check_fail "${branch} — unexpected WI mention in history"
    elif branch_has_fix "${branch}"; then
      check_fail "${branch} — should not have received fix"
    else
      check_pass "${branch} — no WI history, correctly skipped"
    fi
  done
else
  echo ""
  echo "--- Branches that must NOT have the affected file ---"
  for branch in "${EXPECTED_WI_BUT_NO_FIX[@]}" "${EXPECTED_NO_WI[@]}"; do
    if branch_has_file "${branch}"; then
      check_fail "${branch} — unexpected file '${AFFECTED_FILE}' present"
    else
      check_pass "${branch} — no affected file (correctly skipped)"
    fi
  done
fi

echo ""
echo "--- WI noise check ---"
definitive_count="$(
  git -C "${REPO_DIR}" log --all --oneline \
    | grep -F "Apply definitive thread-safe fix" \
    | grep -cF "${WI_ID}" || true
)"
if [[ "${definitive_count}" -ge 4 ]]; then
  check_pass "Definitive fix propagated to payment branches (${definitive_count} commits)"
else
  check_fail "Expected ≥4 definitive-fix commits, found ${definitive_count}"
fi

wi_branches=0
for branch in $(git -C "${REPO_DIR}" branch --format='%(refname:short)'); do
  if branch_mentions_wi "${branch}"; then
    wi_branches=$((wi_branches + 1))
  fi
done
if [[ "${wi_branches}" -eq 7 ]]; then
  check_pass "Seven branches mention ${WI_ID} in history (expected WI footprint)"
else
  check_fail "Expected 7 WI branches, found ${wi_branches}"
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed"

if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi

exit 0
