#!/usr/bin/env bash
#
# notify_propagation.sh — Summarize propagation outcomes and email them.
#
# Reads the machine-readable results written by propagate_patch.sh
# (.propagation-logs/results.tsv) and produces a report grouped into:
#   1. Pull requests opened   — which PRs were opened and onto which branches
#   2. Skipped                — branches skipped, each with the reason
#   3. No action / cannot apply — branches that received nothing, with the reason
#
# The report is always printed to stdout and appended to the GitHub Actions run
# summary ($GITHUB_STEP_SUMMARY). If SMTP settings are provided it is also sent
# as an email.
#
# Usage:
#   ./scripts/notify_propagation.sh [REPO_DIR]
#
# Email environment (all required to actually send; otherwise email is skipped):
#   NOTIFY_EMAIL_TO     recipient address(es), comma-separated
#   NOTIFY_EMAIL_FROM   sender address
#   SMTP_SERVER         SMTP host
#   SMTP_USERNAME       SMTP login
#   SMTP_PASSWORD       SMTP password / app password
# Optional:
#   SMTP_PORT           SMTP port (default 587)
#   SMTP_SECURITY       starttls (default) | ssl | none
#   NOTIFY_SUBJECT      subject line override
#

set -euo pipefail

REPO_DIR="${1:-.}"
REPO_DIR="$(cd "${REPO_DIR}" && pwd)"

WI_ID="${WI_ID:-WI-440219}"
LOG_DIR="${LOG_DIR:-${REPO_DIR}/.propagation-logs}"
RESULTS_FILE="${RESULTS_FILE:-${LOG_DIR}/results.tsv}"

REPO_SLUG="${GITHUB_REPOSITORY:-$(basename "${REPO_DIR}")}"
RUN_URL=""
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

if [[ ! -f "${RESULTS_FILE}" ]]; then
  echo "notify: no results file at ${RESULTS_FILE}; nothing to report." >&2
  exit 0
fi

opened=()
skipped=()
noaction=()

while IFS=$'\t' read -r status branch reason url; do
  [[ -z "${status:-}" ]] && continue
  case "${status}" in
    PR_OPENED)   opened+=("${branch} → ${url:-(url unavailable)}") ;;
    PR_EXISTING) opened+=("${branch} → ${url:-(existing PR)} (already open)") ;;
    APPLIED)     opened+=("${branch} (fix cherry-picked directly)") ;;
    SKIPPED)     skipped+=("${branch} — ${reason:-skipped}") ;;
    FAILED)      noaction+=("${branch} — ${reason:-could not apply}") ;;
    *)           skipped+=("${branch} — ${reason:-${status}}") ;;
  esac
done < "${RESULTS_FILE}"

SUBJECT="${NOTIFY_SUBJECT:-Patch Propagation [${WI_ID}] on ${REPO_SLUG}: ${#opened[@]} PR/applied, ${#skipped[@]} skipped, ${#noaction[@]} no-action}"

print_section() {
  local title="$1"; shift
  printf '%s (%d)\n' "${title}" "$#"
  if [[ "$#" -eq 0 ]]; then
    printf '  (none)\n'
  else
    printf '  - %s\n' "$@"
  fi
  printf '\n'
}

BODY_FILE="$(mktemp)"
{
  printf 'Patch Propagation Report — [%s]\n' "${WI_ID}"
  printf 'Repository : %s\n' "${REPO_SLUG}"
  [[ -n "${RUN_URL}" ]] && printf 'CI run     : %s\n' "${RUN_URL}"
  printf '\n'
  print_section "Pull requests opened / fixes applied" "${opened[@]}"
  print_section "Skipped (and why)" "${skipped[@]}"
  print_section "No action / could not apply (received nothing)" "${noaction[@]}"
} > "${BODY_FILE}"

echo "==================== Propagation Notification ===================="
cat "${BODY_FILE}"
echo "=================================================================="

# Surface in the GitHub Actions run summary when available.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '## %s\n\n' "${SUBJECT}"
    printf '```\n'
    cat "${BODY_FILE}"
    printf '```\n'
  } >> "${GITHUB_STEP_SUMMARY}"
fi

# Send the email only when fully configured; otherwise skip cleanly.
if [[ -n "${NOTIFY_EMAIL_TO:-}" && -n "${NOTIFY_EMAIL_FROM:-}" \
   && -n "${SMTP_SERVER:-}" && -n "${SMTP_USERNAME:-}" && -n "${SMTP_PASSWORD:-}" ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "notify: python3 not available; cannot send email." >&2
    rm -f "${BODY_FILE}"
    exit 0
  fi
  NOTIFY_SUBJECT="${SUBJECT}" NOTIFY_BODY_FILE="${BODY_FILE}" python3 <<'PY' || echo "notify: email send failed (non-fatal) — report still in logs/summary." >&2
import os, smtplib, ssl, sys
from email.message import EmailMessage

to = [a.strip() for a in os.environ["NOTIFY_EMAIL_TO"].split(",") if a.strip()]
msg = EmailMessage()
msg["From"] = os.environ["NOTIFY_EMAIL_FROM"]
msg["To"] = ", ".join(to)
msg["Subject"] = os.environ["NOTIFY_SUBJECT"]
with open(os.environ["NOTIFY_BODY_FILE"], "r", encoding="utf-8") as fh:
    msg.set_content(fh.read())

host = os.environ["SMTP_SERVER"]
port = int(os.environ.get("SMTP_PORT", "587"))
user = os.environ["SMTP_USERNAME"]
password = os.environ["SMTP_PASSWORD"]
security = os.environ.get("SMTP_SECURITY", "starttls").lower()

try:
    if security == "ssl":
        with smtplib.SMTP_SSL(host, port, context=ssl.create_default_context(), timeout=30) as s:
            s.login(user, password)
            s.send_message(msg)
    else:
        with smtplib.SMTP(host, port, timeout=30) as s:
            if security != "none":
                s.starttls(context=ssl.create_default_context())
            s.login(user, password)
            s.send_message(msg)
    print(f"notify: email sent to {', '.join(to)}")
except Exception as exc:  # noqa: BLE001 — report and fail soft
    print(f"notify: failed to send email: {exc}", file=sys.stderr)
    sys.exit(1)
PY
else
  echo "notify: SMTP/email env not set — email skipped (report shown above)."
fi

rm -f "${BODY_FILE}"
