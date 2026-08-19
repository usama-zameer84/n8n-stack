#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/.env"
EXAMPLE="$ROOT_DIR/.env.example"

force=0
for arg in "$@"; do
  case "$arg" in
    --force|-f) force=1 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ -f "$ENV_FILE" && "$force" -eq 0 ]]; then
  echo "Refusing to overwrite existing .env (pass --force to override)." >&2
  exit 1
fi

gen_secret() { openssl rand -hex 32; }

ENCRYPTION_KEY="$(gen_secret)"
PG_PW="$(gen_secret)"
PG_APP_PW="$(gen_secret)"
WORKFLOW_PW="$(gen_secret)"

cp "$EXAMPLE" "$ENV_FILE"

# Substitute secrets into the .env file
# We use a temp sed-free approach with awk to handle special characters safely.
awk -v ek="$ENCRYPTION_KEY" -v pw="$PG_PW" -v apw="$PG_APP_PW" -v wfw_pw="$WORKFLOW_PW" '
  /^N8N_ENCRYPTION_KEY=/{print "N8N_ENCRYPTION_KEY=" ek; next}
  /^POSTGRES_PASSWORD=/{print "POSTGRES_PASSWORD=" pw; next}
  /^POSTGRES_NON_ROOT_PASSWORD=/{print "POSTGRES_NON_ROOT_PASSWORD=" apw; next}
  /^WORKFLOW_DB_PASSWORD=/{print "WORKFLOW_DB_PASSWORD=" wfw_pw; next}
  {print}
' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"

chmod 600 "$ENV_FILE"

echo "Wrote $ENV_FILE with generated secrets."
echo ""
echo "IMPORTANT:"
echo "  - Edit DOMAIN and EMAIL in $ENV_FILE before 'make up'."
echo "  - Back up .env somewhere safe. N8N_ENCRYPTION_KEY is non-recoverable."