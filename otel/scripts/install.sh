#!/usr/bin/env bash
#
# Mihari - OpenTelemetry Collector Setup
#
# Usage:
#   curl -fsSL https://YOUR_HOST/setup-otel/TECHNOLOGY/SOURCE_TOKEN | bash
#
# Or manually:
#   INGESTION_URL=https://platform.mihari.io SOURCE_TOKEN=xxx TECHNOLOGY=postgresql bash install.sh
#

set -euo pipefail

# --- Configuration (injected by server or set manually) ---
INGESTION_URL="${INGESTION_URL:-__INGESTION_URL__}"
SOURCE_TOKEN="${SOURCE_TOKEN:-__SOURCE_TOKEN__}"
TECHNOLOGY="${TECHNOLOGY:-__TECHNOLOGY__}"

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
        error "INGESTION_URL is not set."
        errors=$((errors + 1))
    fi

    if [[ "$SOURCE_TOKEN" == "${placeholder_prefix}SOURCE_TOKEN${placeholder_suffix}" || -z "$SOURCE_TOKEN" ]]; then
        error "SOURCE_TOKEN is not set."
        errors=$((errors + 1))
    fi

    if [[ "$TECHNOLOGY" == "${placeholder_prefix}TECHNOLOGY${placeholder_suffix}" || -z "$TECHNOLOGY" ]]; then
        error "TECHNOLOGY is not set."
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        echo ""
        echo "Usage:"
        echo "  INGESTION_URL=https://platform.mihari.io SOURCE_TOKEN=your_token TECHNOLOGY=postgresql bash install.sh"
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
            elif [ -f /etc/debian_version ]; then echo "debian"
            elif [ -f /etc/redhat-release ]; then echo "rhel"
            else echo "linux-unknown"
            fi
            ;;
        Darwin) echo "macos" ;;
        *) echo "unknown" ;;
    esac
}

# --- Install OpenTelemetry Collector Contrib ---
install_otel() {
    if command -v otelcol-contrib &>/dev/null; then
        local current_version
        current_version=$(otelcol-contrib --version 2>/dev/null | head -1)
        success "OpenTelemetry Collector Contrib already installed: $current_version"
        return 0
    fi

    local os
    os=$(detect_os)
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
    esac

    # Latest stable version
    local version="0.96.0"
    info "Installing OpenTelemetry Collector Contrib v${version} on ${os}/${arch}..."

    case "$os" in
        debian)
            local deb_url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${version}/otelcol-contrib_${version}_linux_${arch}.deb"
            local tmp_deb
            tmp_deb=$(mktemp /tmp/otelcol-contrib.XXXXXX.deb)
            info "Downloading from GitHub releases..."
            curl -fsSL "$deb_url" -o "$tmp_deb"
            sudo dpkg -i "$tmp_deb"
            rm -f "$tmp_deb"
            ;;
        rhel)
            local rpm_url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${version}/otelcol-contrib_${version}_linux_${arch}.rpm"
            local tmp_rpm
            tmp_rpm=$(mktemp /tmp/otelcol-contrib.XXXXXX.rpm)
            info "Downloading from GitHub releases..."
            curl -fsSL "$rpm_url" -o "$tmp_rpm"
            sudo rpm -ivh "$tmp_rpm"
            rm -f "$tmp_rpm"
            ;;
        macos)
            if command -v brew &>/dev/null; then
                brew install open-telemetry/opentelemetry-collector/otelcol-contrib
            else
                local tar_url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${version}/otelcol-contrib_${version}_darwin_${arch}.tar.gz"
                local tmp_tar
                tmp_tar=$(mktemp /tmp/otelcol-contrib.XXXXXX.tar.gz)
                curl -fsSL "$tar_url" -o "$tmp_tar"
                sudo tar -xzf "$tmp_tar" -C /usr/local/bin otelcol-contrib
                rm -f "$tmp_tar"
            fi
            ;;
        *)
            error "Unsupported OS. Install manually: https://opentelemetry.io/docs/collector/installation/"
            exit 1
            ;;
    esac

    success "OpenTelemetry Collector Contrib installed"
}

# --- Apply Config ---
apply_config() {
    local os
    os=$(detect_os)
    local config_dir="/etc/otelcol-contrib"
    local config_path="${config_dir}/config.yaml"

    if [[ "$os" == "macos" ]]; then
        config_dir="/opt/homebrew/etc/otelcol-contrib"
        config_path="${config_dir}/config.yaml"
    fi

    info "Configuring OpenTelemetry Collector for $TECHNOLOGY..."

    # Backup existing
    if [ -f "$config_path" ]; then
        local backup="${config_path}.backup-$(date +%Y-%m-%d_%H-%M-%S)"
        warn "Backing up existing config to $backup"
        sudo cp "$config_path" "$backup"
    fi

    # Try remote config first
    local config_url="${INGESTION_URL}/setup-otel-config/${TECHNOLOGY}/${SOURCE_TOKEN}"
    local tmp_config
    tmp_config=$(mktemp)

    if curl -fsSL "$config_url" -o "$tmp_config" 2>/dev/null; then
        info "Downloaded config from Mihari"
    else
        warn "Could not download config from server, generating locally..."
        generate_local_config "$tmp_config"
    fi

    sudo mkdir -p "$config_dir"
    sudo cp "$tmp_config" "$config_path"
    rm -f "$tmp_config"

    success "Config written to $config_path"
}

# --- Generate Local Config ---
generate_local_config() {
    local output_file="$1"

    cat > "$output_file" << YAML
# Mihari OpenTelemetry Collector Configuration
# Technology: ${TECHNOLOGY}
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

receivers:
  filelog:
    include:
$(get_otel_log_paths "$TECHNOLOGY")
    start_at: beginning
    operators:
      - type: regex_parser
        if: 'body matches "(?i)(ERROR|WARN|WARNING|INFO|DEBUG|CRITICAL|FATAL)"'
        regex: '(?i)(?P<level>ERROR|WARN|WARNING|INFO|DEBUG|CRITICAL|FATAL)'
        parse_to: attributes
        on_error: send

  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu: {}
      disk: {}
      filesystem: {}
      load: {}
      memory: {}
      network: {}
      process: {}

  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
      http:
        endpoint: "0.0.0.0:4318"

processors:
  batch:
    send_batch_size: 1024
    timeout: 1s

  attributes/add_source:
    actions:
      - key: service.name
        value: "${TECHNOLOGY}"
        action: upsert
      - key: source_token
        value: "${SOURCE_TOKEN}"
        action: upsert

  resourcedetection:
    detectors: [env, system]
    system:
      hostname_sources: ["os"]

extensions:
  health_check:
    endpoint: "0.0.0.0:13133"

exporters:
  otlphttp/logs:
    endpoint: "${INGESTION_URL}/otel"
    headers:
      Authorization: "Bearer ${SOURCE_TOKEN}"
    compression: gzip

  otlphttp/metrics:
    endpoint: "${INGESTION_URL}/otel"
    headers:
      Authorization: "Bearer ${SOURCE_TOKEN}"
    compression: gzip

  otlphttp/traces:
    endpoint: "${INGESTION_URL}/otel"
    headers:
      Authorization: "Bearer ${SOURCE_TOKEN}"
    compression: gzip

service:
  extensions: [health_check]
  pipelines:
    logs:
      receivers: [filelog, otlp]
      processors: [batch, attributes/add_source, resourcedetection]
      exporters: [otlphttp/logs]
    metrics:
      receivers: [hostmetrics, otlp]
      processors: [batch, attributes/add_source, resourcedetection]
      exporters: [otlphttp/metrics]
    traces:
      receivers: [otlp]
      processors: [batch, attributes/add_source, resourcedetection]
      exporters: [otlphttp/traces]
YAML
}

# --- Log Paths per Technology ---
get_otel_log_paths() {
    case "$1" in
        postgresql)
            echo '      - "/var/log/postgresql/*.log"'
            echo '      - "/var/lib/postgresql/*/main/log/*.log"'
            ;;
        mysql)
            echo '      - "/var/log/mysql/*.log"'
            echo '      - "/var/log/mysql/error.log"'
            echo '      - "/var/log/mysql/slow-query.log"'
            ;;
        nginx)
            echo '      - "/var/log/nginx/access.log"'
            echo '      - "/var/log/nginx/error.log"'
            ;;
        apache)
            echo '      - "/var/log/apache2/*.log"'
            echo '      - "/var/log/httpd/*.log"'
            ;;
        rabbitmq)
            echo '      - "/var/log/rabbitmq/*.log"'
            ;;
        elasticsearch)
            echo '      - "/var/log/elasticsearch/*.log"'
            echo '      - "/var/log/elasticsearch/*_server.json"'
            ;;
        mongodb)
            echo '      - "/var/log/mongodb/mongod.log"'
            echo '      - "/var/log/mongodb/*.log"'
            ;;
        traefik)
            echo '      - "/var/log/traefik/*.log"'
            ;;
        haproxy)
            echo '      - "/var/log/haproxy.log"'
            echo '      - "/var/log/haproxy/*.log"'
            ;;
        minio)
            echo '      - "/var/log/minio/*.log"'
            ;;
        docker)
            echo '      - "/var/lib/docker/containers/*/*.log"'
            ;;
        kubernetes)
            echo '      - "/var/log/pods/*/*.log"'
            echo '      - "/var/log/containers/*.log"'
            ;;
        *)
            echo '      - "/var/log/*.log"'
            ;;
    esac
}

# --- Start/Restart OTEL Collector ---
restart_otel() {
    local os
    os=$(detect_os)

    info "Starting OpenTelemetry Collector..."

    case "$os" in
        macos)
            brew services restart otelcol-contrib 2>/dev/null || brew services start otelcol-contrib
            ;;
        *)
            sudo systemctl enable otelcol-contrib
            sudo systemctl restart otelcol-contrib
            ;;
    esac

    sleep 2

    if command -v systemctl &>/dev/null && systemctl is-active --quiet otelcol-contrib 2>/dev/null; then
        success "OpenTelemetry Collector is running"
    elif pgrep -x otelcol-contrib &>/dev/null; then
        success "OpenTelemetry Collector is running"
    else
        warn "OTEL Collector may not have started. Check: journalctl -u otelcol-contrib -f"
    fi
}

# --- Main ---
main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Mihari - OpenTelemetry Collector Setup         ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""

    validate_config

    info "Technology:     $TECHNOLOGY"
    info "Ingestion URL:  $INGESTION_URL"
    info "Source Token:   ${SOURCE_TOKEN:0:8}..."
    echo ""

    install_otel
    apply_config
    restart_otel

    echo ""
    success "Setup complete!"
    echo ""
    info "OTEL Collector is now collecting ${TECHNOLOGY} telemetry and sending it to Mihari."
    info "OTLP endpoints available at:"
    info "  gRPC: localhost:4317"
    info "  HTTP: localhost:4318"
    info "Health check: http://localhost:13133"
    echo ""
}

main "$@"
