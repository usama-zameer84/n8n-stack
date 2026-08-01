# n8n-stack

Single-node n8n deployment with Postgres persistence, exposed to the internet via a Cloudflare Tunnel. No inbound host ports required — traffic egresses from the host to Cloudflare's edge over an outbound tunnel.

## Services

| Service | Image | Purpose |
|---|---|---|
| `n8n` | `n8nio/n8n:latest` | Workflow automation UI + executor |
| `postgres` | `postgres:16-alpine` | Stores workflows, credentials, executions |
| `cloudflared` | `cloudflare/cloudflared:latest` | Outbound tunnel to Cloudflare edge; terminates public TLS at edge |

No host ports are published. n8n (5678) and Postgres (5432) are internal to the `n8n-net` bridge network; cloudflared proxies inbound requests from the tunnel to `http://n8n:5678`.

## Architecture

```
Internet ──HTTPS──▶ Cloudflare edge ──tunnel──▶ cloudflared ──HTTP──▶ n8n ──5432──▶ Postgres
                   (TLS terminates here)        (outbound only)        (internal)
```

The DNS CNAME for `${DOMAIN}` points at `<tunnel-id>.cfargotunnel.com` (created automatically by `tunnel-setup.sh`). Cloudflare's edge terminates TLS, so no Let's Encrypt / cert management is needed on the host.

## Prerequisites

- Docker + Docker Compose v2
- `cloudflared` CLI on the host (only for the one-time `tunnel-setup` step): `brew install cloudflared`
- A Cloudflare API token with:
  - Account → `Cloudflare Tunnel` → Edit
  - Zone → `DNS` → Edit (for your domain)

## Quickstart

```bash
make init-env          # generates .env with strong Postgres + n8n secrets
$EDITOR .env           # fill in CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, DOMAIN, TIMEZONE
make tunnel-setup      # creates tunnel + DNS CNAME, writes cloudflared/config.yml + credentials.json
make up                # start the stack
```

Once `cloudflared` connects, `https://${DOMAIN}` serves n8n.

## Common operations

```bash
make logs              # all services
make logs-n8n          # n8n only
make logs-tunnel       # cloudflared connection log
make psql              # interactive Postgres shell
make backup            # pg_dump to backups/ (gzipped, keeps last 30)
make upgrade           # backup + pull + restart
make down              # stop, keep volumes
make status            # show container status
```

## MCP access for users

Instance-level MCP is enabled by the stack (`N8N_MCP_ACCESS_ENABLED=true` in `.env`, applied by `docker-compose.yml`). The n8n remote MCP server exposes workflows as MCP tools at:

```
https://${DOMAIN}/mcp-server/http
```

Authentication is a **per-user access token** (not the n8n Public API key).

### Owner: invite users

1. Log in as owner → **Settings → Users → Invite**.
2. n8n shows an invite link (no SMTP is configured). Copy it and send it to the user out-of-band.
3. The user follows the link, sets a password, and gets their own workflows/credentials.

To disable MCP for the whole instance, set `N8N_MCP_ACCESS_ENABLED=false` in `.env` and `make restart`. (The on/off toggle in the UI is locked because `N8N_MCP_MANAGED_BY_ENV=true`.)

### User: generate your access token

1. Log in at `https://${DOMAIN}` → **Settings → Instance-level MCP → Access Token** tab.
2. Copy the auto-generated token immediately. It is shown **once** and redacted afterward. If you lose it, generate a new one here (the old one is revoked).

### User: expose workflows as MCP tools

n8n does **not** auto-expose all workflows. Enable the ones you want available:

- **Per workflow**: open the workflow → `...` menu → **Settings** → toggle **Available in MCP**.
- **Per project/folder** (bulk): project **Options** menu → **Manage MCP access** → **Enable MCP**.

You only see workflows you already have access to.

### User: connect an MCP client

All clients use the same endpoint and `Authorization: Bearer <YOUR_TOKEN>` header. Replace `<YOUR_TOKEN>` with your access token.

**Claude Desktop** (via the `supergateway` streamable-HTTP bridge):

```json
{
  "mcpServers": {
    "n8n-mcp": {
      "command": "npx",
      "args": [
        "-y", "supergateway",
        "--streamableHttp", "https://${DOMAIN}/mcp-server/http",
        "--header", "Authorization:Bearer <YOUR_TOKEN>"
      ]
    }
  }
}
```

**Claude Code**:

```bash
claude mcp add --transport http n8n-mcp https://${DOMAIN}/mcp-server/http \
  --header "Authorization: Bearer <YOUR_TOKEN>"
```

**Cursor / other streamable-HTTP clients**: set the server URL to `https://${DOMAIN}/mcp-server/http` and add the header `Authorization: Bearer <YOUR_TOKEN>`.

## Backup & restore

`make backup` writes `backups/n8n-YYYYMMDD-HHMMSS.sql.gz` and prunes to the last `BACKUP_KEEP` (default 30) files.

Restore (run from repo root):

```bash
gunzip -c backups/n8n-<stamp>.sql.gz | \
  docker compose exec -T postgres psql -U "$$(grep POSTGRES_USER .env | cut -d= -f2)" -d "$$(grep POSTGRES_DB .env | cut -d= -f2)"
```

## Upgrading n8n

```bash
make upgrade   # backs up DB, pulls n8nio/n8n:latest, recreates
```

Pin a specific version by editing `docker-compose.yml` (`image: n8nio/n8n:<version>`) for reproducible upgrades.

## Troubleshooting

**`cloudflared` won't connect, logs show "tunnel not found" / auth errors**
- Verify `CLOUDFLARE_API_TOKEN` in `.env` is valid and scoped to Tunnel:Edit + DNS:Edit.
- Check `cloudflared/credentials.json` exists — if not, re-run `make tunnel-setup`.
- The tunnel must exist on the account; `make tunnel-setup` creates it. If you deleted the tunnel via the Cloudflare dashboard, delete `cloudflared/credentials.json` and re-run setup.

**DNS isn't resolving**
- `cloudflared tunnel route dns` creates a CNAME `${DOMAIN}` → `<tunnel-id>.cfargotunnel.com`. Check the Cloudflare dashboard DNS tab. The record should be proxied (orange cloud).
- DNS propagation is usually <30s on Cloudflare.

**n8n webhooks use wrong URL**
- `WEBHOOK_URL` is built from `${DOMAIN}` in `docker-compose.yml`. If you change `DOMAIN`, run `make down && make up` to pick up the new value.

**`N8N_ENCRYPTION_KEY` lost**
- This key encrypts stored credentials. If lost (e.g. `make clean` without backing up `.env`), all credentials in the DB become unrecoverable. Keep `.env` in a password manager or off-host backup.

**Want to expose a different/additional hostname**
- Add more `ingress` entries to `cloudflared/config.yml` mapping hostnames to services, then `make restart`.

## Layout

```
.
├── docker-compose.yml
├── .env.example
├── .env                  # generated; holds secrets + Cloudflare token
├── Makefile
├── cloudflared/          # gitignored — created by tunnel-setup.sh
│   ├── credentials.json  # tunnel credentials (secret)
│   └── config.yml        # ingress rules
├── scripts/
│   ├── init-env.sh       # generates Postgres/n8n secrets -> .env
│   ├── init-db.sh        # creates non-root Postgres role on first init
│   ├── tunnel-setup.sh   # creates tunnel + DNS, writes cloudflared/ files
│   └── backup.sh         # pg_dump wrapper
└── backups/              # created on first backup
```

## Security notes

- `.env` and `cloudflared/` are gitignored — both contain secrets. Never commit them.
- Rotate the Cloudflare API token if it's ever leaked (dash.cloudflare.com → My Profile → API Tokens → Roll).
- The tunnel hides your host's public IP; no inbound ports need to be open.
- The `/mcp-server/http` endpoint is public via the tunnel but token-gated per user: only invited users can obtain a token. To separately disable the n8n Public REST API (`/api/v1`) if you don't use it, set `N8N_PUBLIC_API_DISABLED=true` in `.env` and `make restart`.