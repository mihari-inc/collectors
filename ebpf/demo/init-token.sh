#!/bin/sh
set -e

PG_HOST="${POSTGRES_HOST:-mihari-uptime-postgres}"
PG_USER="${POSTGRES_USER:-mihari}"
PG_PASS="${POSTGRES_PASSWORD:-mihari_dev_password}"
PG_DB="${POSTGRES_DB:-mihari_uptime}"

until pg_isready -h "$PG_HOST" -U "$PG_USER" 2>/dev/null; do
  echo "[init] Waiting for Postgres..."
  sleep 2
done

TOKEN="mih_demo_ebpf_000000000000000000000000000000000000"
TOKEN_HASH=$(echo -n "$TOKEN" | sha256sum | cut -d' ' -f1)
TOKEN_PREFIX="mih_demo_ebpf_00…"

psql_cmd() { PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -U "$PG_USER" -d "$PG_DB" "$@"; }

ORG_ID=$(psql_cmd -t -A -c "SELECT u.\"defaultOrganizationId\" FROM users u WHERE u.\"defaultOrganizationId\" IS NOT NULL LIMIT 1" 2>/dev/null || echo "")
[ -z "$ORG_ID" ] && ORG_ID=$(psql_cmd -t -A -c "SELECT id FROM organizations LIMIT 1" 2>/dev/null || echo "")

if [ -z "$ORG_ID" ]; then
  echo "[init] No organization found — waiting for Mihari seed..."
  for i in $(seq 1 30); do
    sleep 3
    ORG_ID=$(psql_cmd -t -A -c "SELECT u.\"defaultOrganizationId\" FROM users u WHERE u.\"defaultOrganizationId\" IS NOT NULL LIMIT 1" 2>/dev/null || echo "")
    [ -z "$ORG_ID" ] && ORG_ID=$(psql_cmd -t -A -c "SELECT id FROM organizations LIMIT 1" 2>/dev/null || echo "")
    if [ -n "$ORG_ID" ]; then break; fi
  done
fi

if [ -z "$ORG_ID" ]; then
  echo "[init] ERROR: No organization found after 90s. Is Mihari running?"
  exit 1
fi

echo "[init] Organization: $ORG_ID"

EXISTING=$(psql_cmd -t -A -c "SELECT count(*) FROM data_sources WHERE \"tokenHash\" = '$TOKEN_HASH'")

if [ "$EXISTING" != "0" ]; then
  echo "[init] Demo datasource already exists — skipping insert"
else
  echo "[init] Creating demo datasource..."
  psql_cmd -c "
    INSERT INTO data_sources (
      name, slug, kind, status, signals, protocols, environment,
      \"organizationId\", \"tokenHash\", \"tokenPrefix\", \"publicKey\",
      \"retentionDays\", colors
    ) VALUES (
      'eBPF Demo',
      'ebpf-demo-' || substr(md5(random()::text), 1, 6),
      'telemetry',
      'active',
      '[\"logs\",\"metrics\",\"traces\"]'::jsonb,
      '[\"otlp\"]'::jsonb,
      'production',
      '$ORG_ID',
      '$TOKEN_HASH',
      '$TOKEN_PREFIX',
      'pk-ebpf-demo-' || substr(md5(random()::text), 1, 16),
      30,
      '[\"#00d4ff\", \"#0066ff\"]'::jsonb
    );
  "
fi

echo "[init] Demo datasource ready — token: $TOKEN"
echo "$TOKEN" > /tmp/mihari-demo-token
