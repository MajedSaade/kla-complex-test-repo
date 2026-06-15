#!/usr/bin/env bash
#
# verify_propagation.sh — Assert cross-branch patch propagation outcomes.
#
# Propagation is always via pull request, so verification is fully dynamic: it
# rediscovers the real branches (local heads + origin/*), recomputes eligibility
# from git state exactly like propagate_patch.sh, and asserts each branch's PR
# outcome. No branch names are hardcoded.
#
# A branch MUST have a PR (or already carry the fix) when its NAME sorts
# lexicographically AFTER the fix branch AND it is selected by the branch mode
# AND is not the source, a propagation branch, protected, or blocked. Every
# other branch MUST NOT have a
# PR. A genuine cherry-pick conflict is accepted as a reported, non-fatal
# outcome. Recorded PR_OPENED/PR_EXISTING entries also satisfy a branch, so a
# DRY_RUN propagation (which records intent without pushing) verifies cleanly.
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
SOURCE_BRANCH="${SOURCE_BRANCH:-A14-bugfix/payment-patch}"
BRANCH_SELECT_MODE="${BRANCH_SELECT_MODE:-wi-history}"
PRS_FILE="${PRS_FILE:-${REPO_DIR}/.propagation-logs/pull-requests.txt}"
SUMMARY_FILE="${SUMMARY_FILE:-${REPO_DIR}/.propagation-logs/propagation-summary.txt}"
RESULTS_FILE="${RESULTS_FILE:-${REPO_DIR}/.propagation-logs/results.tsv}"

# Same block policy as propagate_patch.sh (space- or comma-separated). The
# unprefixed "infra/kubernetes-config" is the pre-rename name still present on
# origin as a protected branch; it is blocked too so the stale ref verifies as
# "no PR" (safe to drop once that branch is removed).
BLOCKED_BRANCHES="${BLOCKED_BRANCHES:-G6-infra/kubernetes-config infra/kubernetes-config}"
BLOCKED_BRANCHES="${BLOCKED_BRANCHES//,/ }"
# Protected integration branches that must never receive a PR (matches propagate).
PROTECTED_BRANCHES="${PROTECTED_BRANCHES:-main master}"
PROTECTED_BRANCHES="${PROTECTED_BRANCHES//,/ }"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
pass=0
fail=0

check_pass() { echo -e "${GREEN}PASS${NC}  $*"; pass=$((pass + 1)); }
check_fail() { echo -e "${RED}FAIL${NC}  $*" >&2; fail=$((fail + 1)); }

# Resolve a branch to a usable ref, preferring origin/* (the live repo state)
# and falling back to a local head (e.g. a freshly generated fixture).
branch_ref() {
  local branch="$1"
  if git -C "${REPO_DIR}" show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
    echo "origin/${branch}"
  elif git -C "${REPO_DIR}" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
    echo "${branch}"
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

is_protected() {
  local b
  for b in ${PROTECTED_BRANCHES}; do
    [[ "$1" == "${b}" ]] && return 0
  done
  return 1
}

# Discover every real branch (local heads + origin/*), deduplicated. This is
# what makes verification reflect the actual repo with no hardcoded names.
list_branches() {
  {
    git -C "${REPO_DIR}" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null
    git -C "${REPO_DIR}" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null \
      | sed 's#^origin/##'
  } | grep -vxE 'HEAD|origin' | sort -u
}

# --- "Name sorts after the fix branch" detection (mirrors propagate_patch.sh) -
# Eligibility is decided by branch NAME, not commit dates: a branch qualifies
# only when its name sorts strictly AFTER the source branch name. Comparison is
# byte-wise (LC_ALL=C) so the numeric prefixes branches carry (e.g.
# 20-bugfix/payment-patch) give a stable, locale-independent ordering.
name_after_source() {
  [[ "$1" == "${SOURCE_BRANCH}" ]] && return 1
  ( LC_ALL=C; [[ "$1" > "${SOURCE_BRANCH}" ]] )
}

# Find a recorded PR url for a branch, either from the machine-readable list or
# the human-readable summary written by propagate_patch.sh.
pr_for_branch() {
  local branch="$1" url=""
  if [[ -f "${PRS_FILE}" ]]; then
    url="$(grep -F "${branch}|" "${PRS_FILE}" 2>/dev/null | head -1 | cut -d'|' -f2- || true)"
  fi
  if [[ -z "${url}" && -f "${SUMMARY_FILE}" ]]; then
    url="$(grep -E "^PR[[:space:]]+${branch//\//\\/}[[:space:]]" "${SUMMARY_FILE}" 2>/dev/null \
      | head -1 | grep -oE 'https://github.com/[^[:space:]]+' | head -1 || true)"
  fi
  [[ -n "${url}" ]] && echo "${url}"
}

# Look up the recorded outcome status for a branch from results.tsv (the genuine
# result of the propagation run, including real cherry-pick CONFLICTs and the
# PR_OPENED intent recorded by a DRY_RUN run).
recorded_status() {
  [[ -f "${RESULTS_FILE}" ]] || return 0
  awk -F'\t' -v b="$1" '$2==b {print $1; exit}' "${RESULTS_FILE}"
}

echo "Propagation Verification"
echo "========================"
echo "Repository : ${REPO_DIR}"
echo "Selection  : ${BRANCH_SELECT_MODE} + name lexicographically after ${SOURCE_BRANCH}"
echo ""

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  echo "Error: ${REPO_DIR} is not a Git repository." >&2
  exit 1
fi

if [[ ! -f "${PRS_FILE}" && ! -f "${SUMMARY_FILE}" && ! -f "${RESULTS_FILE}" ]]; then
  check_fail "Missing propagation logs — run propagate_patch.sh first"
  exit 1
fi

# Classify a branch: eligible | source | propagation | protected | blocked |
# skip-before | skip-no-wi | skip-no-file.
classify_branch() {
  local b="$1"
  [[ "${b}" == "${SOURCE_BRANCH}" ]] && { echo source; return; }
  is_propagation_branch "${b}" && { echo propagation; return; }
  is_protected "${b}" && { echo protected; return; }
  is_blocked "${b}" && { echo blocked; return; }
  name_after_source "${b}" || { echo skip-before; return; }
  case "${BRANCH_SELECT_MODE}" in
    wi-history)
      branch_mentions_wi "${b}" && echo eligible || echo skip-no-wi ;;
    affected-file)
      branch_has_file "${b}" && echo eligible || echo skip-no-file ;;
    *) echo skip-no-wi ;;
  esac
}

# A branch is "accounted for" when it has a recorded/real PR, already carries
# the fix, or is a reported conflict.
branch_satisfied() {
  local branch="$1" status
  [[ -n "$(pr_for_branch "${branch}" || true)" ]] && return 0
  branch_has_fix "${branch}" && return 0
  status="$(recorded_status "${branch}")"
  [[ "${status}" == "PR_OPENED" || "${status}" == "PR_EXISTING" ]]
}

eligible=0
satisfied=0
conflicted=0

echo "--- Branches selected for the fix (PR expected, unless it conflicts) ---"
while IFS= read -r branch; do
  [[ "$(classify_branch "${branch}")" == "eligible" ]] || continue
  eligible=$((eligible + 1))
  url="$(pr_for_branch "${branch}" || true)"
  if branch_satisfied "${branch}"; then
    if [[ -n "${url}" ]]; then
      check_pass "${branch} — PR recorded (${url})"
    elif branch_has_fix "${branch}"; then
      check_pass "${branch} — fix already on branch (no new PR needed)"
    else
      check_pass "${branch} — PR recorded (intent logged)"
    fi
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
    protected)     reason="protected integration branch" ;;
    blocked)       reason="blocked by policy" ;;
    skip-before)   reason="name sorts on/before the fix branch" ;;
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
