#!/usr/bin/env bash
#
# Mihari Collector — Standalone Docker run (two containers)
#
# Usage:
#   INGESTION_URL=https://app.mihari.io SOURCE_TOKEN=xxx bash docker-run.sh
#

set -euo pipefail

INGESTION_URL="${INGESTION_URL:-__INGESTION_URL__}"
SOURCE_TOKEN="${SOURCE_TOKEN:-__SOURCE_TOKEN__}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Starting Mihari Collector..."
echo "  Ingestion URL: ${INGESTION_URL}"
echo "  Source Token:   ${SOURCE_TOKEN:0:8}..."

# Ensure sysctl for conntrack
if [ -f /proc/sys/net/netfilter/nf_conntrack_events ]; then
  current=$(cat /proc/sys/net/netfilter/nf_conntrack_events)
  if [ "$current" != "1" ]; then
    echo "Setting nf_conntrack_events=1..."
    sudo sysctl -w net.netfilter.nf_conntrack_events=1 2>/dev/null || true
  fi
fi

# Start Vector collector (receives from coroot, ships to Mihari)
docker rm -f mihari-collector 2>/dev/null || true
docker run -d \
  --name mihari-collector \
  --restart unless-stopped \
  --network host \
  -v "${SCRIPT_DIR}/../vector.yaml:/etc/vector/vector.yaml:ro" \
  -e "INGESTION_URL=${INGESTION_URL}" \
  -e "SOURCE_TOKEN=${SOURCE_TOKEN}" \
  -e "VECTOR_LOG=info" \
  timberio/vector:0.47.0-distroless-libc

# Start coroot-node-agent (eBPF → sends to local Vector)
docker rm -f mihari-ebpf 2>/dev/null || true
docker run -d \
  --name mihari-ebpf \
  --restart unless-stopped \
  --privileged \
  --pid host \
  --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:rw \
  -v /sys/kernel/tracing:/sys/kernel/tracing:rw \
  -v /sys/fs/cgroup:/host/sys/fs/cgroup:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -e "GOMEMLIMIT=512MiB" \
  ghcr.io/coroot/coroot-node-agent:latest \
    --cgroupfs-root=/host/sys/fs/cgroup \
    --metrics-endpoint=http://127.0.0.1:9090 \
    --traces-endpoint=http://127.0.0.1:4318

echo ""
echo "Mihari Collector started!"
echo "  mihari-ebpf:      eBPF agent (coroot-node-agent)"
echo "  mihari-collector:  Vector pipeline → ${INGESTION_URL}"
echo ""
echo "Logs:"
echo "  docker logs -f mihari-ebpf"
echo "  docker logs -f mihari-collector"
