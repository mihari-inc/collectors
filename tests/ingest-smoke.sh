#!/usr/bin/env bash
# End-to-end ingest smoke test: POSTs one representative, already-parsed log
# payload per technology to /v1/ingest/vector and one Prometheus JSON-fallback
# body to /v1/ingest/prometheus, exactly as the Vector collectors would after
# their transforms. Verifies the API accepts everything (2xx).
#
# Usage:
#   INGESTION_URL=http://localhost:3000 TOKEN=<source-ingest-token> ./ingest-smoke.sh
#
# Compatible with macOS bash 3.2. Requires curl.

set -u

: "${INGESTION_URL:?INGESTION_URL is required (e.g. http://localhost:3000)}"
: "${TOKEN:?TOKEN is required (a data-source ingest token)}"

BASE="${INGESTION_URL%/}"
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NOW_MS=$(($(date +%s) * 1000))
failures=0

post() {
  # post <label> <path> <json-body>
  label=$1
  path=$2
  body=$3
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE$path" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    --data "$body")
  case "$code" in
    2*) echo "PASS $label ($code)" ;;
    *)
      echo "FAIL $label ($code)"
      failures=$((failures + 1))
      ;;
  esac
}

log_event() {
  # log_event <service> <host> <level> <message> <extra-json-attrs (",..." or "")>
  printf '[{"timestamp":"%s","service":"%s","host":"%s","level":"%s","message":"%s"%s}]' \
    "$NOW_ISO" "$1" "$2" "$3" "$4" "$5"
}

echo "Smoke-testing log ingest at $BASE/v1/ingest/vector"
post "kubernetes" /v1/ingest/vector "$(log_event checkout k8s-node-1 error 'Unhandled exception in payment handler' ',"k8s_namespace":"shop","k8s_pod":"checkout-5f4b9","k8s_container":"app","stream":"stderr"')"
post "debian" /v1/ingest/vector "$(log_event sshd deb-web-1 warn 'Failed password for invalid user admin from 203.0.113.7 port 51234 ssh2' ',"pid":"912","facility":"auth"')"
post "postgresql" /v1/ingest/vector "$(log_event postgresql deb-db-1 error 'duplicate key value violates unique constraint' ',"pid":"4471","db_user":"app","db_database":"app_prod"')"
post "mysql" /v1/ingest/vector "$(log_event mysql db-2 warn 'Aborted connection 42 to db' ',"thread":"42","subsystem":"Server","err_code":"MY-010055"')"
post "docker" /v1/ingest/vector "$(log_event api-container docker-host-1 info 'request handled in 12ms' ',"container_name":"api","stream":"stdout"')"
post "nginx" /v1/ingest/vector "$(log_event nginx lb-1 warn 'GET /missing 404' ',"http_method":"GET","http_path":"/missing","http_status":"404","client_ip":"198.51.100.3"')"
post "apache" /v1/ingest/vector "$(log_event apache web-2 info 'GET / 200' ',"http_method":"GET","http_path":"/","http_status":"200"')"
post "mongodb" /v1/ingest/vector "$(log_event mongodb db-3 error 'WiredTiger error' ',"component":"STORAGE","context":"initandlisten","mongo_id":"22435"')"
post "rabbitmq" /v1/ingest/vector "$(log_event rabbitmq mq-1 error 'connection closed abruptly' ',"erlang_pid":"<0.123.0>"')"
post "elasticsearch" /v1/ingest/vector "$(log_event elasticsearch es-1 warn 'high disk watermark exceeded' ',"component":"o.e.c.r.a.DiskThresholdMonitor","cluster":"prod-logs"')"
post "haproxy" /v1/ingest/vector "$(log_event haproxy lb-2 error 'backend api has no server available' ',"backend":"api","http_status":"503"')"
post "traefik" /v1/ingest/vector "$(log_event traefik edge-1 warn 'GET /api/orders 502' ',"http_method":"GET","http_path":"/api/orders","http_status":"502","router":"web@docker"')"
post "minio" /v1/ingest/vector "$(log_event minio s3-1 error 'Unable to read bucket policy' ',"api":"GetBucketPolicy","bucket":"backups"')"

echo "Smoke-testing metric ingest at $BASE/v1/ingest/prometheus"
post "prometheus-json" /v1/ingest/prometheus \
  "{\"timeseries\":[{\"labels\":{\"__name__\":\"smoke_test_metric\",\"job\":\"smoke\",\"host\":\"smoke-1\"},\"samples\":[{\"value\":1,\"timestamp\":$NOW_MS}]}]}"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures request(s) failed"
  exit 1
fi
echo "All ingest smoke checks passed"
