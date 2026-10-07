# Project context for Claude

OpenTelemetry Demo, configured to export telemetry to **two** observability backends: Dynatrace and Splunk Observability Cloud. This file is committed so it travels with the repo — a clone on another machine, under another Claude account, picks it up automatically.

Last updated 2026-10-07.

## Repo topology — read before any git operation

```
upstream   open-telemetry/opentelemetry-demo     (the real project)
  └─ fork  avillela/opentelemetry-demo           read-only to us
       └─  sachanta/opentelemetry-demo           ← ours, all pushes go here
```

- **Check `git remote -v` before pushing.** Which repo `origin` means depends on how the checkout was made:
  - Cloned from `sachanta/opentelemetry-demo` -> `origin` **is** the user's fork. Plain `git push` is correct.
  - Srikar's original working copy (`~/wd/repos/opentelemetry-demo`) -> `origin` is **Adriana Villela's** fork, pull-access only (`push: false`). A push there is rejected. Use the `srikar` remote instead; add it if absent:
    `git remote add srikar https://github.com/sachanta/opentelemetry-demo.git`
- Working branch: **`splunk-o11y-export`**. It is **not** the default branch, so a plain clone lands on `main`, which has none of this work. `git checkout splunk-o11y-export`, or clone with `-b splunk-o11y-export`.
- That branch sits on `avillela-dt-backend`, which is **~458 commits behind upstream**. Fine for config work; rebase before any upstream PR.
- Both forks are **public**. Treat everything committed as world-readable.

## What was done here

Two commits past upstream `6a3c191`:

| Commit | |
|---|---|
| `7fff28f` | Adriana's Dynatrace work: `otlphttp/dt` exporter, `.devcontainer/`, `.env` version pins |
| `054d07a` | Splunk export: `otlphttp/splunk` exporter, `resource/environment` processor, `memory_limiter` restored |

Both backends are wired into the same collector pipelines in `src/otel-collector/otelcol-config-extras.yml`. The demo services themselves have no backend-specific config — only the collector knows about Dynatrace or Splunk.

## Documentation

All in `claude_summary/`. Keep it that way — the user asked for the Splunk material to be its own file rather than folded into the Dynatrace doc.

| File | Covers |
|---|---|
| `claude_summary/DYNATRACE_SETUP.md` | Dynatrace export + the Claude Code Dynatrace MCP plugin |
| `claude_summary/SPLUNK_SETUP.md` | Splunk export, and why logs are excluded |
| `claude_summary/CREDENTIALS.md` | How to obtain and place every token |

## Credentials — not in git

`docker-compose.override.yml` holds all collector credentials and is **gitignored** (`.gitignore:12`), so it never arrives with a clone. `docker-compose.override.yml.example` is committed as a template:

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
# fill in four REPLACE_ values — see claude_summary/CREDENTIALS.md
```

Three distinct tokens, none interchangeable: a Dynatrace classic API token (`dt0c01.`, ingest scopes) for the collector, a Splunk org access token (`INGEST` authorization) for the collector, and a Dynatrace platform token (`dt0s16.`, `mcp-gateway:*`) for the Claude plugin — that last one via `launchctl setenv`, not the compose file.

**Never** print a token value, commit it, or paste it into a message. Redact when echoing the override file.

## Hard-won gotchas

Things that cost time already. Do not rediscover them.

- **Extras-file lists REPLACE, they do not append.** Any `processors:` or `exporters:` list in `otelcol-config-extras.yml` overwrites the base list in `otelcol-config.yml`. Every override must repeat the base entries it still needs. `memory_limiter` was silently lost from the metrics pipeline this way.
- **`spanmetrics` must stay in the traces *exporters* list.** It is a connector feeding the metrics pipeline; dropping it breaks span metrics.
- **Splunk Observability Cloud does not ingest application logs.** Not over OTLP, not over HEC. Logs must land in a Splunk Cloud Platform / Enterprise index, which Log Observer Connect queries *in place* — it stores and indexes nothing. The native "Log Observer" that accepted logs at `/v1/log` was retired in January 2024; that endpoint is now effectively the AlwaysOn Profiling channel. A `splunk_hec` exporter for the platform path is present but commented out.
- **`otlphttp/splunk` must not be added to the logs pipeline.** It sets `traces_endpoint`/`metrics_endpoint` per-signal and omits the generic `endpoint`, so a logs pipeline makes the collector refuse to start.
- **Splunk metrics require OTLP/HTTP.** gRPC is not accepted for metrics.
- **Dynatrace `live` vs `apps`.** The collector uses `<tenant>.live.dynatrace.com`; the Claude MCP plugin uses `<tenant>.apps.dynatrace.com`. Mixing them yields 404s or malformed-token errors.
- **The collector fails hard on any unresolved `${VAR}`**, including in an exporter no pipeline references. You cannot run one backend by blanking the other's variables — remove its exporter from the pipelines instead.
- **Memory.** Stock cap is 200M / `GOMEMLIMIT=160MiB`, sized for three exporters. There are now four, so the override raises it to 400M / 320MiB. Watch for OOM kills if lowered.

## Validating config without restarting

Full command in `claude_summary/CREDENTIALS.md`. It runs the collector image's `validate` subcommand against both config files with fake credentials and exits 0 when clean. The `/hostfs` mount only satisfies the `hostmetrics` `root_path` check. Use this instead of restarting the collector to test a config change.

## Current state

- Dynatrace export: **working and verified** (traces, metrics, logs; confirmed via the Dynatrace MCP plugin).
- Splunk export: **config in place, credentials not filled in, end-to-end ingest unverified.** The placeholders are still `REPLACE_WITH_…` as of 2026-10-07.
- Open question from the Dynatrace side: no logs arrive from checkout, email, frontend, image-provider, payment, product-catalog, flagd. Not investigated.
- The running collector may be on an older config than the working tree. `docker compose up -d --force-recreate otel-collector` to sync it.

## Working preferences

- **Separate concerns into separate docs.** Do not fold a new backend's documentation into an existing backend's file.
- **Do not commit unrelated changes.** The working tree chronically carries pre-existing noise — `.env` blank-line edits, `src/react-native-app/package-lock.json` deletions, a stray `env.txt` (an Aug 2025 copy of `.env`), and `.claude/settings.local.json`. Stage explicitly; never `git add -A`.
- **Confirm before pushing**, and check `git remote -v` first — see the topology section above.
- `.claude/` is untracked but not gitignored. It should be excluded.
- Harmless shell noise: `setValueForKeyFakeAssocArray: command not found: _encode` on every Bash call comes from the user's zsh profile. Ignore it; it is not a failure.
