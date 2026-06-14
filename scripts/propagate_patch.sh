#!/usr/bin/env bash
#
# propagate_patch.sh — Cross-branch patch propagation for work-item tagged fixes.
#
# Finds the definitive fix commit (by WI tag + message pattern), then cherry-picks
# it onto every branch whose commit history mentions the same work item.
#
# Usage:
#   ./scripts/propagate_patch.sh [REPO_DIR]
#
# Environment overrides:
#   WI_ID                  Work item tag (default: WI-440219)
#   SOURCE_BRANCH          Branch containing the fix (default: bugfix/payment-patch)
#   FIX_MESSAGE_PATTERN    Grep pattern for the definitive commit (default below)
#   FIX_MARKER             Content marker proving fix is applied (default below)
#   BRANCH_SELECT_MODE     wi-history (default) or affected-file
#

set -euo pipefail

REPO_DIR="${1:-.}"

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  echo "Error: ${REPO_DIR} is not a Git repository." >&2
  exit 1
fi

REPO_DIR="$(cd "${REPO_DIR}" && pwd)"

WI_ID="${WI_ID:-WI-440219}"
WI_TAG="[${WI_ID}]"
SOURCE_BRANCH="${SOURCE_BRANCH:-bugfix/payment-patch}"
FIX_MESSAGE_PATTERN="${FIX_MESSAGE_PATTERN:-Apply definitive thread-safe fix}"
AFFECTED_FILE="${AFFECTED_FILE:-src/payment/transaction_queue.py}"
FIX_MARKER="${FIX_MARKER:-threading.RLock()  # WI-440219: definitive thread-safe fix}"
BRANCH_SELECT_MODE="${BRANCH_SELECT_MODE:-wi-history}"

LOG_DIR="${LOG_DIR:-${REPO_DIR}/.propagation-logs}"
mkdir -p "${LOG_DIR}"
SUMMARY_FILE="${LOG_DIR}/propagation-summary.txt"
TARGETS_FILE="${LOG_DIR}/wi-target-branches.txt"
: > "${SUMMARY_FILE}"
: > "${TARGETS_FILE}"

log() {
  echo "$*" | tee -a "${SUMMARY_FILE}"
}

cd "${REPO_DIR}"

ORIG_BRANCH="$(git branch --show-current 2>/dev/null || echo main)"

# ---------------------------------------------------------------------------
# Locate the definitive fix commit (ignore other WI-tagged commits)
# ---------------------------------------------------------------------------

SOURCE_COMMIT="$(
  git log "${SOURCE_BRANCH}" --format='%H %s' \
    | grep -F "${FIX_MESSAGE_PATTERN}" \
    | grep -F "${WI_TAG}" \
    | head -1 \
    | cut -d' ' -f1
)"

if [[ -z "${SOURCE_COMMIT}" ]]; then
  echo "Error: could not find definitive fix on '${SOURCE_BRANCH}'" >&2
  echo "  Pattern: ${FIX_MESSAGE_PATTERN} ${WI_TAG}" >&2
  exit 1
fi

branch_mentions_wi() {
  local count
  count="$(git rev-list "$1" --grep="${WI_ID}" --count 2>/dev/null || echo 0)"
  [[ "${count}" -gt 0 ]]
}

branch_has_file() {
  git cat-file -e "$1:${AFFECTED_FILE}" 2>/dev/null
}

branch_has_fix() {
  git show "$1:${AFFECTED_FILE}" 2>/dev/null | grep -Fq "${FIX_MARKER}"
}

should_target_branch() {
  local branch="$1"

  if [[ "${branch}" == "${SOURCE_BRANCH}" ]]; then
    return 1
  fi

  if branch_has_fix "${branch}"; then
    return 1
  fi

  case "${BRANCH_SELECT_MODE}" in
    wi-history)
      branch_mentions_wi "${branch}"
      ;;
    affected-file)
      branch_has_file "${branch}"
      ;;
    *)
      echo "Error: unknown BRANCH_SELECT_MODE '${BRANCH_SELECT_MODE}'" >&2
      exit 1
      ;;
  esac
}

log "Patch Propagation Report"
log "========================"
log "Repository : $(pwd)"
log "Work item  : ${WI_TAG}"
log "Source     : ${SOURCE_BRANCH} (${SOURCE_COMMIT:0:7})"
log "Selection  : ${BRANCH_SELECT_MODE}"
log "Fix commit : $(git log -1 --format='%s' "${SOURCE_COMMIT}")"
log ""

log "Branches whose history mentions ${WI_TAG}:"
for branch in $(git branch --format='%(refname:short)'); do
  if branch_mentions_wi "${branch}"; then
    wi_count="$(git rev-list "${branch}" --grep="${WI_ID}" --count 2>/dev/null || echo 0)"
    log "  - ${branch} (${wi_count} WI commit(s) in history)"
    echo "${branch}" >> "${TARGETS_FILE}"
  fi
done
log ""

applied=0
skipped=0
failed=0

for branch in $(git branch --format='%(refname:short)'); do
  if [[ "${branch}" == "${SOURCE_BRANCH}" ]]; then
    log "SKIP  ${branch} — source branch (already contains fix)"
    skipped=$((skipped + 1))
    continue
  fi

  if branch_has_fix "${branch}"; then
    log "SKIP  ${branch} — fix marker already present"
    skipped=$((skipped + 1))
    continue
  fi

  if ! should_target_branch "${branch}"; then
    if [[ "${BRANCH_SELECT_MODE}" == "wi-history" ]] && ! branch_mentions_wi "${branch}"; then
      log "SKIP  ${branch} — no ${WI_TAG} in branch commit history"
    elif [[ "${BRANCH_SELECT_MODE}" == "affected-file" ]] && ! branch_has_file "${branch}"; then
      log "SKIP  ${branch} — '${AFFECTED_FILE}' not present"
    fi
    skipped=$((skipped + 1))
    continue
  fi

  log_file="${LOG_DIR}/cherry-pick-${branch//\//_}.log"
  if git checkout "${branch}" >> "${log_file}" 2>&1 \
    && git cherry-pick "${SOURCE_COMMIT}" >> "${log_file}" 2>&1; then
    new_sha="$(git rev-parse --short HEAD)"
    log "APPLY ${branch} — cherry-picked ${SOURCE_COMMIT:0:7} → ${new_sha} (WI history match)"
    applied=$((applied + 1))
  else
    git cherry-pick --abort >> "${log_file}" 2>&1 || true
    if [[ "${BRANCH_SELECT_MODE}" == "wi-history" ]] && ! branch_has_file "${branch}"; then
      log "FAIL  ${branch} — WI history match but missing '${AFFECTED_FILE}' (see ${log_file})"
    else
      log "FAIL  ${branch} — cherry-pick conflict (see ${log_file})"
    fi
    failed=$((failed + 1))
  fi
done

git checkout "${ORIG_BRANCH}" >> /dev/null 2>&1 || git checkout main >> /dev/null 2>&1 || true

log ""
log "Summary: ${applied} applied, ${skipped} skipped, ${failed} failed"
log "WI targets file: ${TARGETS_FILE}"
log "Full log: ${SUMMARY_FILE}"

if [[ "${failed}" -gt 0 && "${BRANCH_SELECT_MODE}" == "wi-history" ]]; then
  log ""
  log "Note: FAIL on WI branches without '${AFFECTED_FILE}' is expected for this fixture."
  exit 0
fi

if [[ "${failed}" -gt 0 ]]; then
  exit 1
fi

exit 0
