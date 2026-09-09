#!/usr/bin/env bash
set -euo pipefail

# Back up the full n8n stack state to ./backups/:
#   n8n-<ts>.sql.gz       — n8n's internal Postgres DB (executions, users, creds)
#   workflows-<ts>.sql.gz — the separate workflow-data DB (Postgres node creds)
#   n8n-data-<ts>.tar.gz  — /home/node/.n8n from the n8n container (logs, uploads, local config)
#
# All three share a timestamp so the restore path can pair them up and prune
# them as a set. Timestamps are YYYYMMDD-HHMMSS so lexical sort == chronological.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/.env"
BACKUP_DIR="$ROOT_DIR/backups"
KEEP="${BACKUP_KEEP:-30}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing .env — run 'make init-env' first." >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

mkdir -p "$BACKUP_DIR"

if ! docker compose -f "$ROOT_DIR/docker-compose.yml" ps postgres | grep -q "Up\|healthy"; then
  echo "postgres container not running — start the stack with 'make up' first." >&2
  exit 1
fi
if ! docker compose -f "$ROOT_DIR/docker-compose.yml" ps n8n | grep -q "Up"; then
  echo "n8n container not running — start the stack with 'make up' first." >&2
  exit 1
fi

COMPOSE="docker compose -f $ROOT_DIR/docker-compose.yml"
# UTC so host `make backup` stamps match the in-container sidecar (which
# runs in UTC) and the stack's TIMEZONE=UTC — keeps lexical-sort == real
# chronology across host and sidecar snapshots.
stamp="$(TZ=UTC date +%Y%m%d-%H%M%S)"

# ---- Postgres dumps ----
out_n8n="$BACKUP_DIR/n8n-$stamp.sql.gz"
echo "Dumping ${POSTGRES_DB} -> $out_n8n"
$COMPOSE exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  | gzip > "$out_n8n"

out_wf="$BACKUP_DIR/workflows-$stamp.sql.gz"
echo "Dumping ${WORKFLOW_DB} -> $out_wf"
$COMPOSE exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$WORKFLOW_DB" \
  | gzip > "$out_wf"

# ---- n8n_data volume (contents of /home/node/.n8n) ----
out_data="$BACKUP_DIR/n8n-data-$stamp.tar.gz"
echo "Archiving n8n_data volume -> $out_data"
$COMPOSE exec -T n8n tar czf - -C /home/node/.n8n . \
  > "$out_data"

# ---- Prune old backups as a paired set by timestamp ----
# Collect every timestamp that appears on any backup file, keep the newest $KEEP,
# delete all files belonging to older timestamps.
mapfile -t stamps < <(
  {
    for f in "$BACKUP_DIR"/n8n-*.sql.gz "$BACKUP_DIR"/workflows-*.sql.gz "$BACKUP_DIR"/n8n-data-*.tar.gz; do
      [[ -f "$f" ]] || continue
      b="$(basename "$f")"
      # strip leading prefix up to the timestamp: n8n- / workflows- / n8n-data-
      ts="${b#n8n-data-}"; ts="${ts#n8n-}"; ts="${ts#workflows-}"
      ts="${ts%.sql.gz}"; ts="${ts%.tar.gz}"
      echo "$ts"
    done
  } | sort -u
)

pruned=0
if [[ ${#stamps[@]} -gt $KEEP ]]; then
  for ts in "${stamps[@]:0:${#stamps[@]}-KEEP}"; do
    for f in \
      "$BACKUP_DIR/n8n-$ts.sql.gz" \
      "$BACKUP_DIR/workflows-$ts.sql.gz" \
      "$BACKUP_DIR/n8n-data-$ts.tar.gz"; do
      if [[ -f "$f" ]]; then
        echo "Pruning $(basename "$f")"
        rm -f "$f"
        pruned=$((pruned + 1))
      fi
    done
  done
fi
[[ $pruned -gt 0 ]] && echo "Pruned $pruned file(s) older than the newest $KEEP snapshots."

echo "Done. Snapshot: $stamp"
echo "  $out_n8n"
echo "  $out_wf"
echo "  $out_data"
