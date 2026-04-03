#!/usr/bin/env bash
#
# Mihari - Vector Collector Setup
#
# Usage:
#   curl -fsSL https://YOUR_HOST/setup-vector/TECHNOLOGY/SOURCE_TOKEN | bash
#
# Or manually:
#   INGESTION_URL=https://app.mihari.io SOURCE_TOKEN=xxx TECHNOLOGY=postgresql bash install.sh
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
        error "INGESTION_URL is not set. Export it or pass it via the setup URL."
        errors=$((errors + 1))
    fi

    if [[ "$SOURCE_TOKEN" == "${placeholder_prefix}SOURCE_TOKEN${placeholder_suffix}" || -z "$SOURCE_TOKEN" ]]; then
        error "SOURCE_TOKEN is not set. Export it or pass it via the setup URL."
        errors=$((errors + 1))
    fi

    if [[ "$TECHNOLOGY" == "${placeholder_prefix}TECHNOLOGY${placeholder_suffix}" || -z "$TECHNOLOGY" ]]; then
        error "TECHNOLOGY is not set. Export it or pass it via the setup URL."
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        echo ""
        echo "Usage:"
        echo "  INGESTION_URL=https://app.mihari.io SOURCE_TOKEN=your_token TECHNOLOGY=postgresql bash install.sh"
        exit 1
    fi
}

# --- OS Detection ---
detect_os() {
    local os=""
    local uname_s
    uname_s=$(uname -s)

    case "$uname_s" in
        Linux)
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                case "$ID" in
                    ubuntu|debian|pop|linuxmint) os="debian" ;;
                    centos|rhel|fedora|rocky|alma|amzn) os="rhel" ;;
                    *) os="linux-unknown" ;;
                esac
            elif [ -f /etc/debian_version ]; then
                os="debian"
            elif [ -f /etc/redhat-release ]; then
                os="rhel"
            else
                os="linux-unknown"
            fi
            ;;
        Darwin) os="macos" ;;
        *) os="unknown" ;;
    esac

    echo "$os"
}

# --- Install node_exporter (for prometheus technology) ---
install_node_exporter() {
    if [[ "$TECHNOLOGY" != "prometheus" ]]; then
        return 0
    fi

    if command -v node_exporter &>/dev/null || systemctl is-active --quiet prometheus-node-exporter 2>/dev/null; then
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
            sudo yum install -y golang-github-prometheus-node-exporter || {
                # Fallback: install from binary
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

                # Create systemd unit
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
            }
            ;;
        macos)
            if command -v brew &>/dev/null; then
                brew install node_exporter
                brew services start node_exporter
            else
                error "Homebrew is required on macOS to install node_exporter"
                return 1
            fi
            ;;
        *)
            warn "Could not auto-install node_exporter on this OS"
            warn "Install it manually: https://github.com/prometheus/node_exporter"
            return 0
            ;;
    esac

    sleep 2

    if curl -fsSL http://127.0.0.1:9100/metrics &>/dev/null; then
        success "node_exporter is running on :9100"
    else
        warn "node_exporter may not be responding yet. Check: curl http://127.0.0.1:9100/metrics"
    fi
}

# --- Install Vector ---
install_vector() {
    local os
    os=$(detect_os)

    if command -v vector &>/dev/null; then
        local current_version
        current_version=$(vector --version 2>/dev/null | head -1)
        success "Vector is already installed: $current_version"
        return 0
    fi

    info "Installing Vector on $os..."

    case "$os" in
        debian)
            info "Adding Vector APT repository..."
            bash -c "$(curl -fsSL https://setup.vector.dev)"
            sudo apt-get install -y vector
            ;;
        rhel)
            info "Adding Vector YUM repository..."
            bash -c "$(curl -fsSL https://setup.vector.dev)"
            sudo yum install -y vector
            ;;
        macos)
            if ! command -v brew &>/dev/null; then
                error "Homebrew is required on macOS. Install it: https://brew.sh"
                exit 1
            fi
            info "Installing Vector via Homebrew..."
            brew install vector
            ;;
        *)
            error "Unsupported OS: $os"
            error "Install Vector manually: https://vector.dev/docs/setup/installation/"
            exit 1
            ;;
    esac

    success "Vector installed successfully"
}

# --- Download & Apply Config ---
apply_config() {
    local os
    os=$(detect_os)
    local config_dir config_path

    case "$os" in
        macos)
            config_dir="/opt/homebrew/etc/vector"
            ;;
        *)
            config_dir="/etc/vector"
            ;;
    esac

    config_path="$config_dir/vector.yaml"

    info "Configuring Vector for $TECHNOLOGY..."

    # Backup existing config
    if [ -f "$config_path" ]; then
        local backup="${config_path}.backup-$(date +%Y-%m-%d_%H-%M-%S)"
        warn "Backing up existing config to $backup"
        sudo cp "$config_path" "$backup"
    fi

    # Try to download config from Mihari, or use bundled template
    local config_url="${INGESTION_URL}/setup-vector-config/${TECHNOLOGY}/${SOURCE_TOKEN}"
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

    if [[ "$TECHNOLOGY" == "prometheus" ]]; then
        generate_prometheus_config "$output_file"
    else
        generate_standard_config "$output_file"
    fi
}

generate_prometheus_config() {
    local output_file="$1"

    cat > "$output_file" <<YAML
# Mihari Vector Configuration - Prometheus
# Technology: prometheus
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

api:
  enabled: true
  address: "127.0.0.1:8686"

sources:
  mihari_prometheus_scrape:
    type: prometheus_scrape
    endpoints:
      - "http://127.0.0.1:9100/metrics"
    scrape_interval_secs: 30

  mihari_host_metrics:
    type: host_metrics
    collectors: [cpu, disk, filesystem, load, host, memory, network]
    scrape_interval_secs: 30
    filesystem:
      devices:
        excludes: ["overlay*", "tmpfs", "nsfs"]
      filesystems:
        excludes: ["overlay", "tmpfs", "nsfs"]
      mountpoints:
        excludes: ["/var/lib/docker/*"]

transforms:
  mihari_metrics_to_logs:
    type: metric_to_log
    inputs:
      - mihari_prometheus_scrape
      - mihari_host_metrics

  mihari_metrics_formatter:
    type: remap
    inputs:
      - mihari_metrics_to_logs
    source: |
      del(.source_type)
      .dt = del(.timestamp)

sinks:
  mihari_metrics_sink:
    type: http
    inputs:
      - mihari_metrics_formatter
    uri: "${INGESTION_URL}/api/v1/ingest/metrics"
    method: post
    encoding:
      codec: json
    compression: gzip
    auth:
      strategy: bearer
      token: "${SOURCE_TOKEN}"
    batch:
      max_bytes: 1048576
      timeout_secs: 5
YAML
}

generate_standard_config() {
    local output_file="$1"

    cat > "$output_file" <<YAML
# Mihari Vector Configuration
# Technology: ${TECHNOLOGY}
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

api:
  enabled: true
  address: "127.0.0.1:8686"

sources:
  mihari_${TECHNOLOGY}_logs:
    type: file
    include:
$(get_log_paths "$TECHNOLOGY")
    read_from: beginning
    ignore_older_secs: 600

  mihari_host_metrics:
    type: host_metrics
    collectors: [cpu, disk, filesystem, load, host, memory, network]
    scrape_interval_secs: 30
    filesystem:
      devices:
        excludes: ["overlay*", "tmpfs", "nsfs"]
      filesystems:
        excludes: ["overlay", "tmpfs", "nsfs"]
      mountpoints:
        excludes: ["/var/lib/docker/*"]

transforms:
  mihari_${TECHNOLOGY}_parser:
    type: remap
    inputs:
      - mihari_${TECHNOLOGY}_logs
    source: |
      del(.source_type)
      .dt = del(.timestamp)
$(get_parser_vrl "$TECHNOLOGY")

  mihari_metrics_to_logs:
    type: metric_to_log
    inputs:
      - mihari_host_metrics

  mihari_metrics_formatter:
    type: remap
    inputs:
      - mihari_metrics_to_logs
    source: |
      del(.source_type)
      .dt = del(.timestamp)

sinks:
  mihari_logs_sink:
    type: http
    inputs:
      - mihari_${TECHNOLOGY}_parser
    uri: "${INGESTION_URL}/api/v1/ingest/logs"
    method: post
    encoding:
      codec: json
    compression: gzip
    auth:
      strategy: bearer
      token: "${SOURCE_TOKEN}"
    batch:
      max_bytes: 1048576
      timeout_secs: 1

  mihari_metrics_sink:
    type: http
    inputs:
      - mihari_metrics_formatter
    uri: "${INGESTION_URL}/api/v1/ingest/metrics"
    method: post
    encoding:
      codec: json
    compression: gzip
    auth:
      strategy: bearer
      token: "${SOURCE_TOKEN}"
    batch:
      max_bytes: 1048576
      timeout_secs: 5
YAML
}

# --- Log Paths per Technology ---
get_log_paths() {
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

# --- VRL Parser per Technology ---
get_parser_vrl() {
    case "$1" in
        postgresql)
            cat <<'VRL'
      # Parse PostgreSQL log format
      parsed, err = parse_regex(.message, r'^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ \w+) \[(?P<pid>\d+)\] (?:(?P<user>\w+)@(?P<database>\w+) )?(?P<level>\w+):  (?P<msg>.*)')
      if err == null {
        .level = downcase!(parsed.level ?? "info")
        .postgresql_pid = parsed.pid
        .postgresql_user = parsed.user
        .postgresql_database = parsed.database
        .message = parsed.msg ?? .message
      }
VRL
            ;;
        mysql)
            cat <<'VRL'
      # Parse MySQL log format
      parsed, err = parse_regex(.message, r'^(?P<timestamp>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z) (?P<thread>\d+) \[(?P<level>\w+)\] (?:\[(?P<code>\w+)\] \[(?P<subsystem>\w+)\] )?(?P<msg>.*)')
      if err == null {
        .level = downcase!(parsed.level ?? "info")
        .mysql_thread = parsed.thread
        .message = parsed.msg ?? .message
      }
VRL
            ;;
        nginx)
            cat <<'VRL'
      # Parse Nginx combined log format
      parsed, err = parse_nginx_log(.message, "combined")
      if err == null {
        .level = if parsed.status != null && to_int(parsed.status) ?? 200 >= 500 { "error" } else if to_int(parsed.status) ?? 200 >= 400 { "warning" } else { "info" }
        .http_method = parsed.method
        .http_path = parsed.path
        .http_status = parsed.status
        .client_ip = parsed.client
      }
VRL
            ;;
        apache)
            cat <<'VRL'
      # Parse Apache combined log format
      parsed, err = parse_apache_log(.message, "combined")
      if err == null {
        .level = if parsed.status != null && to_int(parsed.status) ?? 200 >= 500 { "error" } else if to_int(parsed.status) ?? 200 >= 400 { "warning" } else { "info" }
        .http_method = parsed.method
        .http_path = parsed.path
        .http_status = parsed.status
        .client_ip = parsed.host
      }
VRL
            ;;
        rabbitmq)
            cat <<'VRL'
      # Parse RabbitMQ log format
      parsed, err = parse_regex(.message, r'^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+) \[(?P<level>\w+)\] <(?P<pid>[^>]+)> (?P<msg>.*)')
      if err == null {
        .level = downcase!(parsed.level ?? "info")
        .rabbitmq_pid = parsed.pid
        .message = parsed.msg ?? .message
      }
VRL
            ;;
        elasticsearch)
            cat <<'VRL'
      # Parse Elasticsearch JSON log format
      parsed, err = parse_json(.message)
      if err == null {
        .level = downcase!(parsed.level ?? parsed.log.level ?? "info")
        .elasticsearch_component = parsed.component
        .elasticsearch_cluster = parsed.cluster.name
        .elasticsearch_node = parsed.node.name
        .message = parsed.message ?? .message
      }
VRL
            ;;
        mongodb)
            cat <<'VRL'
      # Parse MongoDB JSON log format (4.4+)
      parsed, err = parse_json(.message)
      if err == null {
        severity = parsed.s ?? "I"
        .level = if severity == "F" { "critical" } else if severity == "E" { "error" } else if severity == "W" { "warning" } else { "info" }
        .mongodb_component = parsed.c
        .mongodb_context = parsed.ctx
        .message = parsed.msg ?? .message
      }
VRL
            ;;
        traefik)
            cat <<'VRL'
      # Parse Traefik JSON access log
      parsed, err = parse_json(.message)
      if err == null {
        status = to_int(parsed.DownstreamStatus) ?? 200
        .level = if status >= 500 { "error" } else if status >= 400 { "warning" } else { "info" }
        .http_method = parsed.RequestMethod
        .http_path = parsed.RequestPath
        .http_status = to_string(status)
        .traefik_router = parsed.RouterName
        .traefik_service = parsed.ServiceName
        .duration_ms = parsed.Duration
      }
VRL
            ;;
        haproxy)
            cat <<'VRL'
      # Parse HAProxy log format
      parsed, err = parse_regex(.message, r'(?P<client_ip>[\d.]+):(?P<client_port>\d+) \[(?P<timestamp>[^\]]+)\] (?P<frontend>\S+) (?P<backend>\S+)/(?P<server>\S+) (?P<timers>[\d/]+) (?P<status>\d+) (?P<bytes>\d+)')
      if err == null {
        status = to_int(parsed.status) ?? 200
        .level = if status >= 500 { "error" } else if status >= 400 { "warning" } else { "info" }
        .http_status = parsed.status
        .haproxy_frontend = parsed.frontend
        .haproxy_backend = parsed.backend
        .haproxy_server = parsed.server
        .client_ip = parsed.client_ip
      }
VRL
            ;;
        minio)
            cat <<'VRL'
      # Parse MinIO audit/server log (JSON)
      parsed, err = parse_json(.message)
      if err == null {
        .level = downcase!(parsed.level ?? "info")
        .minio_api = parsed.api.name
        .minio_bucket = parsed.api.bucket
        .minio_object = parsed.api.object
        .message = parsed.message ?? .message
      }
VRL
            ;;
        docker)
            cat <<'VRL'
      # Parse Docker JSON log format
      parsed, err = parse_json(.message)
      if err == null {
        .message = parsed.log ?? .message
        .docker_stream = parsed.stream
        .dt = parsed.time ?? .dt
        # Try to extract level from log message
        level_parsed, level_err = parse_regex(.message, r'(?i)\b(?P<level>ERROR|WARN|WARNING|INFO|DEBUG|CRITICAL|FATAL)\b')
        if level_err == null {
          .level = downcase!(level_parsed.level)
        }
      }
VRL
            ;;
        kubernetes)
            cat <<'VRL'
      # Parse Kubernetes container log format
      parsed, err = parse_regex(.message, r'^(?P<timestamp>\S+) (?P<stream>stdout|stderr) (?P<flags>\S+) (?P<msg>.*)')
      if err == null {
        .message = parsed.msg ?? .message
        .k8s_stream = parsed.stream
        .level = if parsed.stream == "stderr" { "error" } else { "info" }
      }
      # Extract pod metadata from file path
      path_parsed, path_err = parse_regex(to_string(.file) ?? "", r'/var/log/pods/(?P<namespace>[^_]+)_(?P<pod>[^_]+)_(?P<uid>[^/]+)/(?P<container>[^/]+)/')
      if path_err == null {
        .k8s_namespace = path_parsed.namespace
        .k8s_pod = path_parsed.pod
        .k8s_container = path_parsed.container
      }
VRL
            ;;
        *)
            cat <<'VRL'
      # Generic log parser
      level_parsed, err = parse_regex(.message, r'(?i)\b(?P<level>ERROR|WARN|WARNING|INFO|DEBUG|CRITICAL|FATAL)\b')
      if err == null {
        .level = downcase!(level_parsed.level)
      }
VRL
            ;;
    esac
}

# --- Configure Permissions ---
configure_permissions() {
    if [[ "$TECHNOLOGY" == "docker" ]]; then
        local os
        os=$(detect_os)
        if [[ "$os" != "macos" ]] && getent group docker &>/dev/null; then
            if ! id -nG vector 2>/dev/null | grep -qw docker; then
                info "Adding vector user to docker group..."
                sudo usermod -aG docker vector
                success "vector user added to docker group"
            else
                success "vector user already in docker group"
            fi
        fi
    fi
}

# --- Start/Restart Vector ---
restart_vector() {
    local os
    os=$(detect_os)

    info "Starting Vector..."

    case "$os" in
        macos)
            brew services restart vector 2>/dev/null || brew services start vector
            ;;
        *)
            sudo systemctl enable vector
            sudo systemctl restart vector
            ;;
    esac

    sleep 2

    # Check if running
    if command -v systemctl &>/dev/null && systemctl is-active --quiet vector 2>/dev/null; then
        success "Vector is running"
    elif pgrep -x vector &>/dev/null; then
        success "Vector is running"
    else
        warn "Vector may not have started. Check: journalctl -u vector -f"
    fi
}

# --- Main ---
main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       Mihari - Vector Collector Setup     ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════╝${NC}"
    echo ""

    validate_config

    info "Technology:     $TECHNOLOGY"
    info "Ingestion URL:  $INGESTION_URL"
    info "Source Token:   ${SOURCE_TOKEN:0:8}..."
    echo ""

    install_vector
    apply_config
    configure_permissions
    restart_vector

    echo ""
    success "Setup complete!"
    echo ""
    info "Vector is now collecting ${TECHNOLOGY} logs and sending them to Mihari."
    info "Config location:"
    case "$(detect_os)" in
        macos) info "  /opt/homebrew/etc/vector/vector.yaml" ;;
        *)     info "  /etc/vector/vector.yaml" ;;
    esac
    echo ""
    info "Useful commands:"
    info "  vector top                    # Live metrics"
    info "  vector validate               # Validate config"
    info "  journalctl -u vector -f       # View logs (Linux)"
    echo ""
}

main "$@"
