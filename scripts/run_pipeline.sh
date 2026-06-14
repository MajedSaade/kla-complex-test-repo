#!/usr/bin/env bash
#
# run_pipeline.sh — Full local pipeline: generate → propagate → verify.
#
# Usage:
#   ./scripts/run_pipeline.sh [TARGET_DIR]
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${1:-${ROOT}/complex-test-repo}"

echo ">>> Step 1/3: Generate complex test repository"
"${ROOT}/generate_complex_repo.sh" "${TARGET_DIR}"

echo ""
echo ">>> Step 2/3: Propagate definitive fix across branches"
"${ROOT}/scripts/propagate_patch.sh" "${TARGET_DIR}"

echo ""
echo ">>> Step 3/3: Verify propagation outcomes"
"${ROOT}/scripts/verify_propagation.sh" "${TARGET_DIR}"

echo ""
echo "Pipeline complete."
