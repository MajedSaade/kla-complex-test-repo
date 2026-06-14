#!/usr/bin/env bash
#
# push_all_branches.sh — Push all branches to GitHub.
#
# Usage:
#   ./scripts/push_all_branches.sh [GITHUB_REPO]
#
# Example:
#   ./scripts/push_all_branches.sh MajedSaade/kla-complex-test-repo
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

GITHUB_REPO="${1:-MajedSaade/kla-complex-test-repo}"
REMOTE_URL="https://github.com/${GITHUB_REPO}.git"

echo "Repository : ${GITHUB_REPO}"
echo "Local path : ${ROOT}"
echo ""

if ! git remote get-url origin >/dev/null 2>&1; then
  git remote add origin "${REMOTE_URL}"
else
  git remote set-url origin "${REMOTE_URL}"
fi

echo "Pushing all branches to origin..."
git push -u origin --all
git push origin --tags 2>/dev/null || true

echo ""
echo "Done:"
echo "  https://github.com/${GITHUB_REPO}/branches"
echo "  https://github.com/${GITHUB_REPO}/network"
echo "  https://github.com/${GITHUB_REPO}/actions"
