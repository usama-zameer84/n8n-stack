SHELL := /bin/bash
COMPOSE := docker compose

.PHONY: init-env tunnel-setup up down restart logs logs-n8n logs-db logs-tunnel psql backup upgrade clean status

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

psql:
	@$(COMPOSE) exec postgres psql -U "$$(grep POSTGRES_USER .env | cut -d= -f2)" -d "$$(grep POSTGRES_DB .env | cut -d= -f2)"

backup:
	@./scripts/backup.sh

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