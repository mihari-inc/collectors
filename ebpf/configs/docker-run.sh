#!/usr/bin/env bash
# Mihari eBPF Collector — Single Docker run command
#
# Variables:
#   __INGESTION_URL__ — Your Mihari instance URL
#   __SOURCE_TOKEN__  — Bearer token for authentication

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
  -e BEYLA_OTEL_EXPORTER_OTLP_ENDPOINT="__INGESTION_URL__" \
  -e OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer __SOURCE_TOKEN__" \
  -m 512m \
  ghcr.io/mihari-inc/ebpf-collector:latest
