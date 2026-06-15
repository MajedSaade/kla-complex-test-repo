#!/usr/bin/env bash
#
# verify_propagation.sh — Assert cross-branch patch propagation outcomes.
#
# Two verification modes (selected by PROPAGATION_MODE, matching propagate_patch.sh):
#
#   PROPAGATION_MODE=direct  (default) — the fix was cherry-picked onto the
#       eligible branches in this repo; assert it is present where expected
#       and absent everywhere else.
#
#   PROPAGATION_MODE=pr      — the fix was proposed via pull requests; assert a
#       PR was opened (or the fix is already merged) for each eligible branch
#       and that no PR/fix landed on the branches that should be skipped.
#
# Usage:
#   ./scripts/verify_propagation.sh [REPO_DIR]
#

set -euo pipefail

REPO_DIR="${1:-.}"
REPO_DIR="$(cd "${REPO_DIR}" && pwd)"

WI_ID="${WI_ID:-WI-440219}"
AFFECTED_FILE="${AFFECTED_FILE:-src/payment/transaction_queue.py}"
FIX_MARKER="${FIX_MARKER:-threading.RLock()  # WI-440219: definitive thread-safe fix}"
ENQUEUE_MARKER="${ENQUEUE_MARKER:-def enqueue(self, txn: dict) -> None:}"
BRANCH_SELECT_MODE="${BRANCH_SELECT_MODE:-wi-history}"
PROPAGATION_MODE="${PROPAGATION_MODE:-direct}"
PRS_FILE="${PRS_FILE:-${REPO_DIR}/.propagation-logs/pull-requests.txt}"
SUMMARY_FILE="${SUMMARY_FILE:-${REPO_DIR}/.propagation-logs/propagation-summary.txt}"

# Branches that must end up with the fix (cherry-pick succeeds / PR opens).
EXPECTED_FIXED=(
  feature/payment-gateway
  feature/ledger-audit
  feature/compliance-reporting
)

# WI-history branches that must NOT get the fix (they lack the affected file).
EXPECTED_WI_BUT_NO_FIX=(
  release/v1.0
  feature/database-migration
  infra/kubernetes-config
)

# Branches with no WI history at all (must be untouched). Only checked in
# direct mode, where every local branch is inspectable.
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

check_pass() { echo -e "${GREEN}PASS${NC}  $*"; pass=$((pass + 1)); }
check_fail() { echo -e "${RED}FAIL${NC}  $*" >&2; fail=$((fail + 1)); }

# Resolve a branch to a usable ref. PR mode prefers origin/* (the live repo
# state); direct mode prefers the local branch the cherry-pick wrote to.
branch_ref() {
  local branch="$1"
  if [[ "${PROPAGATION_MODE}" == "pr" ]] \
    && git -C "${REPO_DIR}" show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
    echo "origin/${branch}"
  elif git -C "${REPO_DIR}" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
    echo "${branch}"
  elif git -C "${REPO_DIR}" show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
    echo "origin/${branch}"
  else
    echo "${branch}"
  fi
}

branch_content() { git -C "${REPO_DIR}" show "$(branch_ref "$1"):${AFFECTED_FILE}" 2>/dev/null; }
branch_has_file() { git -C "${REPO_DIR}" cat-file -e "$(branch_ref "$1"):${AFFECTED_FILE}" 2>/dev/null; }
branch_has_fix() { branch_content "$1" | grep -Fq "${FIX_MARKER}"; }

branch_mentions_wi() {
  local count
  count="$(git -C "${REPO_DIR}" rev-list "$(branch_ref "$1")" --grep="${WI_ID}" --count 2>/dev/null || echo 0)"
  [[ "${count}" -gt 0 ]]
}

# Find a recorded PR url for a branch, either from the machine-readable list or
# the human-readable summary written by propagate_patch.sh.
pr_for_branch() {
  local branch="$1" url=""
  if [[ -f "${PRS_FILE}" ]]; then
    url="$(grep -F "${branch}|" "${PRS_FILE}" 2>/dev/null | head -1 | cut -d'|' -f2-)"
  fi
  if [[ -z "${url}" && -f "${SUMMARY_FILE}" ]]; then
    url="$(grep -E "^PR[[:space:]]+${branch//\//\\/}[[:space:]]" "${SUMMARY_FILE}" 2>/dev/null \
      | head -1 | grep -oE 'https://github.com/[^[:space:]]+' | head -1)"
  fi
  [[ -n "${url}" ]] && echo "${url}"
}

echo "Propagation Verification"
echo "========================"
echo "Repository : ${REPO_DIR}"
echo "Mode       : ${PROPAGATION_MODE} (${BRANCH_SELECT_MODE})"
echo ""

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  echo "Error: ${REPO_DIR} is not a Git repository." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# PR mode: assert PRs were opened (or fix already merged) for eligible branches.
# ---------------------------------------------------------------------------
if [[ "${PROPAGATION_MODE}" == "pr" ]]; then
  if [[ ! -f "${PRS_FILE}" && ! -f "${SUMMARY_FILE}" ]]; then
    check_fail "Missing propagation logs — run propagate_patch.sh with PROPAGATION_MODE=pr first"
    exit 1
  fi

  satisfied=0
  echo "--- Branches that MUST have a PR or the fix already ---"
  for branch in "${EXPECTED_FIXED[@]}"; do
    url="$(pr_for_branch "${branch}" || true)"
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
  for branch in "${EXPECTED_WI_BUT_NO_FIX[@]}"; do
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
    check_pass "All 3 payment branches have a PR or the fix (${satisfied}/3 satisfied)"
  else
    check_fail "Expected 3 satisfied branches, got ${satisfied}"
  fi

  echo ""
  echo "Results: ${pass} passed, ${fail} failed"
  [[ "${fail}" -gt 0 ]] && exit 1
  exit 0
fi

# ---------------------------------------------------------------------------
# Direct mode: assert the fix is present/absent on the right branches.
# ---------------------------------------------------------------------------
EXPECTED_FIXED=(bugfix/payment-patch "${EXPECTED_FIXED[@]}")

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
    elif branch_has_fix "${branch}"; then
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
  branch_mentions_wi "${branch}" && wi_branches=$((wi_branches + 1))
done
if [[ "${wi_branches}" -eq 7 ]]; then
  check_pass "Seven branches mention ${WI_ID} in history (expected WI footprint)"
else
  check_fail "Expected 7 WI branches, found ${wi_branches}"
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -gt 0 ]] && exit 1
exit 0
