#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/opt/novabank}"
NS="${NS:-novabank-app}"
CRONJOB="${CRONJOB:-novabank-postgres-backup}"
OUT_DIR="${OUT_DIR:-$ROOT/evidence/v03}"
mkdir -p "$OUT_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/rpo-rto-${STAMP}.txt"
BACKUP_LOG="$OUT_DIR/rpo-rto-backup-${STAMP}.log"
RESTORE_LOG="$OUT_DIR/rpo-rto-restore-${STAMP}.log"

exec > >(tee -a "$OUT") 2>&1

echo "=== RPO / RTO MEASUREMENT ==="
echo "UTC=$STAMP"
echo "NAMESPACE=$NS"
echo "CRONJOB=$CRONJOB"

SCHEDULE="$(
  kubectl -n "$NS" get cronjob "$CRONJOB" \
    -o jsonpath='{.spec.schedule}'
)"
echo "BACKUP_SCHEDULE=$SCHEDULE"

CRONJOB_JSON="$(
  kubectl -n "$NS" get cronjob "$CRONJOB" -o json
)"

LATEST_SCHEDULE_TIME="$(
  printf '%s' "$CRONJOB_JSON" |
  jq -r '.status.lastScheduleTime // empty'
)"

LATEST_SUCCESS="$(
  printf '%s' "$CRONJOB_JSON" |
  jq -r '.status.lastSuccessfulTime // empty'
)"

NOW_EPOCH="$(date -u +%s)"

echo "RPO_CONFIGURED_MAX_SECONDS=86400"
echo "RPO_CONFIGURED_MAX_HOURS=24"

if [ -n "$LATEST_SCHEDULE_TIME" ]; then
  echo "LAST_CRON_SCHEDULE_TIME=$LATEST_SCHEDULE_TIME"
else
  echo "LAST_CRON_SCHEDULE_TIME=NOT_AVAILABLE"
fi

if [ -n "$LATEST_SUCCESS" ]; then
  SUCCESS_EPOCH="$(date -u -d "$LATEST_SUCCESS" +%s)"
  RPO_SECONDS="$((NOW_EPOCH - SUCCESS_EPOCH))"

  echo "LATEST_SUCCESSFUL_RECOVERY_POINT=$LATEST_SUCCESS"
  echo "RPO_OBSERVED_SECONDS=$RPO_SECONDS"
  printf 'RPO_OBSERVED_HMS=%02d:%02d:%02d\n' \
    "$((RPO_SECONDS / 3600))" \
    "$(((RPO_SECONDS % 3600) / 60))" \
    "$((RPO_SECONDS % 60))"
else
  echo "LATEST_SUCCESSFUL_RECOVERY_POINT=NOT_AVAILABLE"
  echo "RPO_OBSERVED=NOT_MEASURABLE"
fi

echo
echo "=== CREATE CONTROLLED RECOVERY POINT ==="

BACKUP_JOB="novabank-rto-source-${STAMP,,}"
BACKUP_JOB="${BACKUP_JOB//:/-}"

BACKUP_START="$(date -u +%s)"

kubectl -n "$NS" create job \
  --from="cronjob/$CRONJOB" \
  "$BACKUP_JOB"

if ! kubectl -n "$NS" wait \
  --for=condition=complete \
  "job/$BACKUP_JOB" \
  --timeout=240s; then
  echo "BACKUP_FOR_RTO=FAILED"
  kubectl -n "$NS" logs "job/$BACKUP_JOB" || true
  exit 1
fi

BACKUP_END="$(date -u +%s)"
kubectl -n "$NS" logs "job/$BACKUP_JOB" | tee "$BACKUP_LOG"

echo "BACKUP_CREATION_SECONDS=$((BACKUP_END - BACKUP_START))"

BACKUP_TS="$(
  grep -Eo 'novabank_db-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z\.dump' "$BACKUP_LOG" \
  | head -1 \
  | sed -E 's/^novabank_db-(.*)\.dump$/\1/'
)"

if [ -z "$BACKUP_TS" ]; then
  echo "BACKUP_TIMESTAMP=NOT_FOUND"
  exit 1
fi

echo "RECOVERY_POINT=$BACKUP_TS"

BACKUP_IMAGE="$(
  kubectl -n "$NS" get cronjob "$CRONJOB" \
    -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}'
)"
echo "RESTORE_IMAGE=$BACKUP_IMAGE"

RESTORE_JOB="novabank-rto-restore-${STAMP,,}"
RESTORE_JOB="${RESTORE_JOB//:/-}"

echo
echo "=== ISOLATED RESTORE TEST ==="
RTO_START="$(date -u +%s)"

cat <<YAML | kubectl -n "$NS" apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${RESTORE_JOB}
  labels:
    app: novabank
    component: rto-restore-test
spec:
  activeDeadlineSeconds: 300
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: novabank
        component: rto-restore-test
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: restore
          image: ${BACKUP_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -ec
          args:
            - |
              set -eu

              LOCAL_START="\$(date +%s)"

              ENDPOINT_HOST="\${AWS_ENDPOINTS#http://}"
              ENDPOINT_HOST="\${ENDPOINT_HOST#https://}"

              case "\${AWS_ENDPOINTS}" in
                https://*) MC_SCHEME="https" ;;
                *) MC_SCHEME="http" ;;
              esac

              export MC_HOST_backup="\${MC_SCHEME}://\${AWS_ACCESS_KEY_ID}:\${AWS_SECRET_ACCESS_KEY}@\${ENDPOINT_HOST}"

              SOURCE="backup/novabank-longhorn-backups/postgresql/\${BACKUP_TS}/novabank_db.dump"
              echo "RESTORE_SOURCE=\${SOURCE}"

              mc cp "\${SOURCE}" /tmp/restore.dump

              rm -rf /tmp/pgdata
              mkdir -p /tmp/pgdata

              initdb -D /tmp/pgdata -A trust >/dev/null

              pg_ctl \
                -D /tmp/pgdata \
                -o "-k /tmp -p 55432" \
                -w start >/dev/null

              createdb \
                -h /tmp \
                -p 55432 \
                novabank_restore

              pg_restore \
                --exit-on-error \
                --no-owner \
                -h /tmp \
                -p 55432 \
                -d novabank_restore \
                /tmp/restore.dump

              RESULT="\$(psql \
                -h /tmp \
                -p 55432 \
                -d novabank_restore \
                -Atc 'SELECT 1')"

              test "\${RESULT}" = "1"

              LOCAL_END="\$(date +%s)"
              echo "RESTORE_DB=OK"
              echo "RESTORE_IN_POD_SECONDS=\$((LOCAL_END - LOCAL_START))"

              pg_ctl \
                -D /tmp/pgdata \
                -m fast \
                -w stop >/dev/null
          env:
            - name: BACKUP_TS
              value: "${BACKUP_TS}"
          envFrom:
            - secretRef:
                name: novabank-postgres-backup-credentials
            - secretRef:
                name: novabank-postgres-backup-minio
YAML

if ! kubectl -n "$NS" wait \
  --for=condition=complete \
  "job/$RESTORE_JOB" \
  --timeout=300s; then
  echo "RESTORE_JOB=FAILED"
  kubectl -n "$NS" logs "job/$RESTORE_JOB" || true
  exit 1
fi

RTO_END="$(date -u +%s)"
kubectl -n "$NS" logs "job/$RESTORE_JOB" | tee "$RESTORE_LOG"

grep -q '^RESTORE_DB=OK$' "$RESTORE_LOG"
echo "RTO_OBSERVED_SECONDS=$((RTO_END - RTO_START))"
echo "RTO_MEASUREMENT=OK"

kubectl -n "$NS" delete job "$RESTORE_JOB" --wait=false >/dev/null
kubectl -n "$NS" delete job "$BACKUP_JOB" --wait=false >/dev/null

echo "EVIDENCE_FILE=$OUT"
