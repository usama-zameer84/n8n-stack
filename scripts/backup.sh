#!/usr/bin/env bash
set -euo pipefail

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

stamp="$(date +%Y%m%d-%H%M%S)"
out="$BACKUP_DIR/n8n-$stamp.sql.gz"

if ! docker compose -f "$ROOT_DIR/docker-compose.yml" ps postgres | grep -q "Up\|healthy"; then
  echo "postgres container not running — start the stack with 'make up' first." >&2
  exit 1
fi

echo "Dumping ${POSTGRES_DB} -> $out"
docker compose -f "$ROOT_DIR/docker-compose.yml" exec -T postgres \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  | gzip > "$out"

# Prune old backups
ls -1t "$BACKUP_DIR"/n8n-*.sql.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  echo "Pruning $old"
  rm -f "$old"
done

echo "Done."