#!/usr/bin/env bash
set -euo pipefail

# Mihari eBPF Collector — Install Script
# Usage: curl -sSL <url>/setup-ebpf/<token> | bash

INGESTION_URL="__INGESTION_URL__"
SOURCE_TOKEN="__SOURCE_TOKEN__"

echo "==> Installing Mihari eBPF Collector (Grafana Beyla)"
echo "    Target: ${INGESTION_URL}"

if ! command -v docker &>/dev/null; then
  echo "ERROR: docker is not installed. Install Docker first."
  exit 1
fi

# Stop existing container if running
docker rm -f mihari-ebpf 2>/dev/null || true

# Check kernel support
KERNEL_VERSION=$(uname -r | cut -d. -f1)
if [ "$KERNEL_VERSION" -lt 5 ]; then
  echo "WARNING: eBPF requires Linux kernel >= 5.8. Current: $(uname -r)"
  echo "         The collector may not work correctly."
fi

# Run the collector
docker run -d \
  --name mihari-ebpf \
  --restart unless-stopped \
  --privileged \
  --pid host \
  --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:rw \
  -v /sys/kernel/tracing:/sys/kernel/tracing:rw \
  -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -e BEYLA_OTEL_EXPORTER_OTLP_ENDPOINT="${INGESTION_URL}/v1/ingest/otlp/v1/traces" \
  -e OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer ${SOURCE_TOKEN}" \
  -m 512m \
  ghcr.io/mihari-inc/ebpf-collector:latest

echo ""
echo "==> Mihari eBPF Collector is running!"
echo "    Container: mihari-ebpf"
echo "    Logs:      docker logs -f mihari-ebpf"
echo "    Stop:      docker stop mihari-ebpf"
echo ""
echo "    Services will appear in your Mihari Service Map within ~60 seconds."
