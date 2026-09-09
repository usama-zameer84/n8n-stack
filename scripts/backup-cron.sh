#!/bin/sh
# Runs INSIDE the n8n-backup sidecar container on an hourly crond schedule.
# Produces the same paired snapshots as the host scripts/backup.sh so the
# auto-restore path (scripts/20-restore.sh + the n8n-restore one-shot) can
# consume them unchanged:
#   /backups/n8n-<ts>.sql.gz        — n8n internal DB (workflows, executions, users, creds)
#   /backups/workflows-<ts>.sql.gz  — separate workflow-data DB (Postgres node data)
#   /backups/n8n-data-<ts>.tar.gz   — contents of the n8n_data volume (/home/node/.n8n)
# Timestamps are YYYYMMDD-HHMMSS so lexical sort == chronological.
#
# POSIX sh (busybox ash) on alpine — no bashisms, no pipefail (dump-to-temp
# then gzip so a failed pg_dump is caught by `set -e` rather than masked by
# gzip's exit code).

set -eu

ENV_FILE="${ENV_FILE:-/etc/backup.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

: "${POSTGRES_HOST:=postgres}"
: "${POSTGRES_USER:?POSTGRES_USER required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required}"
: "${POSTGRES_DB:=n8n}"
: "${WORKFLOW_DB:=workflows}"
: "${BACKUP_KEEP:=30}"

BACKUP_DIR="${BACKUP_DIR:-/backups}"
N8N_DATA_DIR="${N8N_DATA_DIR:-/n8n-data}"
mkdir -p "$BACKUP_DIR"

# Clean up any partial temp files on exit (success or failure).
trap 'rm -f "$BACKUP_DIR"/*.tmp "$BACKUP_DIR"/*.tmp.gz 2>/dev/null || true' EXIT

stamp="$(date +%Y%m%d-%H%M%S)"

# Dump one Postgres DB to a temp file, gzip, rename. Dumping to temp first
# means a pg_dump failure aborts (set -e) before we produce a valid-gzip-
# but-truncated .sql.gz that would silently pass the verify header check.
dump_db() {
  _db="$1"; _out="$2"; _tmp="${2%.gz}.tmp"
  echo "[$stamp] dumping $_db -> $(basename "$_out")"
  PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d "$_db" > "$_tmp"
  gzip "$_tmp"
  mv "$_tmp.gz" "$_out"
}

out_n8n="$BACKUP_DIR/n8n-$stamp.sql.gz"
dump_db "$POSTGRES_DB" "$out_n8n"

out_wf="$BACKUP_DIR/workflows-$stamp.sql.gz"
dump_db "$WORKFLOW_DB" "$out_wf"

out_data="$BACKUP_DIR/n8n-data-$stamp.tar.gz"
echo "[$stamp] archiving n8n_data -> $(basename "$out_data")"
tar czf "$out_data" -C "$N8N_DATA_DIR" .

# Prune as a paired set by timestamp, keep newest BACKUP_KEEP.
# Collect every timestamp that appears on any backup file.
ts_list=$(
  {
    ls -1 "$BACKUP_DIR"/n8n-*.sql.gz        2>/dev/null
    ls -1 "$BACKUP_DIR"/workflows-*.sql.gz  2>/dev/null
    ls -1 "$BACKUP_DIR"/n8n-data-*.tar.gz   2>/dev/null
  } | sed -E 's#.*/(n8n-data-|n8n-|workflows-)##; s/\.(sql|tar)\.gz$//' | sort -u
)
total=$(printf '%s\n' "$ts_list" | grep -c . || true)
if [ "$total" -gt "$BACKUP_KEEP" ]; then
  prune_n=$((total - BACKUP_KEEP))
  i=0
  for ts in $ts_list; do
    i=$((i + 1))
    [ "$i" -le "$prune_n" ] || break
    for f in "$BACKUP_DIR/n8n-$ts.sql.gz" "$BACKUP_DIR/workflows-$ts.sql.gz" "$BACKUP_DIR/n8n-data-$ts.tar.gz"; do
      [ -f "$f" ] && { echo "[$stamp] pruning $(basename "$f")"; rm -f "$f"; }
    done
  done
fi

echo "[$stamp] done"
