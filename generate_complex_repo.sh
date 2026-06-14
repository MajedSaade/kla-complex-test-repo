#!/usr/bin/env bash
#
# generate_complex_repo.sh
# Initializes a local Git repository with a realistic multi-branch enterprise
# history for stress-testing cross-branch patch propagation tooling.
#
# Usage: ./generate_complex_repo.sh [TARGET_DIR]
#   TARGET_DIR  Optional path for the generated repo (default: ./complex-test-repo)
#

set -euo pipefail

TARGET_DIR="${1:-./complex-test-repo}"
WI="[WI-440219]"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

init_repo() {
  rm -rf "${TARGET_DIR}"
  mkdir -p "${TARGET_DIR}"
  cd "${TARGET_DIR}"
  git init -b main
  git config user.email "devops@enterprise.local"
  git config user.name "Enterprise DevOps Bot"

  # Seed directory structure
  mkdir -p src/auth src/payment src/ui src/analytics src/ledger \
           src/notifications src/compliance src/mobile src/db \
           src/admin infra/ci infra/k8s config docs
}

# append_to_file <path> <content...>
append_to_file() {
  local file="$1"
  shift
  mkdir -p "$(dirname "${file}")"
  {
    echo "# Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "$@"
    echo
  } >> "${file}"
}

# commit_change <message> <file> <content...>
commit_change() {
  local message="$1"
  local file="$2"
  shift 2
  append_to_file "${file}" "$@"
  git add "${file}"
  git commit -m "${message}"
}

# new_branch <name> [<parent>]
new_branch() {
  local name="$1"
  local parent="${2:-}"
  if [[ -n "${parent}" ]]; then
    git checkout "${parent}" 2>/dev/null || git switch "${parent}"
  fi
  git checkout -b "${name}" 2>/dev/null || git switch -c "${name}"
}

section() {
  echo
  echo "================================================================"
  echo "  $*"
  echo "================================================================"
}

# ---------------------------------------------------------------------------
# Repository bootstrap
# ---------------------------------------------------------------------------

section "Initializing repository at ${TARGET_DIR}"
init_repo

# ---------------------------------------------------------------------------
# main — 5 baseline infrastructure commits (no work item tags)
# Split: first 2 commits = "early main" for release/v1.0 fork point
# ---------------------------------------------------------------------------

section "Branch: main (baseline infrastructure)"

commit_change \
  "Add core application configuration scaffold" \
  "config/app.yaml" \
  "app:" \
  "  name: enterprise-platform" \
  "  version: 0.1.0" \
  "  environment: development"

commit_change \
  "Introduce shared logging and metrics bootstrap" \
  "config/logging.yaml" \
  "logging:" \
  "  level: INFO" \
  "  format: json" \
  "metrics:" \
  "  exporter: prometheus" \
  "  port: 9090"

# --- release/v1.0 forks from early main (after 2 baseline commits) ---

section "Branch: release/v1.0 (from early main)"

new_branch "release/v1.0"

commit_change \
  "Stage production build pipeline configuration" \
  "infra/ci/release-pipeline.yaml" \
  "pipeline:" \
  "  name: release-v1.0" \
  "  stages: [build, test, package]" \
  "  artifact_registry: prod-ecr"

commit_change \
  "Pin dependency versions for v1.0 release candidate" \
  "config/dependencies.lock" \
  "django==4.2.7" \
  "celery==5.3.4" \
  "redis==5.0.1"

commit_change \
  "Configure production smoke-test suite ${WI}" \
  "infra/ci/smoke-tests.yaml" \
  "smoke_tests:" \
  "  target: production-staging" \
  "  suites: [health, auth, payment-smoke]" \
  "  work_item: WI-440219"

commit_change \
  "Add release notes template and changelog skeleton" \
  "docs/RELEASE_NOTES_v1.0.md" \
  "# Release v1.0.0" \
  "## Highlights" \
  "- Initial production release" \
  "- Core platform services"

commit_change \
  "Finalize v1.0 deployment checklist and rollback plan" \
  "docs/deployment-checklist-v1.0.md" \
  "## Pre-deploy" \
  "- [ ] Database backup verified" \
  "- [ ] Feature flags reviewed" \
  "## Rollback" \
  "- Trigger helm rollback to previous revision"

# --- Continue main with remaining 3 baseline commits ---

section "Branch: main (continued — commits 3–5)"

git checkout main 2>/dev/null || git switch main

commit_change \
  "Add CI/CD pipeline definitions for main branch" \
  "infra/ci/main-pipeline.yaml" \
  "pipeline:" \
  "  name: main-ci" \
  "  triggers: [push, pull_request]" \
  "  jobs: [lint, unit-test, integration-test]"

commit_change \
  "Configure Docker multi-stage build for services" \
  "infra/ci/Dockerfile" \
  "FROM python:3.11-slim AS builder" \
  "WORKDIR /app" \
  "COPY requirements.txt ." \
  "RUN pip install --no-cache-dir -r requirements.txt"

commit_change \
  "Add infrastructure-as-code baseline with Terraform modules" \
  "infra/terraform/main.tf" \
  "terraform {" \
  "  required_version = \">= 1.5.0\"" \
  "}" \
  "module \"networking\" {" \
  "  source = \"./modules/networking\"" \
  "}"

# ---------------------------------------------------------------------------
# feature/user-auth (from main)
# ---------------------------------------------------------------------------

section "Branch: feature/user-auth (from main)"

new_branch "feature/user-auth" "main"

commit_change \
  "Implement JWT token issuance and validation middleware" \
  "src/auth/jwt_handler.py" \
  "import jwt" \
  "from datetime import datetime, timedelta" \
  "" \
  "def issue_token(user_id: str, secret: str) -> str:" \
  "    payload = {'sub': user_id, 'exp': datetime.utcnow() + timedelta(hours=1)}" \
  "    return jwt.encode(payload, secret, algorithm='HS256')"

commit_change \
  "Add OAuth2 provider integration for Google and GitHub" \
  "src/auth/oauth_provider.py" \
  "OAUTH_PROVIDERS = {" \
  "    'google': {'client_id': None, 'scopes': ['openid', 'email']}," \
  "    'github': {'client_id': None, 'scopes': ['user:email']}," \
  "}"

commit_change \
  "Implement server-side session store with Redis backend" \
  "src/auth/session_store.py" \
  "class SessionStore:" \
  "    def __init__(self, redis_client):" \
  "        self._redis = redis_client" \
  "" \
  "    def create(self, session_id: str, data: dict, ttl: int = 3600):" \
  "        self._redis.setex(session_id, ttl, str(data))"

commit_change \
  "Add refresh token rotation and revocation endpoints" \
  "src/auth/refresh_tokens.py" \
  "def rotate_refresh_token(old_token: str) -> tuple[str, str]:" \
  "    revoke_token(old_token)" \
  "    return generate_token_pair()" \
  "" \
  "def revoke_token(token: str) -> None:" \
  "    TOKEN_BLOCKLIST.add(token)"

commit_change \
  "Wire auth middleware into application request pipeline" \
  "src/auth/middleware.py" \
  "class AuthMiddleware:" \
  "    def __init__(self, app):" \
  "        self.app = app" \
  "" \
  "    async def __call__(self, scope, receive, send):" \
  "        token = extract_bearer_token(scope)" \
  "        scope['user'] = validate_token(token)"

# ---------------------------------------------------------------------------
# feature/payment-gateway (from main) — WI in commits #2 and #4
# ---------------------------------------------------------------------------

section "Branch: feature/payment-gateway (from main)"

new_branch "feature/payment-gateway" "main"

commit_change \
  "Scaffold payment gateway service and routing layer" \
  "src/payment/gateway.py" \
  "class PaymentGateway:" \
  "    def __init__(self, providers: list):" \
  "        self.providers = providers" \
  "" \
  "    def route(self, transaction: dict) -> str:" \
  "        return self.providers[0].process(transaction)"

commit_change \
  "Integrate Stripe billing engine adapter ${WI}" \
  "src/payment/stripe_adapter.py" \
  "class StripeAdapter:" \
  "    def process(self, amount_cents: int, currency: str) -> dict:" \
  "        # WI-440219: initial Stripe integration with idempotency keys" \
  "        return {'status': 'pending', 'provider': 'stripe'}"

commit_change \
  "Add PayPal and ACH payment method handlers" \
  "src/payment/providers.py" \
  "PAYMENT_METHODS = {" \
  "    'paypal': PayPalHandler()," \
  "    'ach': ACHHandler()," \
  "    'card': CardHandler()," \
  "}"

commit_change \
  "Implement concurrent transaction queue with retry logic ${WI}" \
  "src/payment/transaction_queue.py" \
  "import threading" \
  "from queue import Queue" \
  "" \
  "class TransactionQueue:" \
  "    def __init__(self):" \
  "        self._queue = Queue()" \
  "        self._lock = threading.Lock()  # WI-440219: partial lock — race remains"

commit_change \
  "Add payment webhook receiver and event dispatcher" \
  "src/payment/webhooks.py" \
  "WEBHOOK_EVENTS = ['payment.succeeded', 'payment.failed', 'refund.created']" \
  "" \
  "def dispatch_webhook(event_type: str, payload: dict):" \
  "    handler = HANDLERS.get(event_type)" \
  "    if handler:" \
  "        handler(payload)"

# ---------------------------------------------------------------------------
# bugfix/payment-patch (from feature/payment-gateway)
# Commit #5 = definitive fix (propagation target)
# ---------------------------------------------------------------------------

section "Branch: bugfix/payment-patch (from feature/payment-gateway)"

new_branch "bugfix/payment-patch" "feature/payment-gateway"

commit_change \
  "Reproduce race condition in concurrent payment processing" \
  "src/payment/bug_repro.py" \
  "def reproduce_double_charge(txn_id: str):" \
  "    # Simulates duplicate charge under concurrent load" \
  "    pass"

commit_change \
  "Add diagnostic logging around transaction queue locks" \
  "src/payment/diagnostics.py" \
  "import logging" \
  "logger = logging.getLogger('payment.diagnostics')" \
  "" \
  "def log_lock_state(queue):" \
  "    logger.debug('Lock held: %s', queue._lock.locked())"

commit_change \
  "Introduce mutex wrapper for critical payment sections" \
  "src/payment/mutex_wrapper.py" \
  "class PaymentMutex:" \
  "    def __enter__(self):" \
  "        self._lock.acquire()" \
  "    def __exit__(self, *args):" \
  "        self._lock.release()"

commit_change \
  "Add integration tests for concurrent payment scenarios" \
  "src/payment/test_concurrent.py" \
  "def test_concurrent_charges_no_duplicate():" \
  "    # Will pass after definitive fix" \
  "    assert True"

commit_change \
  "Apply definitive thread-safe fix for payment engine ${WI}" \
  "src/payment/transaction_queue.py" \
  "import threading" \
  "from queue import Queue" \
  "" \
  "class TransactionQueue:" \
  "    def __init__(self):" \
  "        self._queue = Queue()" \
  "        self._lock = threading.RLock()  # WI-440219: definitive thread-safe fix" \
  "" \
  "    def enqueue(self, txn: dict) -> None:" \
  "        with self._lock:" \
  "            if not self._is_duplicate(txn):" \
  "                self._queue.put(txn)" \
  "" \
  "    def _is_duplicate(self, txn: dict) -> bool:" \
  "        with self._lock:" \
  "            return txn['id'] in self._processed_ids"

# ---------------------------------------------------------------------------
# feature/ui-ux (from main)
# ---------------------------------------------------------------------------

section "Branch: feature/ui-ux (from main)"

new_branch "feature/ui-ux" "main"

commit_change \
  "Establish design system tokens and color palette" \
  "src/ui/design-tokens.css" \
  ":root {" \
  "  --color-primary: #2563eb;" \
  "  --color-secondary: #64748b;" \
  "  --spacing-unit: 8px;" \
  "}"

commit_change \
  "Implement responsive grid layout components" \
  "src/ui/layout.css" \
  ".grid-container {" \
  "  display: grid;" \
  "  grid-template-columns: repeat(12, 1fr);" \
  "  gap: var(--spacing-unit);" \
  "}"

commit_change \
  "Add dark mode theme variant and toggle" \
  "src/ui/themes.css" \
  "[data-theme='dark'] {" \
  "  --color-bg: #0f172a;" \
  "  --color-text: #f8fafc;" \
  "}"

commit_change \
  "Build reusable button and form input components" \
  "src/ui/components.css" \
  ".btn-primary {" \
  "  background: var(--color-primary);" \
  "  padding: calc(var(--spacing-unit) * 1.5);" \
  "  border-radius: 6px;" \
  "}"

commit_change \
  "Polish checkout flow layout and accessibility labels" \
  "src/ui/checkout.css" \
  ".checkout-form label {" \
  "  font-weight: 600;" \
  "  aria-required: true;" \
  "}"

# ---------------------------------------------------------------------------
# feature/analytics-pipeline (from main) — no WI
# ---------------------------------------------------------------------------

section "Branch: feature/analytics-pipeline (from main)"

new_branch "feature/analytics-pipeline" "main"

commit_change \
  "Define analytics event schema and ingestion contract" \
  "src/analytics/event_schema.json" \
  '{"type":"object","properties":{"event_id":{"type":"string"},"timestamp":{"type":"string"}}}'

commit_change \
  "Implement Kafka producer for real-time event streams" \
  "src/analytics/kafka_producer.py" \
  "from kafka import KafkaProducer" \
  "" \
  "producer = KafkaProducer(" \
  "    bootstrap_servers=['kafka:9092']," \
  "    value_serializer=lambda v: json.dumps(v).encode()" \
  ")"

commit_change \
  "Add stream aggregator for hourly rollups" \
  "src/analytics/aggregator.py" \
  "class HourlyAggregator:" \
  "    def aggregate(self, events: list) -> dict:" \
  "        buckets = {}" \
  "        for e in events:" \
  "            hour = e['timestamp'][:13]" \
  "            buckets.setdefault(hour, []).append(e)" \
  "        return buckets"

commit_change \
  "Configure Flink job for session reconstruction" \
  "src/analytics/flink_job.yaml" \
  "job:" \
  "  name: session-reconstruction" \
  "  parallelism: 4" \
  "  checkpoint_interval: 60s"

commit_change \
  "Wire analytics dashboard data API endpoints" \
  "src/analytics/api.py" \
  "def get_hourly_metrics(date: str) -> dict:" \
  "    return query_warehouse(f'SELECT * FROM hourly_rollups WHERE date = {date}')"

# ---------------------------------------------------------------------------
# feature/ledger-audit (from feature/payment-gateway) — WI commit #2 (1/4)
# ---------------------------------------------------------------------------

section "Branch: feature/ledger-audit (from feature/payment-gateway)"

new_branch "feature/ledger-audit" "feature/payment-gateway"

commit_change \
  "Initialize immutable ledger store with append-only log" \
  "src/ledger/ledger.py" \
  "class Ledger:" \
  "    def __init__(self, storage):" \
  "        self._storage = storage" \
  "" \
  "    def append(self, entry: dict) -> str:" \
  "        entry['hash'] = compute_hash(entry)" \
  "        return self._storage.write(entry)"

commit_change \
  "Add discrepancy detection for payment reconciliation ${WI}" \
  "src/ledger/reconciliation.py" \
  "def detect_discrepancies(payments: list, ledger: list) -> list:" \
  "    # WI-440219: flag mismatches caused by concurrent payment race" \
  "    payment_ids = {p['id'] for p in payments}" \
  "    ledger_ids = {e['txn_id'] for e in ledger}" \
  "    return list(payment_ids.symmetric_difference(ledger_ids))"

commit_change \
  "Implement audit trail export to S3 archive" \
  "src/ledger/export.py" \
  "def export_audit_trail(start_date: str, end_date: str, bucket: str):" \
  "    entries = fetch_entries(start_date, end_date)" \
  "    upload_to_s3(bucket, f'audit/{start_date}_{end_date}.jsonl', entries)"

commit_change \
  "Add cryptographic signing for ledger entries" \
  "src/ledger/signing.py" \
  "from cryptography.hazmat.primitives.asymmetric import ed25519" \
  "" \
  "def sign_entry(entry: dict, private_key) -> bytes:" \
  "    return private_key.sign(json.dumps(entry, sort_keys=True).encode())"

commit_change \
  "Build ledger query API with pagination and filters" \
  "src/ledger/query_api.py" \
  "def query_ledger(filters: dict, page: int = 1, size: int = 50):" \
  "    return paginate(apply_filters(fetch_all(), filters), page, size)"

# ---------------------------------------------------------------------------
# feature/notifications (from main) — no WI
# ---------------------------------------------------------------------------

section "Branch: feature/notifications (from main)"

new_branch "feature/notifications" "main"

commit_change \
  "Scaffold notification service with template engine" \
  "src/notifications/service.py" \
  "class NotificationService:" \
  "    def __init__(self, channels: dict):" \
  "        self.channels = channels" \
  "" \
  "    def send(self, template: str, recipient: str, context: dict):" \
  "        rendered = render_template(template, context)" \
  "        return self.channels['email'].deliver(recipient, rendered)"

commit_change \
  "Implement transactional email delivery via SendGrid" \
  "src/notifications/email.py" \
  "class EmailChannel:" \
  "    def deliver(self, to: str, body: str) -> bool:" \
  "        response = sendgrid_client.send(to=to, subject='Notification', body=body)" \
  "        return response.status_code == 202"

commit_change \
  "Add SMS delivery channel with Twilio integration" \
  "src/notifications/sms.py" \
  "class SMSChannel:" \
  "    def deliver(self, phone: str, message: str) -> bool:" \
  "        return twilio_client.messages.create(to=phone, body=message)"

commit_change \
  "Build webhook trigger dispatcher with retry and DLQ" \
  "src/notifications/webhooks.py" \
  "class WebhookDispatcher:" \
  "    MAX_RETRIES = 3" \
  "" \
  "    def dispatch(self, url: str, payload: dict):" \
  "        for attempt in range(self.MAX_RETRIES):" \
  "            if post_with_timeout(url, payload):" \
  "                return True" \
  "        dead_letter_queue.put({'url': url, 'payload': payload})"

commit_change \
  "Add user notification preference management endpoints" \
  "src/notifications/preferences.py" \
  "DEFAULT_PREFERENCES = {" \
  "    'email': True," \
  "    'sms': False," \
  "    'webhook': True," \
  "}"

# ---------------------------------------------------------------------------
# feature/compliance-reporting (from feature/ledger-audit) — WI commit #4 (2/4)
# ---------------------------------------------------------------------------

section "Branch: feature/compliance-reporting (from feature/ledger-audit)"

new_branch "feature/compliance-reporting" "feature/ledger-audit"

commit_change \
  "Define compliance report schema for financial filings" \
  "src/compliance/schema.json" \
  '{"report_types":["SOX","PCI-DSS","GDPR"],"version":"1.0"}'

commit_change \
  "Implement SOX control evidence collector" \
  "src/compliance/sox_collector.py" \
  "def collect_sox_evidence(period: str) -> dict:" \
  "    return {" \
  "        'access_logs': fetch_access_logs(period)," \
  "        'change_records': fetch_change_records(period)," \
  "    }"

commit_change \
  "Add PCI-DSS scan result aggregation module" \
  "src/compliance/pci_scanner.py" \
  "def aggregate_scan_results(scans: list) -> dict:" \
  "    return {" \
  "        'critical': sum(1 for s in scans if s['severity'] == 'critical')," \
  "        'findings': scans," \
  "    }"

commit_change \
  "Generate quarterly financial report accounting for ${WI} affected data" \
  "src/compliance/quarterly_report.py" \
  "def generate_quarterly_report(quarter: str) -> dict:" \
  "    # WI-440219: include reconciliation adjustments for race-affected txns" \
  "    base = fetch_ledger_summary(quarter)" \
  "    adjustments = fetch_wi440219_adjustments(quarter)" \
  "    return merge_report(base, adjustments)"

commit_change \
  "Export compliance reports to PDF and regulatory portal" \
  "src/compliance/export.py" \
  "def export_to_pdf(report: dict, output_path: str):" \
  "    pdf = build_pdf(report)" \
  "    pdf.save(output_path)" \
  "" \
  "def submit_to_portal(report: dict, portal_url: str):" \
  "    return httpx.post(portal_url, json=report)"

# ---------------------------------------------------------------------------
# feature/mobile-api (from main) — no WI
# ---------------------------------------------------------------------------

section "Branch: feature/mobile-api (from main)"

new_branch "feature/mobile-api" "main"

commit_change \
  "Scaffold mobile REST API with FastAPI router" \
  "src/mobile/rest_api.py" \
  "from fastapi import APIRouter" \
  "router = APIRouter(prefix='/api/v1/mobile')" \
  "" \
  "@router.get('/health')" \
  "def health(): return {'status': 'ok'}"

commit_change \
  "Add GraphQL schema and resolvers for mobile clients" \
  "src/mobile/graphql_schema.py" \
  "type Query {" \
  "  userProfile(id: ID!): User" \
  "  transactions(limit: Int): [Transaction]" \
  "}"

commit_change \
  "Implement JWT-based mobile authentication flow" \
  "src/mobile/auth_flow.py" \
  "async def mobile_login(credentials: dict) -> dict:" \
  "    user = await authenticate(credentials)" \
  "    token = issue_mobile_token(user.id)" \
  "    return {'access_token': token, 'token_type': 'bearer'}"

commit_change \
  "Add push notification registration endpoints" \
  "src/mobile/push_registration.py" \
  "@router.post('/devices/register')" \
  "async def register_device(device_token: str, platform: str):" \
  "    await save_device_token(current_user.id, device_token, platform)"

commit_change \
  "Implement offline sync queue for mobile transactions" \
  "src/mobile/offline_sync.py" \
  "class OfflineSyncQueue:" \
  "    def enqueue(self, action: dict):" \
  "        self._pending.append({**action, 'synced': False})" \
  "" \
  "    async def flush(self):" \
  "        for item in self._pending:" \
  "            await sync_to_server(item)"

# ---------------------------------------------------------------------------
# feature/database-migration (from main) — WI commit #1 (3/4)
# ---------------------------------------------------------------------------

section "Branch: feature/database-migration (from main)"

new_branch "feature/database-migration" "main"

commit_change \
  "Add schema migration for payment table locks related to ${WI}" \
  "src/db/migrations/001_payment_locks.sql" \
  "-- WI-440219: advisory locks to prevent concurrent payment writes" \
  "ALTER TABLE payments ADD COLUMN lock_token UUID;" \
  "CREATE INDEX idx_payments_lock_token ON payments(lock_token);"

commit_change \
  "Create ledger_entries table with hash chain columns" \
  "src/db/migrations/002_ledger_entries.sql" \
  "CREATE TABLE ledger_entries (" \
  "  id BIGSERIAL PRIMARY KEY," \
  "  txn_id UUID NOT NULL," \
  "  entry_hash CHAR(64) NOT NULL," \
  "  prev_hash CHAR(64)," \
  "  created_at TIMESTAMPTZ DEFAULT NOW()" \
  ");"

commit_change \
  "Add composite indexes for analytics query patterns" \
  "src/db/migrations/003_analytics_indexes.sql" \
  "CREATE INDEX idx_events_timestamp ON analytics_events(timestamp DESC);" \
  "CREATE INDEX idx_events_user_ts ON analytics_events(user_id, timestamp DESC);"

commit_change \
  "Implement zero-downtime migration runner with advisory locks" \
  "src/db/migration_runner.py" \
  "def run_migration(migration_file: str):" \
  "    with advisory_lock('migration'):" \
  "        execute_sql(read_file(migration_file))" \
  "        record_migration(migration_file)"

commit_change \
  "Add database seed scripts for staging environments" \
  "src/db/seeds/staging.sql" \
  "INSERT INTO users (email, role) VALUES ('admin@staging.local', 'admin');" \
  "INSERT INTO payment_providers (name, active) VALUES ('stripe', true);"

# ---------------------------------------------------------------------------
# feature/admin-dashboard (from main) — no WI
# ---------------------------------------------------------------------------

section "Branch: feature/admin-dashboard (from main)"

new_branch "feature/admin-dashboard" "main"

commit_change \
  "Scaffold admin dashboard shell with navigation layout" \
  "src/admin/dashboard.html" \
  "<!DOCTYPE html>" \
  "<html><head><title>Admin Dashboard</title></head>" \
  "<body><nav id='sidebar'></nav><main id='content'></main></body></html>"

commit_change \
  "Add user management table with search and pagination" \
  "src/admin/users.js" \
  "function renderUserTable(users, page) {" \
  "  const tbody = document.querySelector('#users tbody');" \
  "  tbody.innerHTML = users.map(u => '<tr><td>' + u.email + '</td></tr>').join('');" \
  "}"

commit_change \
  "Implement role-based access control configuration UI" \
  "src/admin/rbac.js" \
  "const ROLES = ['admin', 'operator', 'viewer'];" \
  "function assignRole(userId, role) {" \
  "  return api.patch('/admin/users/' + userId + '/role', { role });" \
  "}"

commit_change \
  "Add system health monitoring widgets" \
  "src/admin/health_widgets.js" \
  "async function loadHealthMetrics() {" \
  "  const metrics = await api.get('/admin/health');" \
  "  renderGauge('cpu', metrics.cpu_percent);" \
  "  renderGauge('memory', metrics.memory_percent);" \
  "}"

commit_change \
  "Build audit log viewer with export functionality" \
  "src/admin/audit_viewer.js" \
  "function exportAuditLog(filters) {" \
  "  return api.get('/admin/audit/export', { params: filters, responseType: 'blob' });" \
  "}"

# ---------------------------------------------------------------------------
# infra/kubernetes-config (from main) — WI commit #3 (4/4)
# ---------------------------------------------------------------------------

section "Branch: infra/kubernetes-config (from main)"

new_branch "infra/kubernetes-config" "main"

commit_change \
  "Add base Helm chart for payment service deployment" \
  "infra/k8s/payment-service/Chart.yaml" \
  "apiVersion: v2" \
  "name: payment-service" \
  "version: 0.1.0" \
  "appVersion: \"1.0.0\""

commit_change \
  "Configure payment service values and resource limits" \
  "infra/k8s/payment-service/values.yaml" \
  "replicaCount: 3" \
  "resources:" \
  "  limits:" \
  "    cpu: 500m" \
  "    memory: 512Mi"

commit_change \
  "Add env vars to mitigate concurrent payment race ${WI}" \
  "infra/k8s/payment-service/templates/deployment.yaml" \
  "apiVersion: apps/v1" \
  "kind: Deployment" \
  "spec:" \
  "  template:" \
  "    spec:" \
  "      containers:" \
  "      - name: payment-service" \
  "        env:" \
  "        - name: PAYMENT_QUEUE_LOCK_MODE" \
  "          value: \"rlock\"  # WI-440219 mitigation" \
  "        - name: PAYMENT_IDEMPOTENCY_ENABLED" \
  "          value: \"true\""

commit_change \
  "Add Kubernetes ingress and TLS certificate configuration" \
  "infra/k8s/ingress.yaml" \
  "apiVersion: networking.k8s.io/v1" \
  "kind: Ingress" \
  "metadata:" \
  "  name: platform-ingress" \
  "  annotations:" \
  "    cert-manager.io/cluster-issuer: letsencrypt-prod"

commit_change \
  "Configure HorizontalPodAutoscaler for core services" \
  "infra/k8s/hpa.yaml" \
  "apiVersion: autoscaling/v2" \
  "kind: HorizontalPodAutoscaler" \
  "spec:" \
  "  minReplicas: 2" \
  "  maxReplicas: 10" \
  "  metrics:" \
  "  - type: Resource" \
  "    resource:" \
  "      name: cpu" \
  "      target:" \
  "        type: Utilization" \
  "        averageUtilization: 70"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

section "Repository generation complete"
echo "Location: $(pwd)"
echo
echo "Branches created:"
git branch -a | sed 's/^/  /'
echo
echo "Commits mentioning ${WI}:"
git log --all --oneline --grep="WI-440219" | sed 's/^/  /'
echo
echo "Target propagation commit (bugfix/payment-patch):"
git log bugfix/payment-patch --oneline -1 | sed 's/^/  /'
echo
echo "Full branch graph:"
git log --oneline --graph --all
