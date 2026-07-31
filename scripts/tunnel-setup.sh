#!/usr/bin/env bash
# One-shot: creates a Cloudflare named tunnel + DNS CNAME for ${DOMAIN},
# writes credentials.json and config.yml into ./cloudflared/ for the
# cloudflared compose service to mount.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/.env"
CF_DIR="$ROOT_DIR/cloudflared"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing .env — run 'make init-env' first." >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN not set in .env}"
: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID not set in .env}"
: "${TUNNEL_NAME:?TUNNEL_NAME not set in .env}"
: "${DOMAIN:?DOMAIN not set in .env}"

export CLOUDFLARE_API_TOKEN

mkdir -p "$CF_DIR"

if [[ -f "$CF_DIR/credentials.json" ]]; then
  echo "Found existing credentials.json — skipping tunnel creation."
  echo "To recreate, delete $CF_DIR/credentials.json and re-run."
else
  echo "Creating tunnel '${TUNNEL_NAME}'..."
  cloudflared tunnel create --cred-file "$CF_DIR/credentials.json" "$TUNNEL_NAME"
fi

TUNNEL_ID="$(jq -r .TunnelID "$CF_DIR/credentials.json")"
echo "Tunnel ID: $TUNNEL_ID"

# Route DNS by explicit tunnel ID (not name) — a deleted tunnel with the same
# name can otherwise resolve ambiguously and the CNAME ends up pointing at the
# wrong (dead) tunnel. -f overwrites any existing record at this hostname.
echo "Routing DNS CNAME ${DOMAIN} -> ${TUNNEL_ID}.cfargotunnel.com..."
if cloudflared tunnel route dns -f "$TUNNEL_ID" "$DOMAIN" 2>&1 | tee /tmp/cf-route.log; then
  :
else
  if grep -qiE "already exists|record already exists|A similar record exists" /tmp/cf-route.log; then
    echo "DNS record already exists, continuing."
  else
    echo "Failed to route DNS." >&2
    exit 1
  fi
fi

echo "Writing $CF_DIR/config.yml..."
cat > "$CF_DIR/config.yml" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - hostname: ${DOMAIN}
    service: http://n8n:5678
  - service: http_status:404
EOF

echo ""
echo "Done. Credentials + config written to $CF_DIR/"
echo "Next: make up"