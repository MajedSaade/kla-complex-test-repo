#!/usr/bin/env bash
#
# restore_github_main.sh — Put CI tooling back on GitHub main after a fixture force-push.
#
# The fixture generator push overwrites main without .github/ or scripts/.
# Run this from the repo root, then push main.
#
# Usage:
#   ./scripts/restore_github_main.sh
#   git push origin main --force
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

echo "Checking local main has CI tooling..."
for path in .github/workflows/patch-propagation.yml scripts/propagate_patch.sh generate_complex_repo.sh; do
  if [[ ! -e "${path}" ]]; then
    echo "Error: missing ${path} on local main" >&2
    exit 1
  fi
done

git fetch origin

if git show origin/main:.github/workflows/patch-propagation.yml >/dev/null 2>&1; then
  echo "GitHub main already has the workflow — nothing to restore."
  exit 0
fi

echo ""
echo "GitHub main is missing CI tooling (likely overwritten by fixture push)."
echo "Restore it with:"
echo ""
echo "  git push origin main --force"
echo ""
echo "This keeps your fresh fixture branches on GitHub and puts the workflow back on main."
echo "The push to main will automatically trigger Patch Propagation CI."
