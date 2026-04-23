#!/usr/bin/env bash
#
# Mihari Collector — Bare Metal Install
# Installs both Vector (collector) and coroot-node-agent (eBPF) as systemd services.
#
# Usage:
#   curl -fsSL https://YOUR_HOST/setup-coroot/SOURCE_TOKEN | bash
# Or:
#   INGESTION_URL=https://app.mihari.io SOURCE_TOKEN=xxx bash install.sh
#

set -euo pipefail

INGESTION_URL="${INGESTION_URL:-__INGESTION_URL__}"
SOURCE_TOKEN="${SOURCE_TOKEN:-__SOURCE_TOKEN__}"

VECTOR_VERSION="0.47.0"
COROOT_NODE_AGENT_ARCH=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Validation ──
validate_config() {
    local errors=0
    if [[ "$INGESTION_URL" == __*__ || -z "$INGESTION_URL" ]]; then
        error "INGESTION_URL is not set."
        errors=$((errors + 1))
    fi
    if [[ "$SOURCE_TOKEN" == __*__ || -z "$SOURCE_TOKEN" ]]; then
        error "SOURCE_TOKEN is not set."
        errors=$((errors + 1))
    fi
    if [[ $errors -gt 0 ]]; then
        echo "Usage: INGESTION_URL=https://app.mihari.io SOURCE_TOKEN=your_token bash install.sh"
        exit 1
    fi
}

# ── OS Detection ──
detect_os() {
    case "$(uname -s)" in
        Linux)
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                case "$ID" in
                    ubuntu|debian|pop|linuxmint) echo "debian" ;;
                    centos|rhel|fedora|rocky|alma|amzn) echo "rhel" ;;
                    *) echo "linux-unknown" ;;
                esac
            else echo "linux-unknown"
            fi ;;
        *) echo "unknown" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "unknown" ;;
    esac
}

# ── Kernel check ──
check_kernel() {
    local major minor
    major=$(uname -r | cut -d. -f1)
    minor=$(uname -r | cut -d. -f2)
    if [[ "$major" -lt 5 ]] || { [[ "$major" -eq 5 ]] && [[ "$minor" -lt 1 ]]; }; then
        error "Kernel $(uname -r) too old. eBPF requires >= 5.1."
        exit 1
    fi
    success "Kernel $(uname -r) supports eBPF"
}

# ── Sysctl ──
configure_sysctl() {
    if [ -f /proc/sys/net/netfilter/nf_conntrack_events ]; then
        local current
        current=$(cat /proc/sys/net/netfilter/nf_conntrack_events)
        if [ "$current" != "1" ]; then
            info "Setting nf_conntrack_events=1..."
            sudo sysctl -w net.netfilter.nf_conntrack_events=1
            echo "net.netfilter.nf_conntrack_events=1" | sudo tee -a /etc/sysctl.d/99-mihari-collector.conf > /dev/null
        fi
    fi
}

# ── Install Vector ──
install_vector() {
    if command -v vector &>/dev/null; then
        success "Vector already installed: $(vector --version 2>/dev/null | head -1)"
        return 0
    fi

    local os arch
    os=$(detect_os)
    arch=$(detect_arch)

    info "Installing Vector v${VECTOR_VERSION}..."
    case "$os" in
        debian)
            curl -fsSL https://apt.vector.dev/setup.sh | sudo bash
            sudo apt-get install -y vector="${VECTOR_VERSION}-1"
            ;;
        rhel)
            curl -fsSL https://yum.vector.dev/setup.sh | sudo bash
            sudo yum install -y "vector-${VECTOR_VERSION}-1"
            ;;
        *)
            local url="https://github.com/vectordotdev/vector/releases/download/v${VECTOR_VERSION}/vector-${VECTOR_VERSION}-${arch}-unknown-linux-gnu.tar.gz"
            local tmp; tmp=$(mktemp /tmp/vector.XXXXXX.tar.gz)
            curl -fsSL "$url" -o "$tmp"
            sudo tar -xzf "$tmp" -C /usr/local/bin --strip-components=2 "vector-${arch}-unknown-linux-gnu/bin/vector"
            rm -f "$tmp"
            ;;
    esac
    success "Vector installed"
}

# ── Install coroot-node-agent ──
install_coroot() {
    if command -v coroot-node-agent &>/dev/null; then
        success "coroot-node-agent already installed"
        return 0
    fi

    local arch; arch=$(detect_arch)
    info "Downloading coroot-node-agent for linux/${arch}..."

    local latest_url="https://api.github.com/repos/coroot/coroot-node-agent/releases/latest"
    local download_url
    download_url=$(curl -fsSL "$latest_url" | grep "browser_download_url.*linux.*${arch}" | head -1 | cut -d'"' -f4)

    if [[ -z "$download_url" ]]; then
        error "Could not find coroot-node-agent release for linux/${arch}."
        exit 1
    fi

    local tmp; tmp=$(mktemp /tmp/coroot-node-agent.XXXXXX)
    curl -fsSL "$download_url" -o "$tmp"
    chmod +x "$tmp"
    sudo mv "$tmp" /usr/local/bin/coroot-node-agent
    success "coroot-node-agent installed"
}

# ── Configure Vector ──
configure_vector() {
    info "Writing Vector config..."

    sudo mkdir -p /etc/vector
    sudo tee /etc/vector/vector.yaml > /dev/null << VECTORCFG
api:
  enabled: true
  address: "0.0.0.0:8686"

sources:
  coroot_metrics:
    type: prometheus_remote_write
    address: "0.0.0.0:9090"
  coroot_traces:
    type: opentelemetry
    grpc:
      address: "0.0.0.0:4317"
    http:
      address: "0.0.0.0:4318"

transforms:
  metrics_enriched:
    type: remap
    inputs: ["coroot_metrics"]
    source: |
      container_id = get(.tags.container_id) ?? ""
      if container_id != "" {
        clean_name = container_id
        clean_name = replace(clean_name, r'^/docker/', "")
        clean_name = replace(clean_name, r'^/system\\.slice/', "")
        clean_name = replace(clean_name, r'\\.service\$', "")
        clean_name = replace(clean_name, r'\\.scope\$', "")
        clean_name = replace(clean_name, r'-\\d+\$', "")
        .tags.service_name = clean_name
      }
  traces_enriched:
    type: remap
    inputs: ["coroot_traces.traces"]
    source: |
      svc = get(.resource."service.name") ?? ""
      if svc != "" {
        clean = svc
        clean = replace(clean, r'^/docker/', "")
        clean = replace(clean, r'^/system\\.slice/', "")
        clean = replace(clean, r'\\.service\$', "")
        clean = replace(clean, r'\\.scope\$', "")
        clean = replace(clean, r'-\\d+\$', "")
        .resource."service.name" = clean
      }

sinks:
  mihari_metrics:
    type: prometheus_remote_write
    inputs: ["metrics_enriched"]
    endpoint: "${INGESTION_URL}/api/prom/v1/write"
    auth:
      strategy: "bearer"
      token: "${SOURCE_TOKEN}"
    batch:
      max_bytes: 1048576
      timeout_secs: 5
  mihari_traces:
    type: http
    inputs: ["traces_enriched"]
    uri: "${INGESTION_URL}/api/otel/v1/traces"
    method: post
    encoding:
      codec: json
    headers:
      Authorization: "Bearer ${SOURCE_TOKEN}"
      Content-Type: "application/json"
    compression: gzip
    batch:
      max_bytes: 1048576
      timeout_secs: 5
VECTORCFG

    success "Vector config written to /etc/vector/vector.yaml"
}

# ── Create systemd services ──
create_services() {
    info "Creating systemd services..."

    # coroot-node-agent service
    sudo tee /etc/systemd/system/mihari-ebpf.service > /dev/null << EOF
[Unit]
Description=Mihari eBPF Agent (coroot-node-agent)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/coroot-node-agent \\
  --cgroupfs-root=/sys/fs/cgroup \\
  --metrics-endpoint=http://127.0.0.1:9090 \\
  --traces-endpoint=http://127.0.0.1:4318
Restart=always
RestartSec=5
LimitNOFILE=65535
AmbientCapabilities=CAP_SYS_ADMIN CAP_NET_ADMIN CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
Environment=GOMEMLIMIT=512MiB

[Install]
WantedBy=multi-user.target
EOF

    # Vector collector service (override default if exists)
    sudo tee /etc/systemd/system/mihari-collector.service > /dev/null << EOF
[Unit]
Description=Mihari Collector (Vector)
After=network-online.target mihari-ebpf.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/vector --config /etc/vector/vector.yaml
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    success "Systemd services created"
}

# ── Start services ──
start_services() {
    info "Starting services..."

    sudo systemctl enable mihari-ebpf mihari-collector
    sudo systemctl restart mihari-ebpf
    sleep 2
    sudo systemctl restart mihari-collector

    sleep 2
    for svc in mihari-ebpf mihari-collector; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            success "$svc is running"
        else
            warn "$svc may not have started. Check: journalctl -u $svc -f"
        fi
    done
}

# ── Main ──
main() {
    echo ""
    echo -e "${BLUE}+───────────────────────────────────────────────+${NC}"
    echo -e "${BLUE}│   Mihari Collector Setup (eBPF + Vector)      │${NC}"
    echo -e "${BLUE}+───────────────────────────────────────────────+${NC}"
    echo ""

    validate_config

    info "Ingestion URL: $INGESTION_URL"
    info "Source Token:  ${SOURCE_TOKEN:0:8}..."
    echo ""

    check_kernel
    configure_sysctl
    install_vector
    install_coroot
    configure_vector
    create_services
    start_services

    echo ""
    success "Mihari Collector installed!"
    echo ""
    info "Services:"
    info "  mihari-ebpf:      coroot-node-agent (eBPF → localhost:9090/4318)"
    info "  mihari-collector:  Vector pipeline (→ ${INGESTION_URL})"
    echo ""
    info "Management:"
    info "  Status:  sudo systemctl status mihari-ebpf mihari-collector"
    info "  Logs:    journalctl -u mihari-ebpf -f"
    info "           journalctl -u mihari-collector -f"
    info "  Restart: sudo systemctl restart mihari-ebpf mihari-collector"
    echo ""
}

main "$@"
