#!/usr/bin/env bash
#
# migrate_to_letter_branches.sh — Re-point the live repo's fixture branches at
# the new letter+number naming scheme (A11, A12, …, B2, …, G6) and add the
# extra payment-family WI branches, so the PR-mode run opens a PR per eligible
# branch (6 with the current fixture).
#
# It does NOT touch `main` (which holds the tooling on the live repo). It only
# (re)creates the generated *fixture* branches and removes the legacy
# numeric-prefixed ones.
#
# Safe by default: prints the plan and changes nothing. Set APPLY=true to push.
#
# Usage:
#   ./scripts/migrate_to_letter_branches.sh            # dry-run (no changes)
#   APPLY=true ./scripts/migrate_to_letter_branches.sh # push new branches + delete old
#
# Env:
#   TARGET_REMOTE   Remote URL/name to push to (default: origin of this repo)
#   APPLY           "true" to actually push/delete (default: false → dry-run)
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="${APPLY:-false}"

# Legacy numeric-prefixed branches to delete from the remote after the rename.
LEGACY_BRANCHES=(
  "05-release/v1.0"
  "10-feature/user-auth"
  "15-feature/payment-gateway"
  "20-bugfix/payment-patch"
  "25-feature/payment-hotfix"
  "30-feature/ui-ux"
  "35-feature/analytics-pipeline"
  "40-feature/ledger-audit"
  "45-feature/notifications"
  "50-feature/compliance-reporting"
  "55-feature/mobile-api"
  "60-feature/database-migration"
  "65-feature/admin-dashboard"
  "70-infra/kubernetes-config"
)

# Resolve the remote URL (so we can push from the throwaway fixture repo).
if [[ -n "${TARGET_REMOTE:-}" ]]; then
  REMOTE_URL="${TARGET_REMOTE}"
else
  REMOTE_URL="$(git -C "${ROOT}" remote get-url origin 2>/dev/null || true)"
fi

if [[ -z "${REMOTE_URL}" ]]; then
  echo "Error: no remote. Set TARGET_REMOTE=<url> or run inside a repo with an 'origin'." >&2
  exit 1
fi

echo "Letter-branch migration"
echo "======================="
echo "Remote : ${REMOTE_URL}"
echo "Apply  : ${APPLY}  (set APPLY=true to push/delete)"
echo ""

# Build a fresh fixture (the new letter scheme) in a throwaway directory.
FIXTURE_DIR="$(mktemp -d)"
trap 'chmod -R u+w "${FIXTURE_DIR}" 2>/dev/null || true; rm -rf "${FIXTURE_DIR}"' EXIT

echo ">>> Generating fixture with the new branch names…"
unset GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR 2>/dev/null || true
"${ROOT}/generate_complex_repo.sh" "${FIXTURE_DIR}/repo" >/dev/null

# Every generated branch except main is a fixture branch we want to publish.
mapfile -t NEW_BRANCHES < <(
  git -C "${FIXTURE_DIR}/repo" for-each-ref --format='%(refname:short)' refs/heads \
    | grep -vx 'main' | sort
)

echo ""
echo "Fixture branches to publish (force-push to the remote):"
printf '  + %s\n' "${NEW_BRANCHES[@]}"
echo ""
echo "Legacy branches to delete from the remote (best effort; protected ones may stay):"
printf '  - %s\n' "${LEGACY_BRANCHES[@]}"
echo ""

if [[ "${APPLY}" != "true" ]]; then
  echo "Dry-run only — nothing was changed. Re-run with APPLY=true to publish."
  exit 0
fi

git -C "${FIXTURE_DIR}/repo" remote add target "${REMOTE_URL}"

echo ">>> Pushing new branches…"
for b in "${NEW_BRANCHES[@]}"; do
  echo "  push ${b}"
  git -C "${FIXTURE_DIR}/repo" push --force target "refs/heads/${b}:refs/heads/${b}"
done

echo ">>> Deleting legacy branches…"
for b in "${LEGACY_BRANCHES[@]}"; do
  echo "  delete ${b}"
  git -C "${FIXTURE_DIR}/repo" push target ":refs/heads/${b}" \
    || echo "    (skip — branch absent or protected: ${b})"
done

echo ""
echo "Migration complete. Re-run the patch-propagation workflow to open PRs."
