# Design: User MCP access for the n8n-stack

**Date:** 2026-07-31
**Status:** Approved (pending user spec review)
**Approach:** A — enable instance-level MCP via environment variables (reproducible)

## Goal

Allow invited users of the self-hosted n8n instance to connect an MCP client (Claude Desktop, Claude Code, Cursor, or any streamable-HTTP MCP client) to their own n8n account, authenticated with a per-user access token, so they can run their workflows as MCP tools.

## Background (verified from n8n docs)

- n8n exposes a **remote MCP server** at the instance URL path `/mcp-server/http` (streamable HTTP transport).
- Instance-level MCP must be enabled (Settings → Instance-level MCP → "Enable MCP access", owner/admin), or via environment variables `N8N_MCP_ACCESS_ENABLED=true` + `N8N_MCP_MANAGED_BY_ENV=true` (n8n v2.20.0+).
- Authentication: each user generates a **personal access token** at Settings → Instance-level MCP → Access Token tab. Sent as `Authorization: Bearer <token>`. OAuth2 is also supported but out of scope here.
- **Workflows are not auto-exposed.** Each workflow must be enabled for MCP individually (workflow → `...` → Settings → "Available in MCP"), or in bulk per project/folder (n8n v2.24.0+). Users only see workflows they already have access to.
- The MCP access token is distinct from the n8n Public REST API key (Settings → API).
- To disable MCP entirely: `N8N_DISABLED_MODULES=mcp` (we do **not** set this).

## Architecture

The Cloudflare Tunnel already routes all traffic for `${DOMAIN}` to `http://n8n:5678` via a catch-all ingress rule, so the `/mcp-server/http` path is reachable with **no tunnel/ingress change**:

```
MCP client ──HTTPS──▶ Cloudflare edge ──tunnel──▶ cloudflared ──HTTP──▶ n8n:5678/mcp-server/http
                   (TLS terminates here)                                (streamable HTTP, Bearer auth)
```

## Changes

### 1. `docker-compose.yml` — n8n service environment

Add two variables, sourced from `.env` with safe defaults so existing `.env` files keep working:

```yaml
N8N_MCP_ACCESS_ENABLED: ${N8N_MCP_ACCESS_ENABLED:-true}
N8N_MCP_MANAGED_BY_ENV: ${N8N_MCP_MANAGED_BY_ENV:-true}
```

`N8N_MCP_MANAGED_BY_ENV=true` makes n8n apply the MCP env vars on every startup and locks the instance-level on/off toggle in the UI. Per-user token generation and per-workflow MCP enablement remain fully usable in the UI — only the on/off switch is locked.

### 2. `.env.example`

Document the MCP vars:

```
# ---- MCP access (users connect MCP clients to their n8n account) ----
# Instance-level MCP server endpoint: https://${DOMAIN}/mcp-server/http
# Auth: per-user access token (Settings > Instance-level MCP > Access Token).
N8N_MCP_ACCESS_ENABLED=true
N8N_MCP_MANAGED_BY_ENV=true
```

### 3. `scripts/init-env.sh`

No change. The script already copies `.env.example` verbatim (substituting only the generated secrets), so the `N8N_MCP_ACCESS_ENABLED=true` / `N8N_MCP_MANAGED_BY_ENV=true` values written into `.env.example` flow into `.env` automatically on `make init-env`. Additionally, because `docker-compose.yml` uses `${VAR:-true}` fallbacks, an existing `.env` lacking these keys still enables MCP — no forced regeneration required. No SMTP configuration is added.

### 4. `cloudflared/config.yml`

No change. The existing catch-all `service: http://n8n:5678` for the hostname serves `/mcp-server/http`.

### 5. `README.md`

Add a `## MCP access for users` section:
- Owner step: MCP is enabled by the stack env (no manual toggle needed). To invite users: Settings → Users → invite; n8n shows an invite link (no SMTP configured) for the owner to send to the user manually.
- User step 1: log in → Settings → Instance-level MCP → Access Token tab → copy the auto-generated token (shown once, redacted after; rotate here if lost).
- User step 2: expose workflows as tools — open a workflow → `...` → Settings → toggle "Available in MCP", or bulk-enable a project/folder via Options → Manage MCP access → Enable MCP. Note: n8n does not auto-expose all workflows.
- User step 3: configure the MCP client. Provide three snippets (Claude Desktop via `supergateway`, Claude Code CLI, Cursor/other streamable-HTTP clients) using `https://${DOMAIN}/mcp-server/http` and `Authorization: Bearer <USER_TOKEN>`.
- Add a security note in **Security notes**: `/mcp-server/http` is public via the tunnel but token-gated per user; only invited users can obtain a token; the public REST API can be separately disabled with `N8N_PUBLIC_API_DISABLED=true` if unused.

## User-facing flow

1. Owner confirms MCP is enabled (it is, via env). Optionally invites users.
2. User logs in at `https://${DOMAIN}`, generates their access token at Settings → Instance-level MCP → Access Token.
3. User enables workflows for MCP (per-workflow or per-project).
4. User points their MCP client at the endpoint with their token:
   - **Claude Desktop** (supergateway bridge):
     ```json
     "mcpServers": {
       "n8n-mcp": {
         "command": "npx",
         "args": ["-y", "supergateway",
           "--streamableHttp", "https://n8n.reaperautomate.work/mcp-server/http",
           "--header", "Authorization:Bearer <USER_TOKEN>"]
       }
     }
     ```
   - **Claude Code**: `claude mcp add --transport http n8n-mcp https://n8n.reaperautomate.work/mcp-server/http --header "Authorization: Bearer <USER_TOKEN>"`
   - **Cursor / other**: same URL + `Authorization: Bearer <USER_TOKEN>` header.

## Scope / non-goals

- n8n does not auto-expose all workflows; enablement is per-workflow or per-project. This is documented as a limitation, not worked around.
- Requires `n8nio/n8n:latest` ≥ v2.20.0 (current `latest` satisfies this); MCP env vars are no-ops on older versions.
- No code tests — this is config + docs. Correctness is verified post-deploy by hitting `https://${DOMAIN}/mcp-server/http` with a user token from an MCP client.
- OAuth2 auth for MCP is out of scope (access token only).
- The n8n Public REST API (`/api/v1`) is left enabled by default; disabling it is mentioned as optional hardening, not applied.

## Files touched

- `docker-compose.yml` — add 2 MCP env vars to n8n service.
- `.env.example` — MCP vars.
- `README.md` — new MCP section + security note.
- `scripts/init-env.sh` — no change (MCP defaults flow through via `.env.example` copy).
- `cloudflared/config.yml` — no change (documented as unchanged).