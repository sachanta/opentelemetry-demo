#!/usr/bin/env bash
# Create a Dynatrace OTLP ingest token and wire it into docker-compose.override.yml.
#
# Dynatrace trial tenants expire often; this automates the collector half of the
# re-setup. The Claude Code MCP plugin token is NOT handled here - that is a
# platform token and needs a different API (see claude_summary/CREDENTIALS.md).
#
# Usage:
#   export DT_BOOTSTRAP_TOKEN=dt0c01.…       # needs apiTokens.write scope
#   # or, to keep it out of shell history:
#   export DT_BOOTSTRAP_TOKEN_FILE=claude_summary/DT_Creds.txt
#   scripts/dt-setup.sh dgj76891             # tenant ID
#   scripts/dt-setup.sh dgj76891 --recreate  # also restart the collector + verify
#   scripts/dt-setup.sh dgj76891 --dry-run   # show what would happen, change nothing
#
# The bootstrap token is read from the environment so it never appears in
# shell history, argv, or this repo. Created token values are never printed.

set -euo pipefail

ENV_ID="${1:-}"
shift || true
RECREATE=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --recreate) RECREATE=1 ;;
    --dry-run)  DRY_RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERRIDE="$REPO_ROOT/docker-compose.override.yml"
SUFFIX="${DT_ENV_SUFFIX:-live.dynatrace.com}"
TOKEN_NAME="${DT_TOKEN_NAME:-otel-demo-ingest}"
EXPIRY="${DT_TOKEN_EXPIRY:-now+90d}"

# Exactly the scopes the collector's three pipelines need. Nothing more.
SCOPES='["openTelemetryTrace.ingest","metrics.ingest","logs.ingest"]'

die() { echo "error: $*" >&2; exit 1; }

[ -n "$ENV_ID" ] || die "no tenant ID given. usage: scripts/dt-setup.sh <DT_ENV_ID> [--recreate] [--dry-run]"
# Token may come from the environment, or from a file so it never touches argv
# or shell history. The file should hold the token alone, or a KEY=VALUE /
# KEY: VALUE line whose value starts dt0. Keep that file gitignored.
if [ -z "${DT_BOOTSTRAP_TOKEN:-}" ] && [ -n "${DT_BOOTSTRAP_TOKEN_FILE:-}" ]; then
  [ -f "$DT_BOOTSTRAP_TOKEN_FILE" ] || die "DT_BOOTSTRAP_TOKEN_FILE=$DT_BOOTSTRAP_TOKEN_FILE does not exist"
  DT_BOOTSTRAP_TOKEN=$(python3 -c "
import re,sys
t=open(sys.argv[1],errors='replace').read()
m=re.search(r'dt0[a-z]\\d{2}\\.[A-Za-z0-9._-]+', t)
sys.stdout.write(m.group(0) if m else '')
" "$DT_BOOTSTRAP_TOKEN_FILE")
  [ -n "$DT_BOOTSTRAP_TOKEN" ] || die "no dt0… token found in $DT_BOOTSTRAP_TOKEN_FILE. That file needs an API token, not a username/password - the Dynatrace API has no password auth."
fi
[ -n "${DT_BOOTSTRAP_TOKEN:-}" ] || die "no bootstrap token. Either: export DT_BOOTSTRAP_TOKEN=dt0c01.… , or export DT_BOOTSTRAP_TOKEN_FILE=/path/to/file containing one. The token needs the apiTokens.write scope."
[ -f "$OVERRIDE" ] || die "$OVERRIDE not found. Start from the template: cp docker-compose.override.yml.example docker-compose.override.yml"
command -v python3 >/dev/null || die "python3 is required"

API="https://${ENV_ID}.${SUFFIX}/api/v2/apiTokens"

echo "tenant:   ${ENV_ID}.${SUFFIX}"
echo "token:    name=${TOKEN_NAME}  expires=${EXPIRY}"
echo "scopes:   openTelemetryTrace.ingest, metrics.ingest, logs.ingest"
echo "override: $OVERRIDE"

if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "--dry-run: would POST to $API and rewrite DT_ENV_ID / DT_TOKEN / DT_AUTH_SCHEME / DT_ENV_SUFFIX."
  exit 0
fi

echo
echo "==> creating ingest token"
BODY=$(python3 -c "
import json,sys
print(json.dumps({
  'name': sys.argv[1],
  'scopes': json.loads(sys.argv[2]),
  'expirationDate': sys.argv[3],
}))" "$TOKEN_NAME" "$SCOPES" "$EXPIRY")

HTTP_FILE=$(mktemp); trap 'rm -f "$HTTP_FILE"' EXIT
CODE=$(curl -sS -o "$HTTP_FILE" -w '%{http_code}' -X POST "$API" \
  -H "accept: application/json; charset=utf-8" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Authorization: Api-Token ${DT_BOOTSTRAP_TOKEN}" \
  -d "$BODY") || die "curl failed talking to $API"

case "$CODE" in
  201) ;;
  400) die "400 from Dynatrace. A scope name is probably not valid on this tenant. Response: $(cat "$HTTP_FILE")" ;;
  401) die "401 Unauthorized. DT_BOOTSTRAP_TOKEN is wrong or revoked." ;;
  403) die "403 Forbidden. The bootstrap token lacks the apiTokens.write scope." ;;
  404) die "404. Tenant '$ENV_ID' or suffix '$SUFFIX' looks wrong, or this tenant has no classic token API." ;;
  *)   die "unexpected HTTP $CODE from Dynatrace. Response: $(cat "$HTTP_FILE")" ;;
esac

NEW_TOKEN=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['token'])" "$HTTP_FILE")
TOKEN_ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$HTTP_FILE")
[ -n "$NEW_TOKEN" ] || die "Dynatrace returned no token value"
echo "    created token id=${TOKEN_ID} (value not printed)"

echo "==> updating $OVERRIDE"
cp "$OVERRIDE" "${OVERRIDE}.bak"
NEW_TOKEN="$NEW_TOKEN" ENV_ID="$ENV_ID" SUFFIX="$SUFFIX" python3 - "$OVERRIDE" <<'PY'
import os, re, sys
p = sys.argv[1]
vals = {
    "DT_ENV_ID":      os.environ["ENV_ID"],
    "DT_TOKEN":       os.environ["NEW_TOKEN"],
    "DT_ENV_SUFFIX":  os.environ["SUFFIX"],
    "DT_AUTH_SCHEME": "Api-Token",   # /api/v2/apiTokens issues classic tokens
}
lines = open(p).read().split("\n")
seen = set()
for i, l in enumerate(lines):
    m = re.match(r"^(\s*-\s*)([A-Z_]+)=", l)
    if m and m.group(2) in vals:
        lines[i] = f"{m.group(1)}{m.group(2)}={vals[m.group(2)]}"
        seen.add(m.group(2))
# append any var the file did not already define, into the environment block
missing = [k for k in vals if k not in seen]
if missing:
    idx = next(i for i, l in enumerate(lines) if l.strip() == "environment:")
    indent = " " * (len(lines[idx]) - len(lines[idx].lstrip()) + 2)
    for k in missing:
        lines.insert(idx + 1, f"{indent}- {k}={vals[k]}")
open(p, "w").write("\n".join(lines))
print("    set: " + ", ".join(sorted(seen)) + (f"  added: {', '.join(missing)}" if missing else ""))
PY
echo "    backup: ${OVERRIDE}.bak  (delete it once verified - it holds the OLD token)"

if [ "$RECREATE" = 1 ]; then
  echo "==> recreating collector"
  (cd "$REPO_ROOT" && docker compose up -d --force-recreate otel-collector >/dev/null)
  echo "    waiting 20s for exports to start"
  for _ in $(seq 20); do sleep 1; done
  echo "==> recent collector errors mentioning dynatrace / auth"
  (cd "$REPO_ROOT" && docker compose logs --since 30s otel-collector 2>/dev/null \
    | grep -i -E "401|403|404|dynatrace|permanent error" | tail -15) || true
  echo "    (no output above = exporting cleanly)"
else
  echo
  echo "next: docker compose up -d --force-recreate otel-collector"
fi
