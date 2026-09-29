#!/bin/sh
set -eu

TS="$(date -u +%Y-%m-%dT%H%M%SZ)"
DUMP="/tmp/novabank_db-${TS}.dump"
SHA="/tmp/novabank_db-${TS}.dump.sha256"

echo "Starting pg_dump"

PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
  -U "${POSTGRES_USER}" \
  -d "${POSTGRES_DB}" \
  -Fc \
  -f "${DUMP}"

sha256sum "${DUMP}" > "${SHA}"

ENDPOINT_HOST="${AWS_ENDPOINTS#http://}"
ENDPOINT_HOST="${ENDPOINT_HOST#https://}"

case "${AWS_ENDPOINTS}" in
  https://*)
    MC_SCHEME="https"
    ;;
  *)
    MC_SCHEME="http"
    ;;
esac

export MC_HOST_backup="${MC_SCHEME}://${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}@${ENDPOINT_HOST}"

DEST="backup/novabank-longhorn-backups/postgresql/${TS}"

echo "Uploading PostgreSQL backup"

mc cp \
  "${DUMP}" \
  "${DEST}/novabank_db.dump"

mc cp \
  "${SHA}" \
  "${DEST}/novabank_db.dump.sha256"

echo "Verifying remote object"

mc stat "${DEST}/novabank_db.dump"
mc stat "${DEST}/novabank_db.dump.sha256"

echo "PostgreSQL backup completed successfully"
