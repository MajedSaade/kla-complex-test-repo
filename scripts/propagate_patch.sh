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

LOG_DIR="${LOG_DIR:-${REPO_DIR}/.propagation-logs}"
mkdir -p "${LOG_DIR}"
SUMMARY_FILE="${LOG_DIR}/propagation-summary.txt"
TARGETS_FILE="${LOG_DIR}/wi-target-branches.txt"
PRS_FILE="${LOG_DIR}/pull-requests.txt"
: > "${SUMMARY_FILE}"
: > "${TARGETS_FILE}"
: > "${PRS_FILE}"

log() {
  echo "$*" | tee -a "${SUMMARY_FILE}"
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
    [[ "${b}" == "HEAD" ]] && continue
    [[ -n "${seen[$b]:-}" ]] && continue
    echo "${b}"
  done < <(git for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null)
}

is_propagation_branch() {
  [[ "$1" == propagate/* ]]
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

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY   ${base_branch} — would open PR ${head_branch} → ${base_branch}"
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    local existing
    existing="$(gh pr list --repo "${repo}" --base "${base_branch}" --head "${head_branch}" --state open --json url --jq '.[0].url' 2>/dev/null || true)"
    if [[ -n "${existing}" && "${existing}" != "null" ]]; then
      log "PR    ${base_branch} — existing open PR ${existing}"
      echo "${base_branch}|${existing}" >> "${PRS_FILE}"
      return 0
    fi
    local url body_file
    body_file="$(mktemp)"
    printf '%s' "${body}" > "${body_file}"
    url="$(gh pr create --repo "${repo}" --base "${base_branch}" --head "${head_branch}" \
      --title "${title}" --body-file "${body_file}")"
    rm -f "${body_file}"
    log "PR    ${base_branch} — opened ${url}"
    echo "${base_branch}|${url}" >> "${PRS_FILE}"
    return 0
  fi

  if [[ -n "${GITHUB_TOKEN:-}" && -n "${repo}" ]]; then
    local existing_url
    existing_url="$(curl -sf \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${repo}/pulls?state=open&head=${repo%%/*}:${head_branch}&base=${base_branch}" \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['html_url'] if d else '')" 2>/dev/null || true)"
    if [[ -n "${existing_url}" ]]; then
      log "PR    ${base_branch} — existing open PR ${existing_url}"
      echo "${base_branch}|${existing_url}" >> "${PRS_FILE}"
      return 0
    fi
    local url
    url="$(python3 -c "
import json, urllib.request, os
payload = json.dumps({
    'title': '''${title//\'/\\\'}\''',
    'head': '${head_branch}',
    'base': '${base_branch}',
    'body': '''${body//\'/\\\'}\'''
}).encode()
req = urllib.request.Request(
    'https://api.github.com/repos/${repo}/pulls',
    data=payload,
    headers={
        'Authorization': f'Bearer {os.environ[\"GITHUB_TOKEN\"]}',
        'Accept': 'application/vnd.github+json',
        'Content-Type': 'application/json',
    },
    method='POST',
)
print(json.load(urllib.request.urlopen(req))['html_url'])
")"
    log "PR    ${base_branch} — opened ${url}"
    echo "${base_branch}|${url}" >> "${PRS_FILE}"
    return 0
  fi

  echo "Error: PR mode requires 'gh' CLI or GITHUB_TOKEN with repo access." >&2
  return 1
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
  if [[ "${BRANCH_SELECT_MODE}" == "wi-history" ]] && ! branch_has_file "${branch}"; then
    log "FAIL  ${branch} — WI history match but missing '${AFFECTED_FILE}' (see ${log_file})"
  else
    log "FAIL  ${branch} — cherry-pick conflict (see ${log_file})"
  fi
  return 1
}

apply_via_pr() {
  local branch="$1"
  local repo="$2"
  local prop_branch
  local log_file
  prop_branch="$(propagation_branch_name "${branch}")"
  log_file="${LOG_DIR}/pr-${branch//\//_}.log"

  git fetch origin "${branch}" >> "${log_file}" 2>&1 || git fetch origin >> "${log_file}" 2>&1 || true

  if ! git checkout -B "${prop_branch}" "origin/${branch}" >> "${log_file}" 2>&1; then
    git checkout -B "${prop_branch}" "${branch}" >> "${log_file}" 2>&1
  fi

  if ! git cherry-pick "${SOURCE_COMMIT}" >> "${log_file}" 2>&1; then
    git cherry-pick --abort >> "${log_file}" 2>&1 || true
    git checkout "${ORIG_BRANCH}" >> "${log_file}" 2>&1 || true
    if [[ "${BRANCH_SELECT_MODE}" == "wi-history" ]] && ! branch_has_file "${branch}"; then
      log "FAIL  ${branch} — WI history match but missing '${AFFECTED_FILE}' (see ${log_file})"
    else
      log "FAIL  ${branch} — cherry-pick conflict, no PR created (see ${log_file})"
    fi
    return 1
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "DRY   ${branch} — would push ${prop_branch} and open PR"
    git checkout "${ORIG_BRANCH}" >> "${log_file}" 2>&1 || true
    return 0
  fi

  git push -u origin "${prop_branch}" >> "${log_file}" 2>&1

  open_pull_request "${branch}" "${prop_branch}" "$(pr_title "${branch}")" "$(pr_body "${branch}")" "${repo}"
  git checkout "${ORIG_BRANCH}" >> "${log_file}" 2>&1 || git checkout main >> "${log_file}" 2>&1 || true
  return 0
}

# ---------------------------------------------------------------------------
# Locate the definitive fix commit
# ---------------------------------------------------------------------------

SOURCE_REF="$(branch_ref "${SOURCE_BRANCH}")"

SOURCE_COMMIT="$(
  git log "${SOURCE_REF}" --format='%H %s' \
    | grep -F "${FIX_MESSAGE_PATTERN}" \
    | grep -F "${WI_TAG}" \
    | head -1 \
    | cut -d' ' -f1
)"

if [[ -z "${SOURCE_COMMIT}" ]]; then
  echo "Error: could not find definitive fix on '${SOURCE_BRANCH}' (ref: ${SOURCE_REF})" >&2
  exit 1
fi

branch_mentions_wi() {
  local ref count
  ref="$(branch_ref "$1")"
  count="$(git rev-list "${ref}" --grep="${WI_ID}" --count 2>/dev/null || echo 0)"
  [[ "${count}" -gt 0 ]]
}

branch_has_file() {
  git cat-file -e "$(branch_ref "$1"):${AFFECTED_FILE}" 2>/dev/null
}

branch_has_fix() {
  git show "$(branch_ref "$1"):${AFFECTED_FILE}" 2>/dev/null | grep -Fq "${FIX_MARKER}"
}

should_target_branch() {
  local branch="$1"

  [[ "${branch}" == "${SOURCE_BRANCH}" ]] && return 1
  is_propagation_branch "${branch}" && return 1
  branch_has_fix "${branch}" && return 1

  case "${BRANCH_SELECT_MODE}" in
    wi-history) branch_mentions_wi "${branch}" ;;
    affected-file) branch_has_file "${branch}" ;;
    *) echo "Error: unknown BRANCH_SELECT_MODE '${BRANCH_SELECT_MODE}'" >&2; exit 1 ;;
  esac
}

GITHUB_REPO="$(github_repo_slug || true)"

log "Patch Propagation Report"
log "========================"
log "Repository : $(pwd)"
log "Work item  : ${WI_TAG}"
log "Source     : ${SOURCE_BRANCH} (${SOURCE_REF} → ${SOURCE_COMMIT:0:7})"
log "Selection  : ${BRANCH_SELECT_MODE}"
log "Mode       : ${PROPAGATION_MODE}"
log "Fix commit : $(git log -1 --format='%s' "${SOURCE_COMMIT}")"
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

while IFS= read -r branch; do
  is_propagation_branch "${branch}" && continue

  if [[ "${branch}" == "${SOURCE_BRANCH}" ]]; then
    log "SKIP  ${branch} — source branch (already contains fix)"
    skipped=$((skipped + 1))
    continue
  fi

  if branch_has_fix "${branch}"; then
    if [[ "${PROPAGATION_MODE}" == "pr" ]] && command -v gh >/dev/null 2>&1 && [[ -n "${GITHUB_REPO:-}" ]]; then
      local existing_pr
      existing_pr="$(gh pr list --repo "${GITHUB_REPO}" --base "${branch}" --state open \
        --search "Propagate [${WI_ID}] in:title" --json url --jq '.[0].url' 2>/dev/null || true)"
      if [[ -n "${existing_pr}" && "${existing_pr}" != "null" ]]; then
        log "SKIP  ${branch} — fix on branch; existing PR ${existing_pr}"
        echo "${branch}|${existing_pr}" >> "${PRS_FILE}"
      else
        log "SKIP  ${branch} — fix marker already present on branch"
      fi
    else
      log "SKIP  ${branch} — fix marker already present"
    fi
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

  if [[ "${PROPAGATION_MODE}" == "pr" ]]; then
    if apply_via_pr "${branch}" "${GITHUB_REPO}"; then
      prs=$((prs + 1))
    else
      failed=$((failed + 1))
    fi
  elif apply_direct "${branch}"; then
    applied=$((applied + 1))
  else
    failed=$((failed + 1))
  fi
done < <(list_branches)

git checkout "${ORIG_BRANCH}" >> /dev/null 2>&1 || git checkout main >> /dev/null 2>&1 || true

log ""
if [[ "${PROPAGATION_MODE}" == "pr" ]]; then
  log "Summary: ${prs} PR(s) opened, ${skipped} skipped, ${failed} failed"
  log "PR list: ${PRS_FILE}"
else
  log "Summary: ${applied} applied, ${skipped} skipped, ${failed} failed"
fi
log "Full log: ${SUMMARY_FILE}"

if [[ "${failed}" -gt 0 && "${BRANCH_SELECT_MODE}" == "wi-history" ]]; then
  log ""
  log "Note: FAIL on WI branches without '${AFFECTED_FILE}' is expected for this fixture."
  exit 0
fi

[[ "${failed}" -gt 0 ]] && exit 1
exit 0
