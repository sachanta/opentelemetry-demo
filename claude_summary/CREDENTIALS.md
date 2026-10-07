# Credentials: Dynatrace and Splunk Observability Cloud

Everything the demo needs in order to export telemetry, and where each value goes. Companion to `DYNATRACE_SETUP.md` and `SPLUNK_SETUP.md`, which cover *what* the config does; this file covers *how to supply the secrets*.

**Nothing here is in git.** `docker-compose.override.yml` is gitignored (`.gitignore:12`), so a fresh clone has no credentials and the collector will not start until you create it. That is the point of this document.

---

## The four values

| # | Variable | Used by | Type |
|---|---|---|---|
| 1 | `DT_ENV_ID` | collector | Dynatrace tenant ID (not secret) |
| 2 | `DT_TOKEN` | collector | Dynatrace **classic API token** (`dt0c01.…`) |
| 3 | `SPLUNK_REALM` | collector | Splunk region code (not secret) |
| 4 | `SPLUNK_ACCESS_TOKEN` | collector | Splunk **org access token** |

Plus one that is **not** in this file because it belongs to the Claude Code plugin rather than the demo:

| # | Variable | Used by | Type |
|---|---|---|---|
| 5 | `DT_PLATFORM_TOKEN` | Claude desktop app | Dynatrace **platform token** (`dt0s16.…`) |

Tokens 2, 4 and 5 are three different credentials from two different vendors with three different scope models. None is interchangeable with another.

---

## Quick start on a new machine

```bash
git clone https://github.com/sachanta/opentelemetry-demo.git
cd opentelemetry-demo
git checkout splunk-o11y-export

cp docker-compose.override.yml.example docker-compose.override.yml
# edit the four REPLACE_ values, then:
docker compose up -d
```

If you only want one backend, see [Running with one backend](#running-with-one-backend) - the collector fails on *any* unresolved `${VAR}`, so you cannot simply leave the other blank.

---

## 1-2. Dynatrace ingest token (collector)

**Where:** Dynatrace UI -> **Access tokens** -> *Generate new token*.

**Scopes** (exactly these three, nothing more):

- `openTelemetryTrace.ingest`
- `metrics.ingest`
- `logs.ingest`

The token is shown **once**. It starts `dt0c01.`.

**Tenant ID** is the first path segment of your Dynatrace URL: `https://<DT_ENV_ID>.live.dynatrace.com`. Eight characters, e.g. `fwn71039`.

```yaml
- DT_ENV_ID=fwn71039
- DT_TOKEN=dt0c01.XXXXXXXX.XXXXXXXX…
- DT_ENV_SUFFIX=live.dynatrace.com
```

`DT_ENV_SUFFIX` is `live.dynatrace.com` for SaaS. Use the **live** host here, not `apps`. The resulting endpoint is `https://<DT_ENV_ID>.<DT_ENV_SUFFIX>/api/v2/otlp`.

## 3-4. Splunk access token (collector)

**Where:** Splunk Observability Cloud -> **Settings** -> **Access Tokens** -> *New Token*.

**Authorization scope:** `INGEST`. Do not grant `API` (read/admin) authorization to a token the collector holds.

**Realm** is the short region code in your O11y Cloud URL, e.g. `us0`, `us1`, `eu0`. Find it under Settings, or read it from the hostname you log in to.

```yaml
- SPLUNK_REALM=us1
- SPLUNK_ACCESS_TOKEN=XXXXXXXXXXXXXXXXXXXXXX
```

One token covers both signals Splunk accepts. It is sent as the `X-SF-Token` header. Resulting endpoints:

- traces: `https://ingest.<realm>.observability.splunkcloud.com/v2/trace/otlp`
- metrics: `https://ingest.<realm>.observability.splunkcloud.com/v2/datapoint/otlp`

Splunk does **not** take application logs - see `SPLUNK_SETUP.md`. If you later add the Splunk platform HEC path for logs, that needs two more values (`SPLUNK_HEC_URL`, `SPLUNK_HEC_TOKEN`, `SPLUNK_HEC_INDEX`) and a *platform* HEC token, not this one.

## 5. Dynatrace platform token (Claude Code plugin)

This one is **not** read by the demo. It is read by the Claude desktop app process, so it cannot live in `docker-compose.override.yml`.

**Where:** Dynatrace -> Account Management -> Identity & access management -> **Platform tokens**.

**Scopes:**

- `mcp-gateway:servers:invoke`
- `mcp-gateway:servers:read`
- `storage:*:read` (whichever `storage:…:read` scopes you need for DQL)

It starts `dt0s16.` and is sent as `Authorization: Bearer`.

**How to set it** (macOS):

```bash
launchctl setenv DT_ENVIRONMENT "https://<DT_ENV_ID>.apps.dynatrace.com"
launchctl setenv DT_PLATFORM_TOKEN "dt0s16.…"
# then fully quit and reopen the Claude app
```

Two traps, both previously hit:

- Use the **apps** URL here (`apps.dynatrace.com`), not `live`. The collector uses `live`; the plugin uses `apps`.
- `launchctl setenv` values are read at app launch and are **lost on reboot**. For persistence, use a LaunchAgent plist that runs these, or re-run them after each restart.

Putting `DT_ENVIRONMENT` in `.claude/settings.local.json` did **not** work - the plugin did not pick it up from there.

---

## Running with one backend

The collector resolves every `${VAR}` in the merged config at startup and fails hard on an unset one, so you cannot leave a backend's variables blank. To run with only one, remove the other's exporter from the pipelines in `src/otel-collector/otelcol-config-extras.yml`:

| To drop | Remove from pipelines | Then you can omit |
|---|---|---|
| Splunk | `otlphttp/splunk` (traces, metrics) | `SPLUNK_REALM`, `SPLUNK_ACCESS_TOKEN` |
| Dynatrace | `otlphttp/dt` (traces, metrics, logs) | `DT_ENV_ID`, `DT_TOKEN`, `DT_ENV_SUFFIX` |

Deleting the exporter definition itself is optional; an unreferenced exporter is still parsed, so its `${VAR}`s must still resolve. Removing it from the pipelines *and* deleting the block is the clean way.

---

## Verifying

```bash
# 1. Does the merged config parse at all? (no credentials needed - fakes are fine)
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

# 2. Did Compose actually pick up the override?
docker compose config | grep -E "DT_ENV_ID|SPLUNK_REALM|GOMEMLIMIT"

# 3. Are exports succeeding?
docker compose logs --tail=100 otel-collector | grep -i -E "error|401|403|404|dynatrace|splunk"
```

Both exporters are **quiet when healthy** - no news is good news. After changing any value:

```bash
docker compose up -d --force-recreate otel-collector
```

### What failures look like

| Symptom | Likely cause |
|---|---|
| Collector exits immediately, `expected ... got ...` on a `${VAR}` | A variable is unset; the override file is missing or misnamed |
| `401` against Dynatrace | `DT_TOKEN` wrong, or missing an `*.ingest` scope |
| `403` against Dynatrace | Token valid but lacks the scope for that signal |
| `404` against Dynatrace | `DT_ENV_ID` or `DT_ENV_SUFFIX` wrong (check `live` vs `apps`) |
| `401` against Splunk | `SPLUNK_ACCESS_TOKEN` wrong, or it lacks `INGEST` authorization |
| DNS / no-such-host against Splunk | `SPLUNK_REALM` wrong or still the placeholder |
| Collector OOM-killed | Memory cap too low; see the Memory section in `SPLUNK_SETUP.md` |
| Claude plugin: `Bearer token is malformed` | `DT_PLATFORM_TOKEN` empty or not a `dt0s16.` token |
| Claude plugin: `missing scope …:invoke` | Platform token lacks `mcp-gateway:servers:invoke` |

---

## Security

- `docker-compose.override.yml` holds **two plaintext tokens**. It is gitignored. Do not commit it, and do not paste it into a chat, issue, or PR.
- `docker-compose.override.yml.example` is committed and must only ever contain `REPLACE_…` placeholders.
- Keep the three tokens separate and minimally scoped: ingest-only for the collector (both vendors), read-only for the Claude plugin.
- Rotate any token that has been shared, pasted, or committed. Both vendors let you revoke a token without downtime for the others.
- `.claude/` is untracked but **not** gitignored. Add it to `.gitignore` or `.git/info/exclude` so `settings.local.json` is not committed by accident.
- Both `sachanta/opentelemetry-demo` and its parent `avillela/opentelemetry-demo` are **public**. Assume anything committed is world-readable.
