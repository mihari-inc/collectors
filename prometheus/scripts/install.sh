#!/usr/bin/env bash
#
# Mihari - Prometheus + node_exporter Setup
#
# Usage:
#   curl -fsSL https://YOUR_HOST/setup-prometheus/SOURCE_TOKEN | bash
#
# Or manually:
#   INGESTION_URL=https://platform.mihari.io SOURCE_TOKEN=xxx bash install.sh
#

set -euo pipefail

# --- Configuration (injected by server or set manually) ---
INGESTION_URL="${INGESTION_URL:-__INGESTION_URL__}"
SOURCE_TOKEN="${SOURCE_TOKEN:-__SOURCE_TOKEN__}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Validation ---
validate_config() {
    local errors=0
    local placeholder_prefix="__"
    local placeholder_suffix="__"

    if [[ "$INGESTION_URL" == "${placeholder_prefix}INGESTION_URL${placeholder_suffix}" || -z "$INGESTION_URL" ]]; then
        error "INGESTION_URL is not set. Export it or pass it via the setup URL."
        errors=$((errors + 1))
    fi

    if [[ "$SOURCE_TOKEN" == "${placeholder_prefix}SOURCE_TOKEN${placeholder_suffix}" || -z "$SOURCE_TOKEN" ]]; then
        error "SOURCE_TOKEN is not set. Export it or pass it via the setup URL."
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        echo ""
        echo "Usage:"
        echo "  INGESTION_URL=https://platform.mihari.io SOURCE_TOKEN=your_token bash install.sh"
        exit 1
    fi
}

# --- OS Detection ---
detect_os() {
    local uname_s
    uname_s=$(uname -s)

    case "$uname_s" in
        Linux)
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                case "$ID" in
                    ubuntu|debian|pop|linuxmint) echo "debian" ;;
                    centos|rhel|fedora|rocky|alma|amzn) echo "rhel" ;;
                    *) echo "linux-unknown" ;;
                esac
            elif [ -f /etc/debian_version ]; then
                echo "debian"
            elif [ -f /etc/redhat-release ]; then
                echo "rhel"
            else
                echo "linux-unknown"
            fi
            ;;
        Darwin) echo "macos" ;;
        *) echo "unknown" ;;
    esac
}

# --- Install node_exporter ---
install_node_exporter() {
    if systemctl is-active --quiet prometheus-node-exporter 2>/dev/null; then
        success "node_exporter is already running"
        return 0
    fi

    if command -v node_exporter &>/dev/null; then
        success "node_exporter is already installed"
        return 0
    fi

    local os
    os=$(detect_os)

    info "Installing node_exporter..."

    case "$os" in
        debian)
            sudo apt-get update -qq
            sudo apt-get install -y prometheus-node-exporter
            sudo systemctl enable prometheus-node-exporter
            sudo systemctl start prometheus-node-exporter
            ;;
        rhel)
            local version="1.8.2"
            local arch
            arch=$(uname -m)
            case "$arch" in
                x86_64) arch="amd64" ;;
                aarch64) arch="arm64" ;;
            esac
            local url="https://github.com/prometheus/node_exporter/releases/download/v${version}/node_exporter-${version}.linux-${arch}.tar.gz"
            local tmp_dir
            tmp_dir=$(mktemp -d)
            curl -fsSL "$url" | tar xz -C "$tmp_dir" --strip-components=1
            sudo mv "$tmp_dir/node_exporter" /usr/local/bin/
            rm -rf "$tmp_dir"

            sudo tee /etc/systemd/system/prometheus-node-exporter.service > /dev/null <<'UNIT'
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=nobody
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
            sudo systemctl daemon-reload
            sudo systemctl enable prometheus-node-exporter
            sudo systemctl start prometheus-node-exporter
            ;;
        *)
            error "Unsupported OS for node_exporter auto-install: $os"
            error "Install manually: https://github.com/prometheus/node_exporter"
            exit 1
            ;;
    esac

    sleep 2

    if curl -fsSL http://127.0.0.1:9100/metrics &>/dev/null; then
        success "node_exporter is running on :9100"
    else
        warn "node_exporter may not be responding yet. Check: curl http://127.0.0.1:9100/metrics"
    fi
}

# --- Install Prometheus ---
install_prometheus() {
    if command -v prometheus &>/dev/null || command -v /usr/bin/prometheus &>/dev/null; then
        local current_version
        current_version=$(prometheus --version 2>&1 | head -1 || echo "unknown")
        success "Prometheus is already installed: $current_version"
        return 0
    fi

    local os
    os=$(detect_os)

    info "Installing Prometheus..."

    case "$os" in
        debian)
            sudo apt-get update -qq
            sudo apt-get install -y prometheus
            ;;
        rhel)
            local version="2.53.3"
            local arch
            arch=$(uname -m)
            case "$arch" in
                x86_64) arch="amd64" ;;
                aarch64) arch="arm64" ;;
            esac
            local url="https://github.com/prometheus/prometheus/releases/download/v${version}/prometheus-${version}.linux-${arch}.tar.gz"
            local tmp_dir
            tmp_dir=$(mktemp -d)
            curl -fsSL "$url" | tar xz -C "$tmp_dir" --strip-components=1
            sudo mv "$tmp_dir/prometheus" /usr/local/bin/
            sudo mv "$tmp_dir/promtool" /usr/local/bin/
            sudo mkdir -p /etc/prometheus /var/lib/prometheus
            rm -rf "$tmp_dir"

            sudo useradd --no-create-home --shell /bin/false prometheus 2>/dev/null || true
            sudo chown -R prometheus:prometheus /var/lib/prometheus

            sudo tee /etc/systemd/system/prometheus.service > /dev/null <<'UNIT'
[Unit]
Description=Prometheus
After=network.target

[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus \
    --storage.tsdb.retention.time=2d \
    --web.listen-address=127.0.0.1:9090
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
            sudo systemctl daemon-reload
            ;;
        *)
            error "Unsupported OS for Prometheus auto-install: $os"
            error "Install manually: https://prometheus.io/download/"
            exit 1
            ;;
    esac

    success "Prometheus installed"
}

# --- Apply Prometheus Config ---
apply_config() {
    local config_path="/etc/prometheus/prometheus.yml"

    info "Configuring Prometheus with remote_write..."

    # Backup existing config
    if [ -f "$config_path" ]; then
        local backup="${config_path}.backup-$(date +%Y-%m-%d_%H-%M-%S)"
        warn "Backing up existing config to $backup"
        sudo cp "$config_path" "$backup"
    fi

    # Try to download config from Mihari
    local config_url="${INGESTION_URL}/setup-prometheus-config/${SOURCE_TOKEN}"
    local tmp_config
    tmp_config=$(mktemp)

    if curl -fsSL "$config_url" -o "$tmp_config" 2>/dev/null; then
        info "Downloaded config from Mihari"
    else
        warn "Could not download config from server, generating locally..."
        generate_local_config "$tmp_config"
    fi

    sudo mkdir -p /etc/prometheus
    sudo cp "$tmp_config" "$config_path"
    sudo chown prometheus:prometheus "$config_path" 2>/dev/null || true
    rm -f "$tmp_config"

    success "Config written to $config_path"
}

# --- Generate Local Config ---
generate_local_config() {
    local output_file="$1"

    cat > "$output_file" <<YAML
# Mihari Prometheus Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

global:
  scrape_interval: 30s
  evaluation_interval: 30s

scrape_configs:
  - job_name: "node"
    static_configs:
      - targets: ["127.0.0.1:9100"]

remote_write:
  - url: "${INGESTION_URL}/api/v1/ingest/metrics"
    authorization:
      type: Bearer
      credentials: "${SOURCE_TOKEN}"
YAML
}

# --- Start/Restart Prometheus ---
restart_prometheus() {
    info "Starting Prometheus..."

    sudo systemctl enable prometheus
    sudo systemctl restart prometheus

    sleep 2

    if systemctl is-active --quiet prometheus 2>/dev/null; then
        success "Prometheus is running"
    else
        warn "Prometheus may not have started. Check: journalctl -u prometheus -f"
    fi
}

# --- Main ---
main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║    Mihari - Prometheus Collector Setup    ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════╝${NC}"
    echo ""

    validate_config

    info "Ingestion URL:  $INGESTION_URL"
    info "Source Token:   ${SOURCE_TOKEN:0:8}..."
    echo ""

    install_node_exporter
    install_prometheus
    apply_config
    restart_prometheus

    echo ""
    success "Setup complete!"
    echo ""
    info "Prometheus is scraping node_exporter and sending metrics to Mihari via remote_write."
    info "Config: /etc/prometheus/prometheus.yml"
    echo ""
    info "Useful commands:"
    info "  curl http://127.0.0.1:9090/-/healthy     # Prometheus health"
    info "  curl http://127.0.0.1:9100/metrics        # node_exporter metrics"
    info "  journalctl -u prometheus -f               # Prometheus logs"
    echo ""
}

main "$@"
