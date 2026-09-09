#!/usr/bin/env bash
# Auto-restore the newest backup into a freshly initialised Postgres.
# Mounted at /docker-entrypoint-initdb.d/20-restore.sh so it runs AFTER
# 10-init-db.sh (which creates the users + the workflows DB).
#
# docker-entrypoint-initdb.d scripts only run when PGDATA is empty — i.e. the
# pg_data volume was just created (fresh install, or volume was removed). On an
# existing volume this script never runs, so normal restarts are untouched.
#
# If no backup is present we exit cleanly and you get a fresh install, exactly
# as before this script existed.

set -euo pipefail

BACKUPS_DIR="${BACKUPS_DIR:-/backups}"

echo "[restore] looking for backups in $BACKUPS_DIR …"

# Newest n8n dump (timestamps sort lexically == chronologically).
n8n_dump="$(ls -1 "$BACKUPS_DIR"/n8n-*.sql.gz 2>/dev/null | sort | tail -n 1 || true)"

if [[ -z "$n8n_dump" ]]; then
  echo "[restore] no n8n-*.sql.gz found — proceeding with fresh install."
  exit 0
fi

# Derive the timestamp from the n8n dump and look for the matching workflows dump.
ts="$(basename "$n8n_dump")"      # n8n-20260829-143000.sql.gz
ts="${ts#n8n-}"                   # 20260829-143000.sql.gz
ts="${ts%.sql.gz}"                # 20260829-143000

wf_dump="$BACKUPS_DIR/workflows-$ts.sql.gz"

echo "[restore] restoring n8n DB ($POSTGRES_DB) from $(basename "$n8n_dump")"
gunzip -c "$n8n_dump" \
  | psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"

if [[ -f "$wf_dump" ]]; then
  echo "[restore] restoring workflows DB (${WORKFLOW_DB:-workflows}) from $(basename "$wf_dump")"
  gunzip -c "$wf_dump" \
    | psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "${WORKFLOW_DB:-workflows}"
else
  echo "[restore] WARN: no workflows-$ts.sql.gz paired with this snapshot — skipping workflows restore."
fi

echo "[restore] done."
