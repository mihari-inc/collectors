# Mihari Collector — Vector-based data pipeline for coroot-node-agent
# Receives eBPF metrics + traces, transforms, and ships to Mihari API
#
# Build: docker build -t mihari-collector .
# See docker-compose.yaml for full usage with coroot-node-agent

FROM timberio/vector:0.47.0-distroless-libc

COPY vector.yaml /etc/vector/vector.yaml

ENTRYPOINT ["vector"]
CMD ["--config", "/etc/vector/vector.yaml"]
