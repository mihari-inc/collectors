# Mihari Collectors

Open-source installation scripts and configurations for collecting logs, metrics, and traces into [Mihari](https://mihari.io).

Supports **Vector** and **OpenTelemetry Collector** with pre-built configurations for popular technologies.

## Supported Technologies

| Technology    | Vector | OpenTelemetry | Helm |
|---------------|--------|---------------|------|
| PostgreSQL    | ✅     | ✅            | ✅   |
| MySQL         | ✅     | ✅            | ✅   |
| Kubernetes    | ✅     | ✅            | ✅   |
| Nginx         | ✅     | ✅            | ✅   |
| Apache        | ✅     | ✅            | ✅   |
| RabbitMQ      | ✅     | ✅            | ✅   |
| Elasticsearch | ✅     | ✅            | ✅   |
| MongoDB       | ✅     | ✅            | ✅   |
| Traefik       | ✅     | ✅            | ✅   |
| HAProxy       | ✅     | ✅            | ✅   |
| MinIO         | ✅     | ✅            | ✅   |
| Docker        | ✅     | ✅            | ✅   |
| Debian/Ubuntu host | ✅ | —            | —    |

## Log Event Contract

The Vector configs emit log events the Mihari ingest API (`/v1/ingest/vector`)
reads from **top-level** fields only:

| Field | Accepted keys | Notes |
|-------|---------------|-------|
| timestamp | `timestamp`, `@timestamp`, `time`, `ts` | ISO string or epoch s/ms. Never rename it (`dt` is ignored → row gets ingest time). |
| level | `level`, `severity`, `status` | normalised to trace/debug/info/warn/error/fatal |
| message | `message`, `msg`, `body` | |
| service | `service`, `service_name`, `source_type` | drives dashboard filters — always set it |
| host | `host`, `hostname` | |
| env | `env` | |
| trace/span | `trace_id`, `span_id` | hex |

Every other top-level field is stored as a string attribute (objects are
JSON-encoded), queryable as `attributes['key']`. Don't wrap parsed fields in a
nested object — keep them top-level.

Metrics go through Vector's native `prometheus_remote_write` sink to
`/v1/ingest/prometheus`.

## Testing

```bash
# Unit-test every Vector config's parsing transform (requires docker + python3):
./vector/tests/run.sh              # all technologies
./vector/tests/run.sh nginx debian # a subset

# End-to-end ingest smoke test against a running Mihari instance:
INGESTION_URL=http://localhost:3000 TOKEN=<source-ingest-token> ./tests/ingest-smoke.sh
```

`run.sh` substitutes the placeholders, extracts the transforms (sources like
`kubernetes_logs`/`journald`/`host_metrics` can't be built outside their native
environment) and runs `vector test` with the fixtures in `vector/tests/*.test.yaml`.

## Quick Start

### Vector (one-line install)

```bash
curl -fsSL https://YOUR_MIHARI_HOST/setup-vector/postgresql/YOUR_SOURCE_TOKEN | bash
```

### OpenTelemetry Collector (one-line install)

```bash
curl -fsSL https://YOUR_MIHARI_HOST/setup-otel/postgresql/YOUR_SOURCE_TOKEN | bash
```

### Kubernetes (Helm)

```bash
helm repo add mihari https://YOUR_MIHARI_HOST/helm
helm install mihari-collector mihari/mihari-collector \
  --set config.sourceToken=YOUR_SOURCE_TOKEN \
  --set config.ingestionUrl=https://YOUR_MIHARI_HOST \
  --set config.technology=kubernetes
```

## Manual Installation

### Vector

1. Install Vector: `bash vector/scripts/install.sh`
2. Copy the config: `cp vector/configs/postgresql.yaml /etc/vector/vector.yaml`
3. Edit the config with your `SOURCE_TOKEN` and `INGESTION_URL`
4. Restart Vector: `sudo systemctl restart vector`

### OpenTelemetry Collector

1. Install OTEL Collector: `bash otel/scripts/install.sh`
2. Copy the config: `cp otel/configs/postgresql.yaml /etc/otelcol-contrib/config.yaml`
3. Edit the config with your `SOURCE_TOKEN` and `INGESTION_URL`
4. Restart: `sudo systemctl restart otelcol-contrib`

## Configuration Variables

All configs use these variables (replaced by the setup scripts):

| Variable          | Description                                   | Example                           |
|-------------------|-----------------------------------------------|-----------------------------------|
| `INGESTION_URL`   | Your Mihari instance URL                      | `https://platform.mihari.io`          |
| `SOURCE_TOKEN`    | Bearer token for authentication               | `njaXhgqScw3yUwsoWdwSW5rc`      |
| `TECHNOLOGY`      | Target technology                             | `postgresql`                      |

## API Endpoints

The collectors send data to:

| Data Type | Endpoint                  | Format    |
|-----------|---------------------------|-----------|
| Logs      | `POST /v1/ingest/vector`    | JSON/NDJSON |
| Metrics   | `POST /v1/ingest/prometheus` | JSON      |
| Traces    | `POST /v1/ingest/otlp/v1/traces`    | OTLP JSON |
| OTLP Logs | `POST /v1/ingest/otlp/v1/logs`      | OTLP JSON |
| OTLP Metrics | `POST /v1/ingest/otlp/v1/metrics` | OTLP JSON |

Authentication: `Authorization: Bearer <SOURCE_TOKEN>`

## Project Structure

```
collectors/
├── vector/
│   ├── scripts/
│   │   └── install.sh          # Vector installation script
│   └── configs/
│       ├── postgresql.yaml
│       ├── mysql.yaml
│       ├── kubernetes.yaml
│       ├── nginx.yaml
│       ├── apache.yaml
│       ├── rabbitmq.yaml
│       ├── elasticsearch.yaml
│       ├── mongodb.yaml
│       ├── traefik.yaml
│       ├── haproxy.yaml
│       ├── minio.yaml
│       └── docker.yaml
├── otel/
│   ├── scripts/
│   │   └── install.sh          # OTEL Collector installation script
│   └── configs/
│       ├── postgresql.yaml
│       ├── mysql.yaml
│       ├── ...
│       └── all-services.yaml   # Unified config for all services
├── helm/
│   └── mihari-collector/       # Helm chart for Kubernetes
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
└── README.md
```

## Contributing

1. Fork this repository
2. Add or update a configuration in `vector/configs/` or `otel/configs/`
3. Test your configuration locally
4. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE)
