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
SOURCE_BRANCH="${SOURCE_BRANCH:-bugfix/payment-patch}"
BRANCH_SELECT_MODE="${BRANCH_SELECT_MODE:-wi-history}"
PROPAGATION_MODE="${PROPAGATION_MODE:-direct}"
PRS_FILE="${PRS_FILE:-${REPO_DIR}/.propagation-logs/pull-requests.txt}"
SUMMARY_FILE="${SUMMARY_FILE:-${REPO_DIR}/.propagation-logs/propagation-summary.txt}"
RESULTS_FILE="${RESULTS_FILE:-${REPO_DIR}/.propagation-logs/results.tsv}"

# Same block policy as propagate_patch.sh (space- or comma-separated).
BLOCKED_BRANCHES="${BLOCKED_BRANCHES:-infra/kubernetes-config}"
BLOCKED_BRANCHES="${BLOCKED_BRANCHES//,/ }"

# Direct-mode (fixture self-test) expectations. These describe the KNOWN shape
# of the synthetic fixture produced by generate_complex_repo.sh — never real
# GitHub branches. The PR-mode path below derives everything dynamically.
EXPECTED_FIXED=(
  feature/payment-gateway
  feature/ledger-audit
  feature/compliance-reporting
  feature/database-migration
)
# WI branches that end up WITHOUT the definitive fix:
#   release/v1.0            — lacks the affected file (cherry-pick fails)
#   infra/kubernetes-config — qualifies, but blocked via BLOCKED_BRANCHES
#   feature/payment-hotfix  — has the file, but its competing change makes the
#                             cherry-pick conflict, so the fix is not applied
EXPECTED_WI_BUT_NO_FIX=(
  release/v1.0
  infra/kubernetes-config
  feature/payment-hotfix
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

is_propagation_branch() { [[ "$1" == propagate/* ]]; }

is_blocked() {
  local b
  for b in ${BLOCKED_BRANCHES}; do
    [[ "$1" == "${b}" ]] && return 0
  done
  return 1
}

# Discover every real branch (local heads + origin/*), deduplicated. This is
# what makes PR-mode verification reflect the actual GitHub repo with no
# hardcoded branch names.
list_branches() {
  {
    git -C "${REPO_DIR}" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null
    git -C "${REPO_DIR}" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null \
      | sed 's#^origin/##'
  } | grep -vxE 'HEAD|origin' | sort -u
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

# Look up the recorded outcome status for a branch from results.tsv (the genuine
# result of the propagation run, including real cherry-pick CONFLICTs).
recorded_status() {
  [[ -f "${RESULTS_FILE}" ]] || return 0
  awk -F'\t' -v b="$1" '$2==b {print $1; exit}' "${RESULTS_FILE}"
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
# PR mode (LIVE): fully dynamic. Discover the real branches, recompute
# eligibility from git state exactly like propagate_patch.sh, and assert each
# branch's PR outcome. No branch names are hardcoded here.
#
# A branch MUST have a PR (or already carry the fix) when it is selected by the
# branch mode AND can actually receive the fix (affected file present) AND is
# not the source, a propagation branch, or blocked. Every other branch MUST NOT
# have a PR.
# ---------------------------------------------------------------------------
if [[ "${PROPAGATION_MODE}" == "pr" ]]; then
  if [[ ! -f "${PRS_FILE}" && ! -f "${SUMMARY_FILE}" ]]; then
    check_fail "Missing propagation logs — run propagate_patch.sh with PROPAGATION_MODE=pr first"
    exit 1
  fi

  # Classify a branch into: eligible | blocked | source | skip | cannot-apply.
  classify_branch() {
    local b="$1"
    [[ "${b}" == "${SOURCE_BRANCH}" ]] && { echo source; return; }
    is_propagation_branch "${b}" && { echo propagation; return; }
    is_blocked "${b}" && { echo blocked; return; }
    case "${BRANCH_SELECT_MODE}" in
      wi-history)
        branch_mentions_wi "${b}" || { echo skip-no-wi; return; }
        branch_has_file "${b}" && echo eligible || echo cannot-apply ;;
      affected-file)
        branch_has_file "${b}" && echo eligible || echo skip-no-file ;;
      *) echo skip-no-wi ;;
    esac
  }

  eligible=0
  satisfied=0
  conflicted=0

  echo "--- Branches selected for the fix (PR expected, unless it conflicts) ---"
  while IFS= read -r branch; do
    [[ "$(classify_branch "${branch}")" == "eligible" ]] || continue
    eligible=$((eligible + 1))
    url="$(pr_for_branch "${branch}" || true)"
    if [[ -n "${url}" ]]; then
      check_pass "${branch} — PR recorded (${url})"
      satisfied=$((satisfied + 1))
    elif branch_has_fix "${branch}"; then
      check_pass "${branch} — fix already on branch (no new PR needed)"
      satisfied=$((satisfied + 1))
    elif [[ "$(recorded_status "${branch}")" == "CONFLICT" ]]; then
      check_pass "${branch} — fix conflicts; reported for manual resolution (no PR, non-fatal)"
      conflicted=$((conflicted + 1))
    else
      check_fail "${branch} — eligible but no PR recorded and fix not present"
    fi
  done < <(list_branches)

  echo ""
  echo "--- Branches that must NOT have a PR (and why) ---"
  while IFS= read -r branch; do
    case "$(classify_branch "${branch}")" in
      eligible|propagation) continue ;;
      source)        reason="source branch" ;;
      blocked)       reason="blocked by policy" ;;
      cannot-apply)  reason="WI history but missing '${AFFECTED_FILE}'" ;;
      skip-no-wi)    reason="no ${WI_ID} in history" ;;
      skip-no-file)  reason="affected file not present" ;;
      *)             reason="not selected" ;;
    esac
    url="$(pr_for_branch "${branch}" || true)"
    if [[ -n "${url}" ]]; then
      check_fail "${branch} — unexpected PR ${url} (expected none: ${reason})"
    else
      check_pass "${branch} — no PR (${reason})"
    fi
  done < <(list_branches)

  echo ""
  if [[ "${eligible}" -eq 0 ]]; then
    check_fail "No eligible branches found — nothing to propagate"
  elif [[ $((satisfied + conflicted)) -eq "${eligible}" ]]; then
    check_pass "All ${eligible} selected branch(es) accounted for: ${satisfied} with PR/fix, ${conflicted} conflict(s) reported"
  else
    check_fail "Only $((satisfied + conflicted))/${eligible} selected branch(es) accounted for"
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
if [[ "${definitive_count}" -ge 5 ]]; then
  check_pass "Definitive fix propagated to payment branches (${definitive_count} commits)"
else
  check_fail "Expected ≥5 definitive-fix commits, found ${definitive_count}"
fi

wi_branches=0
for branch in $(git -C "${REPO_DIR}" branch --format='%(refname:short)'); do
  branch_mentions_wi "${branch}" && wi_branches=$((wi_branches + 1))
done
if [[ "${wi_branches}" -eq 8 ]]; then
  check_pass "Eight branches mention ${WI_ID} in history (expected WI footprint)"
else
  check_fail "Expected 8 WI branches, found ${wi_branches}"
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -gt 0 ]] && exit 1
exit 0
