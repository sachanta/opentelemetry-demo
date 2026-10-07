# Dynatrace setup for this OpenTelemetry Demo

Branch: `avillela-dt-backend`. Dynatrace tenant: environment ID `fwn71039` (`live.dynatrace.com` / `apps.dynatrace.com`).

There are two separate integrations, and they use **different tokens and different env vars**:

| | A. Telemetry export | B. Claude Code Dynatrace plugin (MCP) |
|---|---|---|
| Purpose | Send the demo's traces, metrics and logs to Dynatrace | Let Claude query Dynatrace (DQL, problems, etc.) |
| Runs in | `otel-collector` container | Claude desktop app / Claude Code |
| Auth | Classic API token (`dt0c01.…`), `Api-Token` header | Platform token (`dt0s16.…`), `Bearer` header |
| Vars | `DT_ENV_ID`, `DT_TOKEN`, `DT_ENV_SUFFIX` | `DT_ENVIRONMENT`, `DT_PLATFORM_TOKEN` |

Splunk Observability Cloud also exports from this collector; that is documented separately in `SPLUNK_SETUP.md`.

No token values are recorded in this document.

---

## A. Telemetry export (collector -> Dynatrace)

### Data flow

```
demo services --OTLP (4317 gRPC / 4318 HTTP)--> otel-collector --otlphttp/dt--> https://<DT_ENV_ID>.<DT_ENV_SUFFIX>/api/v2/otlp
                                                       |--> jaeger (traces), prometheus (metrics), opensearch (logs)   [unchanged demo defaults]
```

Services send to `OTEL_COLLECTOR_HOST:OTEL_COLLECTOR_PORT_*` (`otel-collector:4317/4318`, set in `.env`). They have no Dynatrace-specific config. Only the collector knows about Dynatrace.

### Files and what each does

| File | Tracked in git? | Role |
|---|---|---|
| `docker-compose.override.yml` | **No** (gitignored, `.gitignore:12`) | Defines the three `DT_*` env vars on the `otel-collector` service. This is where the values live. Also holds the `SPLUNK_*` vars and a raised memory limit (`SPLUNK_SETUP.md`). |
| `src/otel-collector/otelcol-config-extras.yml` | Yes (changed in commit `7fff28f`) | Defines the `otlphttp/dt` exporter and adds it to the pipelines. Reads the `DT_*` vars with `${env:...}`-style expansion. Shared with the Splunk exporters (`SPLUNK_SETUP.md`). |
| `src/otel-collector/otelcol-config.yml` | Yes, unchanged | Base collector config: receivers, processors, `spanmetrics` connector, and the default exporters (jaeger, prometheus, opensearch). |
| `docker-compose.yml` | Yes, unchanged | Starts `otel-collector` with both config files: `--config=/etc/otelcol-config.yml --config=/etc/otelcol-config-extras.yml`. |
| `.env` | Yes | Provides `OTEL_COLLECTOR_CONFIG`, `OTEL_COLLECTOR_CONFIG_EXTRAS`, collector host/ports, `COLLECTOR_CONTRIB_IMAGE`. Contains **no** Dynatrace vars. |
| `env.txt` | No (untracked) | Old copy of `.env` (dated Aug 2025). Not used by anything and has no Dynatrace vars. |

### Environment variables (collector)

Set in `docker-compose.override.yml` under `services.otel-collector.environment`. Docker Compose merges the override file automatically on `docker compose up`.

| Variable | Value / meaning | Read where |
|---|---|---|
| `DT_ENV_ID` | `fwn71039`, the tenant ID | `otelcol-config-extras.yml` line 13, in the exporter `endpoint` |
| `DT_ENV_SUFFIX` | `live.dynatrace.com` | `otelcol-config-extras.yml` line 13, in the exporter `endpoint` |
| `DT_TOKEN` | Classic API token (`dt0c01.…`) | `otelcol-config-extras.yml` line 15, as `Authorization: "Api-Token ${DT_TOKEN}"` |

Resulting endpoint: `https://fwn71039.live.dynatrace.com/api/v2/otlp`.

The token needs the OTLP ingest scopes: `openTelemetryTrace.ingest`, `metrics.ingest`, `logs.ingest`. The collector does not read it from `.env` or `env.txt`.

### Collector config changes (`otelcol-config-extras.yml`)

The extras file is merged into the base config. **List values replace the base list instead of appending**, so each pipeline repeats the base exporters and adds `otlphttp/dt`.

```yaml
exporters:
  otlphttp/dt:                 # Dynatrace OTLP/HTTP exporter
    endpoint: "https://${DT_ENV_ID}.${DT_ENV_SUFFIX}/api/v2/otlp"
    headers:
      Authorization: "Api-Token ${DT_TOKEN}"
  debug:
    verbosity: detailed        # overrides base `debug` (more verbose collector logs)

processors:
  cumulativetodelta:           # Dynatrace needs delta temporality for metrics
  resource/environment:        # sets deployment.environment on all telemetry

service:
  pipelines:
    traces:  processors: [memory_limiter, transform, resource/environment, batch]
             exporters: [spanmetrics, otlp, otlphttp/dt, otlphttp/splunk, debug]
    metrics: processors: [memory_limiter, cumulativetodelta, resource/environment, batch]
             exporters: [otlphttp/dt, otlphttp/prometheus, otlphttp/splunk, debug]
    logs:    processors: [memory_limiter, resource/environment, batch]
             exporters: [otlphttp/dt, opensearch, debug]
```

`otlphttp/splunk` and `resource/environment` are shown here because this file is shared with the Splunk export; both are defined and explained in `SPLUNK_SETUP.md`. Nothing about the Dynatrace path depends on them.

Notes:
- `spanmetrics` must stay in the traces exporter list. It is a connector that feeds the metrics pipeline.
- Every overridden list must repeat the base entries it still needs, since the extras file replaces lists rather than appending. `memory_limiter` had been dropped from the metrics pipeline this way; it is now restored in all three.
- The demo's resource attributes come from `.env`: `OTEL_RESOURCE_ATTRIBUTES=service.namespace=opentelemetry-demo,service.version=${IMAGE_VERSION}`.

### Change history (what was changed vs upstream)

- **Commit `7fff28f`** (Adriana Villela, "Add dev containers and update .env file"):
  - Replaced the commented-out example in `otelcol-config-extras.yml` with the real Dynatrace config above.
  - `.env`: pinned `IMAGE_VERSION=2.0.1` (`2.0.2` commented out) and `DEMO_VERSION=${IMAGE_VERSION}` (`latest` commented out).
  - Added `.devcontainer/devcontainer.json` and `.devcontainer/post-create.sh`.
- **Uncommitted in the working tree:**
  - `.env`: two blank lines removed at the top (cosmetic).
  - `src/otel-collector/otelcol-config-extras.yml`: Splunk exporter added, `resource/environment` processor added, `memory_limiter` restored to all pipelines. See `SPLUNK_SETUP.md`.
  - `src/react-native-app/package-lock.json`: modified, unrelated to Dynatrace.
  - `docker-compose.override.yml`, `env.txt`, `.claude/`: untracked or ignored (see below).
- `src/flagd/demo.flagd.json` was temporarily edited to enable failure flags (`productCatalogFailure` on, `paymentFailure` 25%) and has been **reset to the committed version**.

### Running it

```bash
docker compose up -d      # picks up docker-compose.yml + docker-compose.override.yml
docker compose logs otel-collector | grep -i -E "dt|dynatrace|401|403|export"   # check for export errors
```

After changing `DT_*` values or the extras file, restart the collector: `docker compose up -d --force-recreate otel-collector`.

---

## B. Claude Code Dynatrace plugin (MCP server)

Plugin `dynatrace` provides skills (`dt-obs-tracing`, `dt-dql-essentials`, etc.) and an MCP server. The MCP server only connects if its env vars are available to the **Claude desktop app process**.

| Variable | Value / meaning | Where it is set |
|---|---|---|
| `DT_ENVIRONMENT` | `https://fwn71039.apps.dynatrace.com` (the **apps** URL, not `live`) | macOS user session via `launchctl setenv`. Also in `.claude/settings.local.json` (project `env` block), but the plugin did **not** pick it up from there. |
| `DT_PLATFORM_TOKEN` | Platform token (`dt0s16.…`) | macOS user session via `launchctl setenv` |

The plugin's README (in the Claude app's plugin cache) names both variables.

### Setup steps that were needed

1. `launchctl setenv DT_ENVIRONMENT "https://fwn71039.apps.dynatrace.com"`
2. Create a Dynatrace **platform token** (Account Management -> Identity & access management -> Platform tokens) with the `mcp-gateway:servers:invoke` and `mcp-gateway:servers:read` scopes, plus the `storage:*:read` scopes for queries. The token is shown once.
3. `launchctl setenv DT_PLATFORM_TOKEN "<token>"`
4. Fully quit and reopen the Claude app. `launchctl setenv` values are read at app launch, and are lost on reboot.

### Errors seen along the way

| Error | Meaning |
|---|---|
| `INVALID_CONFIG: Missing environment variables: DT_ENVIRONMENT` | The var was not visible to the app. Fixed with `launchctl setenv`. |
| `401 Bearer token is malformed` | `DT_PLATFORM_TOKEN` was missing or empty. |
| `401 Platform token has invalid format` | The var held the wrong value (not a valid `dt0s16.` token). |
| `403 ... missing scope ...:invoke` | Token lacked the MCP gateway scope (`mcp-gateway:servers:invoke`). Fixed by creating a token with it. |

The setup is working: DQL queries return data from tenant `fwn71039`.

### Persistence note

`launchctl setenv` does not survive a reboot. To make it permanent, use a LaunchAgent plist that runs `launchctl setenv`, or re-run the commands after each restart.

---

## Verification status (checked via Dynatrace MCP)

- **Traces:** spans from accounting, ad, cart, checkout, currency, email, flagd, fraud-detection, frontend, frontend-proxy, frontend-web (RUM), image-provider, load-generator, payment, product-catalog, quote, recommendation, shipping.
- **Service metrics:** `dt.service.request.count` for the 14 services with service entities.
- **OTLP metrics:** `app.ads.ad_requests`, `traces.span.metrics.calls` (spanmetrics), `container.cpu.utilization` (docker_stats) all have data. A ~7 minute gap was seen around 22:26-22:32 UTC on 2026-10-05, cause unknown.
- **Logs:** received from accounting, ad, cart, currency, fraud-detection, frontend-proxy, kafka, load-generator, quote, recommendation, shipping.
- **Open question:** no logs from checkout, email, frontend, image-provider, payment, product-catalog, flagd. Not yet investigated.

---

## Security notes

- `docker-compose.override.yml` holds a **plaintext classic API token**. It is gitignored. Do not commit it, and rotate the token if it was ever shared. It also holds Splunk credentials - see `SPLUNK_SETUP.md`.
- `.claude/` is untracked but **not gitignored**. `settings.local.json` currently holds only a URL, but add `.claude/` to `.gitignore` or `.git/info/exclude` so it does not get committed.
- Use separate tokens for each purpose: the ingest-only API token for the collector, and a read-scoped platform token for Claude. Neither is interchangeable with the other.
