#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/opt/novabank}"
OUT_DIR="${OUT_DIR:-$ROOT/evidence/v03}"
mkdir -p "$OUT_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/alertmanager-proof-${STAMP}.txt"
JSON="$OUT_DIR/alertmanager-alert-${STAMP}.json"
PAYLOAD="/tmp/novabank-alertmanager-${STAMP}.json"
LOCAL_PORT="${LOCAL_PORT:-19093}"

exec > >(tee -a "$OUT") 2>&1

echo "=== ALERTMANAGER PROOF ==="
echo "UTC=$STAMP"

ROW="$(
  kubectl get svc -A -o json |
  jq -r '
    .items[]
    | select(.spec.clusterIP != "None")
    | select(
        ((.metadata.name // "") | test("alertmanager"; "i"))
        or ((.metadata.labels["app.kubernetes.io/name"] // "") == "alertmanager")
      )
    | [
        .metadata.namespace,
        .metadata.name,
        (
          [
            .spec.ports[]
            | select((.port == 9093) or (.targetPort == 9093))
            | .port
          ][0] // 9093
        )
      ]
    | @tsv
  ' | head -1
)"

if [ -z "$ROW" ]; then
  echo "ALERTMANAGER_SERVICE=NOT_FOUND"
  exit 1
fi

IFS=$'\t' read -r AM_NS AM_SVC AM_PORT <<<"$ROW"
echo "ALERTMANAGER_NAMESPACE=$AM_NS"
echo "ALERTMANAGER_SERVICE=$AM_SVC"
echo "ALERTMANAGER_PORT=$AM_PORT"

PF_LOG="/tmp/novabank-alertmanager-portforward-${STAMP}.log"
kubectl -n "$AM_NS" port-forward "svc/$AM_SVC" "${LOCAL_PORT}:${AM_PORT}" >"$PF_LOG" 2>&1 &
PF_PID=$!

cleanup() {
  kill "$PF_PID" >/dev/null 2>&1 || true
  rm -f "$PAYLOAD"
}
trap cleanup EXIT

AM_HOST="127.0.0.1"
AM_URL="http://${AM_HOST}:${LOCAL_PORT}"

for _ in $(seq 1 20); do
  if curl -fsS "${AM_URL}/-/ready" >/dev/null 2>&1; then
    echo "ALERTMANAGER_READY=OK"
    break
  fi
  sleep 1
done

curl -fsS "${AM_URL}/-/ready" >/dev/null
STARTS_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ENDS_AT="$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg starts "$STARTS_AT" \
  --arg ends "$ENDS_AT" \
  '[
    {
      labels: {
        alertname: "NovaBankV03Evidence",
        severity: "warning",
        source: "manual-validation"
      },
      annotations: {
        summary: "NovaBank V0.3 Alertmanager validation"
      },
      startsAt: $starts,
      endsAt: $ends
    }
  ]' > "$PAYLOAD"

HTTP_CODE="$(
  curl -sS \
    -o /tmp/novabank-alertmanager-post.out \
    -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    --data-binary "@$PAYLOAD" \
    "${AM_URL}/api/v2/alerts"
)"

echo "ALERT_POST_HTTP=$HTTP_CODE"
case "$HTTP_CODE" in
  200|201|202) ;;
  *)
    echo "ALERTMANAGER_POST=FAILED"
    cat /tmp/novabank-alertmanager-post.out || true
    exit 1
    ;;
esac

sleep 2

curl -fsS \
  "${AM_URL}/api/v2/alerts?active=true&silenced=false&inhibited=false" \
  > "$JSON"

COUNT="$(
  jq '[.[] | select(.labels.alertname == "NovaBankV03Evidence")] | length' "$JSON"
)"

echo "ACTIVE_TEST_ALERTS=$COUNT"
if [ "$COUNT" -lt 1 ]; then
  echo "ALERTMANAGER_EVIDENCE=FAILED"
  exit 1
fi

jq '
  .[]
  | select(.labels.alertname == "NovaBankV03Evidence")
  | {
      labels,
      annotations,
      startsAt,
      endsAt,
      status: .status.state
    }
' "$JSON"

# Resolve the synthetic alert immediately.
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --arg starts "$STARTS_AT" \
  --arg ends "$NOW" \
  '[
    {
      labels: {
        alertname: "NovaBankV03Evidence",
        severity: "warning",
        source: "manual-validation"
      },
      annotations: {
        summary: "NovaBank V0.3 Alertmanager validation"
      },
      startsAt: $starts,
      endsAt: $ends
    }
  ]' > "$PAYLOAD"

curl -fsS \
  -H 'Content-Type: application/json' \
  --data-binary "@$PAYLOAD" \
  "${AM_URL}/api/v2/alerts" >/dev/null

echo "ALERTMANAGER_EVIDENCE=OK"
echo "EVIDENCE_FILE=$OUT"
