# User MCP Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable invited users to connect an MCP client (Claude Desktop, Claude Code, Cursor) to their own n8n account via the n8n remote MCP server, authenticated with a per-user access token.

**Architecture:** Instance-level MCP is enabled through environment variables in `docker-compose.yml` (sourced from `.env`, defaulted in `.env.example`). The existing Cloudflare Tunnel catch-all ingress already routes `/mcp-server/http` to n8n, so no tunnel or `init-env.sh` changes are needed. Users generate their own access token in the n8n UI and enable workflows for MCP per-workflow or per-project. README documents the end-to-end flow with client config snippets.

**Tech Stack:** Docker Compose, n8n (`n8nio/n8n:latest`, ≥ v2.20.0 for MCP env vars), Cloudflare Tunnel, Markdown docs.

**Spec:** `docs/superpowers/specs/2026-07-31-mcp-user-access-design.md`

## Global Constraints

- n8n image is `n8nio/n8n:latest` (satisfies the v2.20.0+ requirement for `N8N_MCP_*` env vars). Do not pin.
- Do NOT add `N8N_DISABLED_MODULES=mcp` anywhere — that disables MCP entirely.
- Do NOT add SMTP env vars — invites happen via the invite link the owner copies from Settings → Users.
- Do NOT modify `cloudflared/config.yml` or `scripts/init-env.sh`.
- No `Co-Authored-By: Claude` trailer in any commit (user is sole author).
- `.env` is gitignored and contains secrets — never edit or commit it; only `.env.example` changes.
- The instance domain (from `.env` `DOMAIN`) is referenced in README snippets as `https://${DOMAIN}/mcp-server/http`.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `docker-compose.yml` | Modify | Add `N8N_MCP_ACCESS_ENABLED` + `N8N_MCP_MANAGED_BY_ENV` to the `n8n` service environment block, sourced from `.env` with `:-true` fallback. |
| `.env.example` | Modify | Document the two MCP env vars with `true` defaults and a comment pointing to the endpoint/auth. |
| `README.md` | Modify | Add `## MCP access for users` section (owner enable + invite, user token, expose workflows, 3 client config snippets) and a security note. |

No new files. `cloudflared/config.yml` and `scripts/init-env.sh` are explicitly unchanged.

---

### Task 1: Enable instance-level MCP in docker-compose.yml

**Files:**
- Modify: `docker-compose.yml` (the `n8n:` service `environment:` block, currently lines 38-51)

**Interfaces:**
- Consumes: `N8N_MCP_ACCESS_ENABLED`, `N8N_MCP_MANAGED_BY_ENV` from `.env` (added in Task 2). The `${VAR:-true}` fallback means this task is independently verifiable even before `.env.example` is updated.
- Produces: A compose file whose `n8n` service passes both MCP env vars to the container.

- [ ] **Step 1: Add the two env vars to the n8n service**

In `docker-compose.yml`, inside the `n8n:` service `environment:` block, add the two lines below. Place them immediately after the `N8N_DIAGNOSTICS_ENABLED: false` line (before `N8N_PERSONALIZATION_ENABLED: false`), keeping alphabetical-ish grouping with the other `N8N_*` keys:

```yaml
      N8N_MCP_ACCESS_ENABLED: ${N8N_MCP_ACCESS_ENABLED:-true}
      N8N_MCP_MANAGED_BY_ENV: ${N8N_MCP_MANAGED_BY_ENV:-true}
```

- [ ] **Step 2: Validate the compose file parses**

Run: `docker compose config --quiet`
Expected: no output, exit code 0 (no YAML errors, no unresolved required vars).

- [ ] **Step 3: Confirm the vars are interpolated to true by default**

Run: `docker compose config | grep -E 'N8N_MCP_(ACCESS_ENABLED|MANAGED_BY_ENV)'`
Expected: two lines, both ending in `true` (the `${...:-true}` fallback resolves even though `.env` does not yet contain these keys):
```
N8N_MCP_ACCESS_ENABLED: true
N8N_MCP_MANAGED_BY_ENV: true
```

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: enable instance-level MCP server via env vars"
```

---

### Task 2: Document MCP env vars in .env.example

**Files:**
- Modify: `.env.example` (append after the basic-auth block, currently end of file at line 21)

**Interfaces:**
- Consumes: nothing.
- Produces: `N8N_MCP_ACCESS_ENABLED=true` and `N8N_MCP_MANAGED_BY_ENV=true` present in `.env.example`, which `scripts/init-env.sh` copies verbatim into `.env` on `make init-env`. Existing deployments without these keys still work via the compose `${VAR:-true}` fallback.

- [ ] **Step 1: Append the MCP block to .env.example**

Add the following to the end of `.env.example` (after the `N8N_BASIC_AUTH_PASSWORD=` line):

```
# ---- MCP access (users connect MCP clients to their n8n account) ----
# Instance-level MCP server endpoint: https://${DOMAIN}/mcp-server/http
# Auth: per-user access token (Settings > Instance-level MCP > Access Token).
# MANAGED_BY_ENV=true locks the on/off toggle in the UI; token + workflow
# enablement remain UI-driven.
N8N_MCP_ACCESS_ENABLED=true
N8N_MCP_MANAGED_BY_ENV=true
```

- [ ] **Step 2: Verify the file ends with the new block**

Run: `tail -8 .env.example`
Expected: the 6 comment/assignment lines above as the last lines, with `N8N_MCP_MANAGED_BY_ENV=true` as the final line.

- [ ] **Step 3: Verify a fresh .env generation carries the MCP defaults**

Run: `cp .env.example /tmp/env-mcp-check && grep -c 'N8N_MCP_ACCESS_ENABLED=true' /tmp/env-mcp-check && rm /tmp/env-mcp-check`
Expected: `1` (the key with value `true` is present, confirming init-env.sh's verbatim copy will carry it through). Do NOT run `make init-env` (it would overwrite the real `.env`).

- [ ] **Step 4: Confirm compose still resolves to true from the example values**

Run: `docker compose config | grep -E 'N8N_MCP_(ACCESS_ENABLED|MANAGED_BY_ENV)'`
Expected: both lines end in `true`.

- [ ] **Step 5: Commit**

```bash
git add .env.example
git commit -m "feat: document MCP env vars in .env.example"
```

---

### Task 3: Add MCP access section + security note to README

**Files:**
- Modify: `README.md` (insert a new `## MCP access for users` section; update the `## Security notes` section)

**Interfaces:**
- Consumes: the enabled MCP env vars (Task 1) and the documented endpoint (`https://${DOMAIN}/mcp-server/http`).
- Produces: end-user documentation for the owner (enable is automatic; invite users), and for each user (generate token, expose workflows, configure MCP client).

- [ ] **Step 1: Insert the MCP access section**

In `README.md`, insert the following new section immediately after the `## Common operations` section's closing fence (after the `make status` block, before `## Backup & restore`). The domain in the snippets is `https://${DOMAIN}/mcp-server/http` so it reads generically; the actual value is `https://n8n.reaperautomate.work/mcp-server/http` for this deployment.

````markdown
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
````

- [ ] **Step 2: Add the security note**

In `README.md`, append a bullet to the existing `## Security notes` list (currently the last section). Add after the existing "The tunnel hides your host's public IP..." bullet:

```markdown
- The `/mcp-server/http` endpoint is public via the tunnel but token-gated per user: only invited users can obtain a token. To separately disable the n8n Public REST API (`/api/v1`) if you don't use it, set `N8N_PUBLIC_API_DISABLED=true` in `.env` and `make restart`.
```

- [ ] **Step 3: Verify both additions landed**

Run: `grep -c "## MCP access for users" README.md && grep -c "mcp-server/http" README.md && grep -c "N8N_PUBLIC_API_DISABLED" README.md`
Expected: `1`, a count ≥ 4 (endpoint appears in section header text + 3 client snippets), `1`.

- [ ] **Step 4: Verify the Markdown renders cleanly (no broken code fences)**

Run: `awk '/^```/{c++} END{print c}' README.md`
Expected: an even number (every opening ``` has a closing ```).

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: add MCP access section for users + security note"
```

---

### Task 4: Live verification (manual, post-deploy)

**Files:** none (verification only).

**Interfaces:**
- Consumes: the running stack after `make up` with the new env vars applied.

- [ ] **Step 1: Apply the env changes to the running stack**

Run: `make restart`
Expected: n8n container restarts and picks up `N8N_MCP_ACCESS_ENABLED=true`.

- [ ] **Step 2: Confirm the endpoint is reachable and token-gated**

Run: `curl -s -o /dev/null -w '%{http_code}' https://${DOMAIN}/mcp-server/http`
Expected: an HTTP status in the 401/4xx range (unauthorized — no token), confirming the endpoint is served and protected. A 404 would indicate MCP is not enabled.

- [ ] **Step 3: Confirm MCP is enabled in the n8n UI**

Log in as owner → **Settings → Instance-level MCP**. Confirm the toggle shows MCP enabled and is locked (managed by env). Generate a token, then from an MCP client (or `curl` with the `Authorization: Bearer <token>` header) confirm a `tools/list` call returns the workflows you enabled for MCP.

- [ ] **Step 4: No commit (verification only)**

Nothing to commit. If steps 2-3 fail, re-check Task 1's env vars and that `n8nio/n8n:latest` is ≥ v2.20.0 (`docker compose exec n8n n8n --version`).