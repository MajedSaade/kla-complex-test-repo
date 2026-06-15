#!/usr/bin/env bash
#
# propagate_patch.sh — Cross-branch patch propagation for work-item tagged fixes.
#
# Finds the definitive fix commit and applies it to matching branches via:
#   PROPAGATION_MODE=direct  — cherry-pick directly onto the branch (default)
#   PROPAGATION_MODE=pr      — cherry-pick onto a propagation branch and open a PR
#
# Usage:
#   ./scripts/propagate_patch.sh [REPO_DIR]
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
PROPAGATION_MODE="${PROPAGATION_MODE:-direct}"
DRY_RUN="${DRY_RUN:-false}"

# Branches to skip even when they qualify (space- or comma-separated).
BLOCKED_BRANCHES="${BLOCKED_BRANCHES:-infra/kubernetes-config}"
BLOCKED_BRANCHES="${BLOCKED_BRANCHES//,/ }"
# Minimum PRs required for PR mode to succeed (eligible branches minus blocked).
MIN_PRS="${MIN_PRS:-4}"

LOG_DIR="${LOG_DIR:-${REPO_DIR}/.propagation-logs}"
mkdir -p "${LOG_DIR}"
SUMMARY_FILE="${LOG_DIR}/propagation-summary.txt"
TARGETS_FILE="${LOG_DIR}/wi-target-branches.txt"
PRS_FILE="${LOG_DIR}/pull-requests.txt"
RESULTS_FILE="${LOG_DIR}/results.tsv"
: > "${SUMMARY_FILE}"
: > "${TARGETS_FILE}"
: > "${PRS_FILE}"
: > "${RESULTS_FILE}"

log() {
  echo "$*" | tee -a "${SUMMARY_FILE}"
}

# Machine-readable per-branch outcome: <status> <branch> <reason> <url>.
# Statuses: PR_OPENED, PR_EXISTING, APPLIED, SKIPPED, FAILED.
# Consumed by verify_propagation.sh and notify_propagation.sh.
record() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "${4:-}" >> "${RESULTS_FILE}"
}

cd "${REPO_DIR}"

ORIG_BRANCH="$(git branch --show-current 2>/dev/null || echo main)"

# Fetch all remote branches (CI often only checks out main locally)
if git remote get-url origin >/dev/null 2>&1; then
  git fetch origin --prune >> "${LOG_DIR}/fetch.log" 2>&1 || true
fi

# Resolve a branch name to a local or origin/* ref
branch_ref() {
  local branch="$1"
  if git show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
    echo "${branch}"
  elif git show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
    echo "origin/${branch}"
  else
    echo "${branch}"
  fi
}

# In PR mode, prefer origin/* so stale local branches do not hide missing fixes.
branch_check_ref() {
  local branch="$1"
  if [[ "${PROPAGATION_MODE:-direct}" == "pr" ]] \
    && git show-ref --verify --quiet "refs/remotes/origin/${branch}" 2>/dev/null; then
    echo "origin/${branch}"
  else
    branch_ref "${branch}"
  fi
}

# List all local + remote branches (deduplicated)
list_branches() {
  local -A seen=()
  local b ref

  while IFS= read -r b; do
    [[ -n "${b}" ]] || continue
    seen["${b}"]=1
    echo "${b}"
  done < <(git branch --format='%(refname:short)' 2>/dev/null)

  while IFS= read -r ref; do
    b="${ref#origin/}"
    [[ "${b}" == "HEAD" || "${b}" == "origin" || -z "${b}" ]] && continue
    [[ -n "${seen[$b]:-}" ]] && continue
    echo "${b}"
  done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null)
}

is_propagation_branch() {
  [[ "$1" == propagate/* ]]
}

is_blocked() {
  local b
  for b in ${BLOCKED_BRANCHES}; do
    [[ "$1" == "${b}" ]] && return 0
  done
  return 1
}

github_repo_slug() {
  local slug=""
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    slug="${GITHUB_REPOSITORY}"
  else
    local url
    url="$(git remote get-url origin 2>/dev/null || true)"
    if [[ "${url}" =~ github\.com[:/]([^/]+/[^/]+?)(\.git)?/?$ ]]; then
      slug="${BASH_REMATCH[1]}"
    fi
  fi
  slug="${slug%.git}"
  echo "${slug}"
}

branch_to_prop_slug() {
  echo "${1//\//-}"
}

propagation_branch_name() {
  local target="$1"
  echo "propagate/${WI_ID}/$(branch_to_prop_slug "${target}")"
}

pr_title() {
  local target="$1"
  echo "Propagate ${WI_TAG} fix to ${target}"
}

pr_body() {
  local target="$1"
  cat <<EOF
## Work item
${WI_TAG}

## Summary
Automated propagation of the definitive fix commit to \`${target}\`.

**Source branch:** \`${SOURCE_BRANCH}\`
**Fix commit:** \`${SOURCE_COMMIT:0:7}\`
**Original message:** $(git log -1 --format='%s' "${SOURCE_COMMIT}")

## Selection
Branch matched because its commit history mentions ${WI_TAG}.

Please review and merge to apply the fix.
EOF
}

open_pull_request() {
  local base_branch="$1"
  local head_branch="$2"
  local title="$3"
  local body="$4"
  local repo="${5:-}"
  local owner="${repo%%/*}"
  local head_ref="${head_branch}"
  local url body_file existing

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY   ${base_branch} — would open PR ${head_branch} → ${base_branch}"
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    existing="$(gh pr list --repo "${repo}" --base "${base_branch}" \
      --head "${owner}:${head_branch}" --state open --json url --jq '.[0].url' 2>/dev/null || true)"
    if [[ -z "${existing}" || "${existing}" == "null" ]]; then
      existing="$(gh pr list --repo "${repo}" --base "${base_branch}" \
        --head "${head_branch}" --state open --json url --jq '.[0].url' 2>/dev/null || true)"
    fi
    if [[ -n "${existing}" && "${existing}" != "null" ]]; then
      log "PR    ${base_branch} — existing open PR ${existing}"
      echo "${base_branch}|${existing}" >> "${PRS_FILE}"
      return 0
    fi
    body_file="$(mktemp)"
    printf '%s' "${body}" > "${body_file}"
    if ! url="$(gh pr create --repo "${repo}" --base "${base_branch}" --head "${head_ref}" \
      --title "${title}" --body-file "${body_file}" 2>&1)"; then
      rm -f "${body_file}"
      echo "gh pr create failed: ${url}" >&2
      return 1
    fi
    rm -f "${body_file}"
    log "PR    ${base_branch} — opened ${url}"
    echo "${base_branch}|${url}" >> "${PRS_FILE}"
    return 0
  fi

  if [[ -n "${GITHUB_TOKEN:-}" && -n "${repo}" ]]; then
    existing="$(curl -sf \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${repo}/pulls?state=open&head=${owner}:${head_branch}&base=${base_branch}" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['html_url'] if d else '')" 2>/dev/null || true)"
    if [[ -n "${existing}" ]]; then
      log "PR    ${base_branch} — existing open PR ${existing}"
      echo "${base_branch}|${existing}" >> "${PRS_FILE}"
      return 0
    fi
    return 1
  fi

  echo "Error: PR mode requires 'gh' CLI or GITHUB_TOKEN with repo access." >&2
  return 1
}

# Log why a cherry-pick failed: a WI branch missing the affected file (expected,
# cannot apply) vs a genuine merge conflict. ${2} is an optional message suffix.
log_apply_failure() {
  local branch="$1" log_file="$2" conflict_note="${3:-}"
  if [[ "${BRANCH_SELECT_MODE}" == "wi-history" ]] && ! branch_has_file "${branch}"; then
    log "FAIL  ${branch} — WI history match but missing '${AFFECTED_FILE}' (see ${log_file})"
  else
    log "FAIL  ${branch} — cherry-pick conflict${conflict_note} (see ${log_file})"
  fi
}

apply_direct() {
  local branch="$1"
  local ref log_file
  ref="$(branch_ref "${branch}")"
  log_file="${LOG_DIR}/cherry-pick-${branch//\//_}.log"

  if git checkout -B "${branch}" "${ref}" >> "${log_file}" 2>&1 \
    && git cherry-pick "${SOURCE_COMMIT}" >> "${log_file}" 2>&1; then
    local new_sha
    new_sha="$(git rev-parse --short HEAD)"
    log "APPLY ${branch} — cherry-picked ${SOURCE_COMMIT:0:7} → ${new_sha}"
    return 0
  fi

  git cherry-pick --abort >> "${log_file}" 2>&1 || true
  log_apply_failure "${branch}" "${log_file}"
  return 1
}

apply_via_pr() {
  local branch="$1"
  local repo="$2"
  local prop_branch
  local log_file
  local worktree_dir
  local base_ref
  prop_branch="$(propagation_branch_name "${branch}")"
  log_file="${LOG_DIR}/pr-${branch//\//_}.log"
  worktree_dir="${LOG_DIR}/worktrees/${branch//\//_}"
  base_ref="$(branch_check_ref "${branch}")"

  mkdir -p "${LOG_DIR}/worktrees"
  rm -rf "${worktree_dir}"
  git worktree prune >> "${log_file}" 2>&1 || true

  git fetch origin "${branch}" >> "${log_file}" 2>&1 || git fetch origin >> "${log_file}" 2>&1 || true

  if ! git worktree add -B "${prop_branch}" "${worktree_dir}" "${base_ref}" >> "${log_file}" 2>&1; then
    log "FAIL  ${branch} — unable to create worktree from ${base_ref} (see ${log_file})"
    rm -rf "${worktree_dir}"
    return 1
  fi

  if ! git -C "${worktree_dir}" cherry-pick "${SOURCE_COMMIT}" >> "${log_file}" 2>&1; then
    git -C "${worktree_dir}" cherry-pick --abort >> "${log_file}" 2>&1 || true
    git worktree remove "${worktree_dir}" --force >> "${log_file}" 2>&1 || rm -rf "${worktree_dir}"
    log_apply_failure "${branch}" "${log_file}" ", no PR created"
    return 1
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY   ${branch} — would push ${prop_branch} and open PR"
    git worktree remove "${worktree_dir}" --force >> "${log_file}" 2>&1 || rm -rf "${worktree_dir}"
    return 0
  fi

  if ! git -C "${worktree_dir}" push -u origin "${prop_branch}" >> "${log_file}" 2>&1; then
    if ! git -C "${worktree_dir}" push -f origin "${prop_branch}" >> "${log_file}" 2>&1; then
      log "FAIL  ${branch} — unable to push ${prop_branch} (see ${log_file})"
      git worktree remove "${worktree_dir}" --force >> "${log_file}" 2>&1 || rm -rf "${worktree_dir}"
      return 1
    fi
  fi

  if ! open_pull_request "${branch}" "${prop_branch}" "$(pr_title "${branch}")" "$(pr_body "${branch}")" "${repo}" >> "${log_file}" 2>&1; then
    log "FAIL  ${branch} — unable to open pull request (see ${log_file})"
    git worktree remove "${worktree_dir}" --force >> "${log_file}" 2>&1 || rm -rf "${worktree_dir}"
    return 1
  fi

  git worktree remove "${worktree_dir}" --force >> "${log_file}" 2>&1 || rm -rf "${worktree_dir}"
  return 0
}

# ---------------------------------------------------------------------------
# Locate the definitive fix commit: the newest commit on the source branch
# whose message mentions the work item, verified to carry the fix marker in
# the affected file (not merely the branch tip or any arbitrary substring).
# ---------------------------------------------------------------------------

SOURCE_REF="$(branch_ref "${SOURCE_BRANCH}")"

SOURCE_COMMIT="$(
  git log "${SOURCE_REF}" --grep="${WI_ID}" --format='%H' -1 2>/dev/null || true
)"

if [[ -z "${SOURCE_COMMIT}" ]]; then
  echo "Error: no commit mentioning '${WI_TAG}' on '${SOURCE_BRANCH}' (ref: ${SOURCE_REF})" >&2
  exit 1
fi

if ! git show "${SOURCE_COMMIT}:${AFFECTED_FILE}" 2>/dev/null | grep -Fq "${FIX_MARKER}"; then
  echo "Error: newest '${WI_TAG}' commit on '${SOURCE_BRANCH}' (${SOURCE_COMMIT:0:7}) does not contain the definitive fix in '${AFFECTED_FILE}'" >&2
  echo "       Message: $(git log -1 --format='%s' "${SOURCE_COMMIT}")" >&2
  exit 1
fi

source_msg="$(git log -1 --format='%s' "${SOURCE_COMMIT}")"

branch_mentions_wi() {
  local ref count
  ref="$(branch_ref "$1")"
  count="$(git rev-list "${ref}" --grep="${WI_ID}" --count 2>/dev/null || echo 0)"
  [[ "${count}" -gt 0 ]]
}

branch_has_file() {
  git cat-file -e "$(branch_check_ref "$1"):${AFFECTED_FILE}" 2>/dev/null
}

branch_has_fix() {
  git show "$(branch_check_ref "$1"):${AFFECTED_FILE}" 2>/dev/null | grep -Fq "${FIX_MARKER}"
}

should_target_branch() {
  local branch="$1"

  [[ "${branch}" == "${SOURCE_BRANCH}" ]] && return 1
  is_propagation_branch "${branch}" && return 1
  is_blocked "${branch}" && return 1
  branch_has_fix "${branch}" && return 1

  case "${BRANCH_SELECT_MODE}" in
    wi-history) branch_mentions_wi "${branch}" ;;
    affected-file) branch_has_file "${branch}" ;;
    *) echo "Error: unknown BRANCH_SELECT_MODE '${BRANCH_SELECT_MODE}'" >&2; exit 1 ;;
  esac
}

is_expected_wi_failure() {
  local branch="$1"
  [[ "${BRANCH_SELECT_MODE}" == "wi-history" ]] \
    && branch_mentions_wi "${branch}" \
    && ! branch_has_file "${branch}"
}

GITHUB_REPO="$(github_repo_slug || true)"

log "Patch Propagation Report"
log "========================"
log "Repository : $(pwd)"
log "Work item  : ${WI_TAG}"
log "Source     : ${SOURCE_BRANCH} (${SOURCE_REF} → ${SOURCE_COMMIT:0:7})"
log "Selection  : ${BRANCH_SELECT_MODE}"
log "Mode       : ${PROPAGATION_MODE}"
log "Fix commit : ${source_msg}"
[[ "${source_msg}" != *"${FIX_MESSAGE_PATTERN}"* ]] \
  && log "Note       : message does not contain '${FIX_MESSAGE_PATTERN}' (selected by ${WI_TAG} + fix marker)"
[[ -n "${GITHUB_REPO}" ]] && log "GitHub     : ${GITHUB_REPO}"
log ""

if [[ "${PROPAGATION_MODE}" == "pr" && -z "${GITHUB_REPO}" ]]; then
  echo "Error: PR mode requires a GitHub origin remote or GITHUB_REPOSITORY." >&2
  exit 1
fi

if [[ "${PROPAGATION_MODE}" == "pr" ]]; then
  git config user.name "${GIT_USER_NAME:-github-actions[bot]}"
  git config user.email "${GIT_USER_EMAIL:-github-actions[bot]@users.noreply.github.com}"
fi

log "Branches whose history mentions ${WI_TAG}:"
while IFS= read -r branch; do
  is_propagation_branch "${branch}" && continue
  if branch_mentions_wi "${branch}"; then
    wi_count="$(git rev-list "$(branch_ref "${branch}")" --grep="${WI_ID}" --count 2>/dev/null || echo 0)"
    log "  - ${branch} (${wi_count} WI commit(s) in history)"
    echo "${branch}" >> "${TARGETS_FILE}"
  fi
done < <(list_branches)
log ""

applied=0
prs=0
skipped=0
failed=0
expected_failed=0
unexpected_failed=0
conflicts=0

# Classify a failed cherry-pick and record it. A branch that HAS the affected
# file but fails is a genuine merge CONFLICT (non-fatal — needs manual
# resolution). A WI branch missing the file is an expected failure. Anything
# else is an unexpected failure (fatal).
classify_failure() {
  local branch="$1"
  if is_expected_wi_failure "${branch}"; then
    failed=$((failed + 1))
    expected_failed=$((expected_failed + 1))
    record FAILED "${branch}" "WI history match but missing '${AFFECTED_FILE}' (cannot apply fix)"
  elif branch_has_file "${branch}"; then
    conflicts=$((conflicts + 1))
    log "CONFLICT ${branch} — fix does not apply cleanly; manual resolution needed"
    record CONFLICT "${branch}" "cherry-pick conflict; manual resolution needed"
  else
    failed=$((failed + 1))
    unexpected_failed=$((unexpected_failed + 1))
    record FAILED "${branch}" "unexpected failure (cherry-pick/push/PR)"
  fi
}

while IFS= read -r branch; do
  is_propagation_branch "${branch}" && continue

  if [[ "${branch}" == "${SOURCE_BRANCH}" ]]; then
    log "SKIP  ${branch} — source branch (already contains fix)"
    record SKIPPED "${branch}" "source branch (already contains fix)"
    skipped=$((skipped + 1))
    continue
  fi

  if is_blocked "${branch}"; then
    log "SKIP  ${branch} — blocked by policy (BLOCKED_BRANCHES)"
    record SKIPPED "${branch}" "blocked by policy (BLOCKED_BRANCHES)"
    skipped=$((skipped + 1))
    continue
  fi

  if branch_has_fix "${branch}"; then
    existing_pr=""
    if [[ "${PROPAGATION_MODE}" == "pr" ]] && command -v gh >/dev/null 2>&1 && [[ -n "${GITHUB_REPO:-}" ]]; then
      existing_pr="$(gh pr list --repo "${GITHUB_REPO}" --base "${branch}" --state open \
        --search "Propagate [${WI_ID}] in:title" --json url --jq '.[0].url' 2>/dev/null || true)"
    fi
    if [[ -n "${existing_pr}" && "${existing_pr}" != "null" ]]; then
      log "SKIP  ${branch} — fix on branch; existing PR ${existing_pr}"
      echo "${branch}|${existing_pr}" >> "${PRS_FILE}"
      record PR_EXISTING "${branch}" "fix already on branch; existing PR" "${existing_pr}"
    else
      log "SKIP  ${branch} — fix marker already present"
      record SKIPPED "${branch}" "fix marker already present on branch"
    fi
    skipped=$((skipped + 1))
    continue
  fi

  if ! should_target_branch "${branch}"; then
    reason="not selected by ${BRANCH_SELECT_MODE}"
    if [[ "${BRANCH_SELECT_MODE}" == "wi-history" ]] && ! branch_mentions_wi "${branch}"; then
      reason="no ${WI_TAG} in branch commit history"
    elif [[ "${BRANCH_SELECT_MODE}" == "affected-file" ]] && ! branch_has_file "${branch}"; then
      reason="'${AFFECTED_FILE}' not present"
    fi
    log "SKIP  ${branch} — ${reason}"
    record SKIPPED "${branch}" "${reason}"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ "${PROPAGATION_MODE}" == "pr" ]] && is_expected_wi_failure "${branch}"; then
    log "FAIL  ${branch} — WI history match but missing '${AFFECTED_FILE}'"
    record FAILED "${branch}" "WI history match but missing '${AFFECTED_FILE}' (cannot apply fix)"
    failed=$((failed + 1))
    expected_failed=$((expected_failed + 1))
    continue
  fi

  if [[ "${PROPAGATION_MODE}" == "pr" ]]; then
    if apply_via_pr "${branch}" "${GITHUB_REPO}"; then
      prs=$((prs + 1))
      pr_url="$(grep -F "${branch}|" "${PRS_FILE}" 2>/dev/null | tail -1 | cut -d'|' -f2-)"
      record PR_OPENED "${branch}" "pull request opened" "${pr_url}"
    else
      classify_failure "${branch}"
    fi
  elif apply_direct "${branch}"; then
    applied=$((applied + 1))
    record APPLIED "${branch}" "fix cherry-picked onto branch"
  else
    classify_failure "${branch}"
  fi
done < <(list_branches)

git checkout "${ORIG_BRANCH}" >> /dev/null 2>&1 || git checkout main >> /dev/null 2>&1 || true

log ""
if [[ "${PROPAGATION_MODE}" == "pr" ]]; then
  log "Summary: ${prs} PR(s) opened, ${skipped} skipped, ${conflicts} conflict(s), ${failed} failed"
  log "PR list: ${PRS_FILE}"
else
  log "Summary: ${applied} applied, ${skipped} skipped, ${conflicts} conflict(s), ${failed} failed"
fi
log "Full log: ${SUMMARY_FILE}"
log "Results  : ${RESULTS_FILE}"

# Conflicts and missing-file failures are expected, non-fatal outcomes: they are
# reported (and emailed) but never stop the run. Only truly unexpected failures
# (or too few PRs in PR mode) fail the job.
if [[ "${conflicts}" -gt 0 ]]; then
  log "Note: ${conflicts} branch(es) need manual conflict resolution (no auto-propagation)."
fi
if [[ "${expected_failed}" -gt 0 ]]; then
  log "Note: ${expected_failed} WI branch(es) without '${AFFECTED_FILE}' (fix not applicable)."
fi

if [[ "${PROPAGATION_MODE}" == "pr" && "${prs}" -lt "${MIN_PRS}" ]]; then
  log "Error: PR mode requires at least ${MIN_PRS} pull requests, opened ${prs}"
  exit 1
fi
if [[ "${unexpected_failed}" -gt 0 ]]; then
  log "Error: ${unexpected_failed} unexpected failure(s)"
  exit 1
fi

exit 0
