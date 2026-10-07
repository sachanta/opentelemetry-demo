# Splunk Observability Cloud setup for this OpenTelemetry Demo

Telemetry export from the demo's `otel-collector` to Splunk Observability Cloud. Dynatrace export and the Claude Code Dynatrace plugin are documented separately in `DYNATRACE_SETUP.md`; the two backends share one collector and one config file but are otherwise independent.

**Status: config in place, credentials not filled in.** `SPLUNK_REALM` and `SPLUNK_ACCESS_TOKEN` are placeholders and the collector has not been restarted. See [Enabling it](#enabling-it).

| | Value |
|---|---|
| Signals sent | Traces, metrics. **Not logs** - see [Logs](#logs-dont-go-to-o11y-cloud) |
| Runs in | `otel-collector` container |
| Auth | Splunk org access token with `INGEST` authorization, `X-SF-Token` header |
| Vars | `SPLUNK_REALM`, `SPLUNK_ACCESS_TOKEN`, `DEPLOYMENT_ENVIRONMENT` |

No token values are recorded in this document.

---

## Data flow

```
                                       |--otlphttp/dt-------> Dynatrace (traces, metrics, logs)
demo services --OTLP--> otel-collector |--otlphttp/splunk---> Splunk O11y  (traces, metrics)
                                       |--> jaeger / prometheus / opensearch   [demo defaults]
```

Services send to `OTEL_COLLECTOR_HOST:OTEL_COLLECTOR_PORT_*` (`otel-collector:4317/4318`, set in `.env`). They have no Splunk-specific config. Only the collector knows about Splunk.

Logs to Splunk would need a second hop, which is **not** configured:

```
collector --splunk_hec--> Splunk Cloud Platform / Enterprise index
                                  ^
                 Log Observer Connect queries it in place --> shown in O11y Cloud UI
```

## Files and what each does

| File | Tracked in git? | Role |
|---|---|---|
| `src/otel-collector/otelcol-config-extras.yml` | Yes | Defines the `otlphttp/splunk` exporter and the `resource/environment` processor, and adds them to the pipelines. Shared with the Dynatrace exporter. |
| `docker-compose.override.yml` | **No** (gitignored, `.gitignore:12`) | Defines `SPLUNK_REALM`, `SPLUNK_ACCESS_TOKEN`, `DEPLOYMENT_ENVIRONMENT` and the raised memory limit. This is where the token value goes. |
| `docker-compose.yml` | Yes, unchanged | Starts `otel-collector` with both config files. |
| `.env` | Yes, unchanged | Pins `COLLECTOR_CONTRIB_IMAGE` to contrib `0.125.0`, which already contains the exporters used here. |

## Exporter

Traces and metrics live at different paths on the Splunk ingest host, so `traces_endpoint` and `metrics_endpoint` are set per-signal and the generic `endpoint` is deliberately omitted:

| Signal | Endpoint |
|---|---|
| Traces | `https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp` |
| Metrics | `https://ingest.<realm>.observability.splunkcloud.com/v2/datapoint/otlp` |

```yaml
exporters:
  otlphttp/splunk:
    traces_endpoint:  "https://ingest.${SPLUNK_REALM}.observability.splunkcloud.com/v2/trace/otlp"
    metrics_endpoint: "https://ingest.${SPLUNK_REALM}.observability.splunkcloud.com/v2/datapoint/otlp"
    headers:
      X-SF-Token: "${SPLUNK_ACCESS_TOKEN}"

processors:
  resource/environment:
    attributes:
      - key: deployment.environment
        value: ${env:DEPLOYMENT_ENVIRONMENT:-opentelemetry-demo}
        action: upsert
```

The extras file is merged into the base config, and **list values replace the base list instead of appending**, so each pipeline repeats everything it still needs:

```yaml
service:
  pipelines:
    traces:  processors: [memory_limiter, transform, resource/environment, batch]
             exporters: [spanmetrics, otlp, otlphttp/dt, otlphttp/splunk, debug]
    metrics: processors: [memory_limiter, cumulativetodelta, resource/environment, batch]
             exporters: [otlphttp/dt, otlphttp/prometheus, otlphttp/splunk, debug]
    logs:    processors: [memory_limiter, resource/environment, batch]
             exporters: [otlphttp/dt, opensearch, debug]
```

## Gotchas that shaped this config

- **`otlphttp/splunk` must not be added to the logs pipeline.** With no `logs_endpoint` set, putting it in a logs pipeline makes the collector refuse to start: `failed to create "otlphttp/splunk" exporter for data type "logs": either endpoint or logs_endpoint must be specified`. Verified against contrib 0.125.0.
- **Metrics must go over OTLP/HTTP.** Splunk does not accept OTLP metrics over gRPC, which is why `otlphttp` is used rather than `otlp`.
- **`deployment.environment` is required for Splunk APM to be usable.** Without it, traces land in an `unknown` environment. The `resource/environment` processor sets it on all three pipelines; it is harmless for Dynatrace (which uses the same attribute) and for Jaeger/Prometheus/OpenSearch.
- **`cumulativetodelta` suits both backends.** It was already present for Dynatrace; Splunk also prefers delta temporality, and cumulative histograms arrive there without min/max, which skews percentiles.
- **`spanmetrics` must stay in the traces exporter list.** It is a connector that feeds the metrics pipeline.
- **`memory_limiter` was restored.** The earlier Dynatrace-only metrics override had dropped it by replacing the base processor list; it is now present in all three pipelines.
- **Legacy vs current domain.** `ingest.<realm>.signalfx.com` still works; `ingest.<realm>.observability.splunkcloud.com` is the current domain and is what this config uses.

## Logs don't go to O11y Cloud

**Splunk Observability Cloud does not ingest or store application logs.** The O11y ingest domain takes metrics, traces, and AlwaysOn Profiling data only. Splunk's own Helm chart states it plainly: "By default only metrics and traces are sent to Splunk Observability destination, and only logs are sent to Splunk Platform destination" - `splunkObservability` has no logs option at all.

Logs reach the O11y UI by a different route:

1. Logs are ingested into a **Splunk Cloud Platform or Splunk Enterprise** index. That is the repository.
2. **Log Observer Connect** authenticates a service account against the Splunk **search head** (port 8089) and runs searches there on demand.
3. Results render in the O11y Cloud UI with Related Content correlation to traces and metrics.

Log Observer Connect stores and indexes nothing, and does not copy data into O11y Cloud. Each query consumes search capacity on the Splunk platform deployment, so sizing matters.

### The retired native Log Observer

There used to be a **Log Observer** (no "Connect") that ingested logs straight into O11y Cloud over HEC at `https://ingest.<realm>.observability.splunkcloud.com/v1/log` and stored them there. It was deprecated, with migration to Log Observer Connect required by **end of January 2024**. That endpoint survives on the O11y ingest domain mainly as the **AlwaysOn Profiling** channel. Do not send application logs to it - on a current tenant nothing displays them.

This config originally pointed a `splunk_hec/splunk` exporter at that endpoint. It is now **commented out** in `otelcol-config-extras.yml` and absent from the logs pipeline, so no logs are sent to a dead path. Demo logs still go to Dynatrace and OpenSearch.

### Enabling logs, if a Splunk platform instance is available

1. Uncomment the `splunk_hec/splunk` exporter in `otelcol-config-extras.yml`.
2. Add it to the logs pipeline: `exporters: [otlphttp/dt, opensearch, splunk_hec/splunk, debug]`.
3. Set these in `docker-compose.override.yml`:

| Variable | Value |
|---|---|
| `SPLUNK_HEC_URL` | `https://http-inputs-<stack>.splunkcloud.com/services/collector` (or `https://<host>:8088/services/collector` for Enterprise) |
| `SPLUNK_HEC_TOKEN` | A Splunk **platform** HEC token - *not* the O11y org access token |
| `SPLUNK_HEC_INDEX` | The index to write to; required, and the one Log Observer Connect must query |

4. In O11y Cloud, set up Log Observer Connect against that Splunk instance and point its default index at the index above.

This is a genuinely separate system from the realm/token pair used for traces and metrics: a different host, a different token type, and a tenant-side integration to configure.

## Environment variables (collector)

Set in `docker-compose.override.yml` under `services.otel-collector.environment`, next to the `DT_*` vars. Docker Compose merges the override file automatically on `docker compose up`.

| Variable | Value / meaning | Status |
|---|---|---|
| `SPLUNK_REALM` | Short region code from your Splunk O11y URL, e.g. `us0`, `us1`, `eu0` | **placeholder - must be filled in** |
| `SPLUNK_ACCESS_TOKEN` | Splunk **org access token** with `INGEST` authorization (Settings -> Access Tokens) | **placeholder - must be filled in** |
| `DEPLOYMENT_ENVIRONMENT` | `opentelemetry-demo`; sets `deployment.environment`. Optional - the config defaults to the same value if unset. | set |

One token covers both signals Splunk accepts. Do not reuse the Dynatrace API token or Dynatrace platform token here; they are unrelated systems. Logs would need a separate Splunk platform HEC token.

## Memory

The stock collector cap of 200M (`docker-compose.yml:754`, with `GOMEMLIMIT=160MiB`) was sized for the demo's three default exporters. There are now four across three pipelines, so the override file raises it to **400M / `GOMEMLIMIT=320MiB`**. Both values are in `docker-compose.override.yml`, which is gitignored, so `docker-compose.yml` stays unmodified. If memory is tight on the host, drop these back and watch for the collector being OOM-killed (`docker compose ps otel-collector`).

## Enabling it

The collector is **still running the old config**. The two placeholder values must be replaced first, otherwise the collector starts but fails every export against the unresolvable host `ingest.REPLACE_WITH_REALM.observability.splunkcloud.com`.

```bash
# 1. edit docker-compose.override.yml: set SPLUNK_REALM and SPLUNK_ACCESS_TOKEN
# 2. recreate the collector
docker compose up -d --force-recreate otel-collector

# 3. confirm it came up and is exporting
docker compose logs --tail=100 otel-collector | grep -i -E "splunk|error|401|403"
```

Expect no `splunk` lines on success - the exporter is quiet when healthy. Failures show as `401` (bad token), `404` (wrong path or realm), or DNS errors (bad realm).

## Verifying the config without restarting

The merged config can be checked offline, which is how this was validated:

```bash
docker run --rm \
  -v "$PWD/src/otel-collector/otelcol-config.yml:/etc/otelcol-config.yml:ro" \
  -v "$PWD/src/otel-collector/otelcol-config-extras.yml:/etc/otelcol-config-extras.yml:ro" \
  -v "/etc:/hostfs:ro" \
  -e OTEL_COLLECTOR_HOST=0.0.0.0 -e OTEL_COLLECTOR_PORT_GRPC=4317 -e OTEL_COLLECTOR_PORT_HTTP=4318 \
  -e ENVOY_PORT=8080 \
  -e DT_ENV_ID=fake -e DT_ENV_SUFFIX=live.dynatrace.com -e DT_TOKEN=dt0c01.fake \
  -e SPLUNK_REALM=us1 -e SPLUNK_ACCESS_TOKEN=faketoken \
  ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.125.0 \
  validate --config=/etc/otelcol-config.yml --config=/etc/otelcol-config-extras.yml
```

Exits 0 on a valid config. The `/hostfs` mount only satisfies the `hostmetrics` receiver's `root_path` check; the path itself does not matter for validation.

## Where to look in Splunk

- **APM** -> service map, filtered to environment `opentelemetry-demo`.
- **Infrastructure / Metrics** -> `app.ads.ad_requests`, `traces.span.metrics.calls` (spanmetrics), `container.cpu.utilization` (docker_stats), `system.*` (hostmetrics).
- **Log Observer Connect** -> nothing, unless the Splunk platform path above is set up.

## Not verified

End-to-end ingest has **not** been confirmed - no realm or token was available when this was set up. The config parses cleanly against collector 0.125.0 and the trace/metric endpoints match current Splunk docs, but no data has been seen landing in a Splunk tenant.

## Security notes

- `docker-compose.override.yml` will hold a **plaintext Splunk org access token** once filled in, alongside the Dynatrace token already there. It is gitignored. Do not commit it, and rotate the token if it was ever shared.
- Use an `INGEST`-scoped org access token here. Do not reuse an API access token that carries read or admin authorization.

## Reference

- [OTLP/HTTP exporter (Splunk)](https://help.splunk.com/en/splunk-observability-cloud/manage-data/splunk-distribution-of-the-opentelemetry-collector/get-started-with-the-splunk-distribution-of-the-opentelemetry-collector/collector-components/exporters/otlphttp-exporter)
- [Splunk HEC exporter](https://help.splunk.com/en/splunk-observability-cloud/manage-data/splunk-distribution-of-the-opentelemetry-collector/get-started-with-the-splunk-distribution-of-the-opentelemetry-collector/collector-components/exporters/splunk-hec-exporter)
- [Introduction to Splunk Log Observer Connect](https://help.splunk.com/en/splunk-observability-cloud/manage-data/view-splunk-platform-logs/introduction-to-splunk-log-observer-connect)
- [Set up Log Observer Connect for Splunk Cloud Platform](https://help.splunk.com/en/splunk-observability-cloud/manage-data/view-splunk-platform-logs/set-up-log-observer-connect-for-splunk-cloud-platform)
- [Cumulative to delta processor](https://help.splunk.com/en/splunk-observability-cloud/manage-data/splunk-distribution-of-the-opentelemetry-collector/get-started-with-the-splunk-distribution-of-the-opentelemetry-collector/collector-components/processors/cumulative-to-delta-processor)
- [splunk-otel-collector-chart advanced configuration](https://github.com/signalfx/splunk-otel-collector-chart/blob/main/docs/advanced-configuration.md)
