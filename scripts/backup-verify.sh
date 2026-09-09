#!/usr/bin/env bash
# Sanity-check the newest backup without restoring anything.
# Confirms each file is a valid gzip/tar and that SQL dumps carry the standard
# pg_dump header (i.e. they're real Postgres dumps, not truncated junk).
# Run with: make backup-verify

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$ROOT_DIR/backups"

if [[ ! -d "$BACKUP_DIR" || -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
  echo "No backups in $BACKUP_DIR — run 'make backup' first." >&2
  exit 1
fi

ok=0; bad=0

check_gzip() {
  local f="$1" label="$2"
  if [[ ! -f "$f" ]]; then
    echo "  MISSING  $label  ($(basename "$f"))"; bad=$((bad+1)); return
  fi
  if gzip -t "$f" 2>/dev/null; then
    echo "  OK       $label  ($(du -h "$f" | cut -f1))  $(basename "$f")"; ok=$((ok+1))
  else
    echo "  CORRUPT  $label  ($(basename "$f")) — gzip -t failed"; bad=$((bad+1)); return
  fi
}

check_sqldump() {
  local f="$1" label="$2"
  # Plain-text pg_dump output starts with a header comment like:
  #   -- PostgreSQL database dump
  # Verify that marker is present in the first 50 decompressed lines.
  # NOTE: temporarily disable pipefail — `grep -q` exits 0 as soon as it
  # matches, which closes the pipe and makes `gunzip`/`head` exit SIGPIPE
  # (141). Under `set -o pipefail` that non-zero propagates and falsely
  # reports the header as missing even when it was found.
  local rc
  set +o pipefail
  gunzip -c "$f" 2>/dev/null | head -n 50 | grep -q "PostgreSQL database dump"
  rc=$?
  set -o pipefail
  if [[ $rc -ne 0 ]]; then
    echo "  WARN     $label  ($(basename "$f")) — missing pg_dump header, dump may be incomplete"; bad=$((bad+1))
  else
    ok=$((ok+1))
  fi
}

check_tar() {
  local f="$1" label="$2"
  if [[ ! -f "$f" ]]; then
    echo "  MISSING  $label  ($(basename "$f"))"; bad=$((bad+1)); return
  fi
  if gzip -t "$f" 2>/dev/null && tar tzf "$f" >/dev/null 2>&1; then
    echo "  OK       $label  ($(du -h "$f" | cut -f1))  $(basename "$f")"; ok=$((ok+1))
  else
    echo "  CORRUPT  $label  ($(basename "$f")) — tar tzf failed"; bad=$((bad+1))
  fi
}

# Newest n8n dump drives the timestamp pairing.
n8n_dump="$(ls -1 "$BACKUP_DIR"/n8n-*.sql.gz 2>/dev/null | sort | tail -n 1 || true)"
if [[ -z "$n8n_dump" ]]; then
  echo "No n8n-*.sql.gz in $BACKUP_DIR." >&2; exit 1
fi
ts="$(basename "$n8n_dump")"; ts="${ts#n8n-}"; ts="${ts%.sql.gz}"
wf_dump="$BACKUP_DIR/workflows-$ts.sql.gz"
data_dump="$BACKUP_DIR/n8n-data-$ts.tar.gz"

echo "Newest snapshot: $ts"
check_gzip   "$n8n_dump"   "n8n DB dump"
check_sqldump "$n8n_dump"  "n8n DB dump"
check_gzip   "$wf_dump"    "workflows DB dump"
check_sqldump "$wf_dump"   "workflows DB dump"
[[ -f "$data_dump" ]] && check_tar "$data_dump" "n8n_data archive"

echo
if [[ $bad -eq 0 ]]; then
  echo "Verified $ok check(s). Snapshot $ts looks intact."
else
  echo "Verified $ok check(s); $bad problem(s) found." >&2
  exit 1
fi