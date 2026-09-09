SHELL := /bin/bash
COMPOSE := docker compose

.PHONY: init-env tunnel-setup up down restart logs logs-n8n logs-db logs-tunnel logs-backup logs-runners psql backup backup-list backup-verify build-runners upgrade clean status

init-env:
	@./scripts/init-env.sh

tunnel-setup:
	@./scripts/tunnel-setup.sh

up:
	@$(COMPOSE) up -d
	@$(COMPOSE) ps

down:
	@$(COMPOSE) down

restart:
	@$(COMPOSE) restart

status:
	@$(COMPOSE) ps

logs:
	@$(COMPOSE) logs -f --tail=200

logs-n8n:
	@$(COMPOSE) logs -f --tail=200 n8n

logs-db:
	@$(COMPOSE) logs -f --tail=200 postgres

logs-tunnel:
	@$(COMPOSE) logs -f --tail=200 cloudflared

logs-backup:
	@tail -n 200 -f backups/.backup-cron.log 2>/dev/null || $(COMPOSE) logs -f --tail=200 backup

logs-runners:
	@$(COMPOSE) logs -f --tail=200 task-runners

# Rebuild the task-runner image (picks up task-runners/requirements.txt changes)
# and restart the sidecar. n8n reconnects to the new runner automatically.
build-runners:
	@$(COMPOSE) build task-runners
	@$(COMPOSE) up -d task-runners
	@$(COMPOSE) logs --tail=20 task-runners

psql:
	@$(COMPOSE) exec postgres psql -U "$$(grep POSTGRES_USER .env | cut -d= -f2)" -d "$$(grep POSTGRES_DB .env | cut -d= -f2)"

backup:
	@./scripts/backup.sh

backup-list:
	@ls -lh backups/ 2>/dev/null | grep -E 'n8n-|workflows-' || echo "No backups yet — run 'make backup'."

backup-verify:
	@./scripts/backup-verify.sh

upgrade: backup
	@$(COMPOSE) pull
	@$(COMPOSE) up -d
	@$(COMPOSE) ps

clean:
	@read -r -p "This runs 'down -v' and deletes ALL volumes. Type DESTROY to proceed: " ans; \
	if [[ "$$ans" == "DESTROY" ]]; then \
	  $(COMPOSE) down -v; \
	else \
	  echo "Aborted."; \
	fi