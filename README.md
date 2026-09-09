# n8n-stack

Single-node n8n deployment with Postgres persistence, exposed to the internet via a Cloudflare Tunnel. No inbound host ports required — traffic egresses from the host to Cloudflare's edge over an outbound tunnel.

## Services

| Service | Image | Purpose |
|---|---|---|
| `n8n` | `n8nio/n8n:latest` | Workflow automation UI + executor |
| `postgres` | `postgres:16-alpine` | Stores workflows, credentials, executions |
| `cloudflared` | `cloudflare/cloudflared:latest` | Outbound tunnel to Cloudflare edge; terminates public TLS at edge |
| `n8n-restore` | `alpine:3.20` | One-shot: restores `n8n_data` from backup on fresh init only |

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
make backup            # snapshot n8n + workflows DBs and n8n_data to backups/
make backup-list       # list backups
make backup-verify     # integrity-check the newest backup
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

## Backup & recovery

`make backup` snapshots the full stack state into `backups/` as a timestamped set (kept in sync and pruned together to the last `BACKUP_KEEP`, default 30):

- `n8n-<ts>.sql.gz` — n8n's internal Postgres DB (workflows, executions, users, stored credentials)
- `workflows-<ts>.sql.gz` — the separate workflow-data DB (Postgres node data)
- `n8n-data-<ts>.tar.gz` — `/home/node/.n8n` from the n8n container (logs, uploads, local config)

### Seamless restore on volume loss

Restore is **automatic on fresh init** — no manual step needed. If a Docker volume is removed (or you move to a new host with the `backups/` folder in place), `make up` brings the stack back with data:

- `pg_data` volume empty → the Postgres entrypoint runs `scripts/20-restore.sh`, which loads the newest `n8n-*.sql.gz` + matching `workflows-*.sql.gz` before n8n connects. If no backup exists, it exits cleanly and you get a fresh install.
- `n8n_data` volume empty → the one-shot `n8n-restore` container extracts the newest `n8n-data-*.tar.gz` into the volume before n8n starts. If the volume already has data, or no backup exists, it does nothing.

So the recovery flow is simply:

```bash
make backup                 # take a snapshot before anything drastic
docker compose down -v      # destroys volumes
make up                     # Postgres + n8n-restore auto-restore the newest snapshot, then n8n starts
```

On normal restarts (volumes intact) neither restore path runs — the entrypoint init scripts only fire on an empty data directory, and `n8n-restore` only acts on an empty volume.

### Verifying a backup

```bash
make backup-verify          # gzip integrity + pg_dump header check on the newest snapshot
make backup-list            # list what's in backups/
```

### Manual restore (advanced)

Only needed if you want to restore a *specific* snapshot onto a *running* database (destructive — overwrites current data):

```bash
stamp=20260829-143000
docker compose exec -T postgres psql -U "$$(grep POSTGRES_USER .env | cut -d= -f2)" -d "$$(grep POSTGRES_DB .env | cut -d= -f2)" < <(gunzip -c backups/n8n-$stamp.sql.gz)
docker compose exec -T postgres psql -U "$$(grep POSTGRES_USER .env | cut -d= -f2)" -d workflows < <(gunzip -c backups/workflows-$stamp.sql.gz)
```

## Connecting workflows to Postgres

The stack runs two databases inside the `postgres` container:

- `n8n` — n8n's internal state (executions, users, stored credentials). Don't write workflow data here.
- `workflows` — for the Postgres node in your workflows. Created by `scripts/init-db.sh` on first init, owned by the `workflow_app` user, isolated from the `n8n` database (no `CONNECT` on each other's DB).

When you add a **Postgres** credential in n8n, the host must be the Docker service name, not `localhost`:

| Field | Value |
|---|---|
| Host | `postgres` |
| Port | `5432` |
| Database | `workflows` |
| User | `workflow_app` |
| Password | `WORKFLOW_DB_PASSWORD` from `.env` |
| SSL | off (internal network) |

Typing `localhost` here gives "Connection refused" — the n8n container has no Postgres on its own loopback. To reach Postgres from the host instead, add `ports: ["127.0.0.1:5432:5432"]` to the `postgres` service in `docker-compose.yml`.

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
│   ├── init-db.sh        # creates non-root Postgres role + workflows DB on first init
│   ├── 20-restore.sh     # auto-restores newest backup on fresh Postgres init
│   ├── tunnel-setup.sh   # creates tunnel + DNS, writes cloudflared/ files
│   ├── backup.sh         # snapshots both DBs + n8n_data to backups/
│   └── backup-verify.sh  # integrity-checks the newest backup
└── backups/              # created on first backup (gitignored)
```

## Security notes

- `.env` and `cloudflared/` are gitignored — both contain secrets. Never commit them.
- Rotate the Cloudflare API token if it's ever leaked (dash.cloudflare.com → My Profile → API Tokens → Roll).
- The tunnel hides your host's public IP; no inbound ports need to be open.
- The `/mcp-server/http` endpoint is public via the tunnel but token-gated per user: only invited users can obtain a token. To separately disable the n8n Public REST API (`/api/v1`) if you don't use it, add `N8N_PUBLIC_API_DISABLED: true` to the n8n service environment in `docker-compose.yml`, then `make up`.
