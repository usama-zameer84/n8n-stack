#!/bin/sh
set -e

# n8n's internal database (executions, users, credentials, etc.)
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE USER ${POSTGRES_NON_ROOT_USER} WITH PASSWORD '${POSTGRES_NON_ROOT_PASSWORD}';
	GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_NON_ROOT_USER};
	\c ${POSTGRES_DB}
	GRANT ALL ON SCHEMA public TO ${POSTGRES_NON_ROOT_USER};
	ALTER SCHEMA public OWNER TO ${POSTGRES_NON_ROOT_USER};
	ALTER DATABASE ${POSTGRES_DB} OWNER TO ${POSTGRES_NON_ROOT_USER};
EOSQL

# Separate database for workflow data (Postgres node credentials).
# Isolated from n8n's internal DB: each user can only connect to its own
# database (PUBLIC's default CONNECT is revoked), and owns only its own
# schema, so a leaked workflow credential cannot reach n8n's
# executions/users/credentials tables.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	CREATE USER ${WORKFLOW_DB_USER} WITH PASSWORD '${WORKFLOW_DB_PASSWORD}';
	CREATE DATABASE ${WORKFLOW_DB} OWNER ${WORKFLOW_DB_USER};
	GRANT ALL PRIVILEGES ON DATABASE ${WORKFLOW_DB} TO ${WORKFLOW_DB_USER};
	\c ${WORKFLOW_DB}
	GRANT ALL ON SCHEMA public TO ${WORKFLOW_DB_USER};
	ALTER SCHEMA public OWNER TO ${WORKFLOW_DB_USER};
	-- Drop default PUBLIC connect on both databases so only the
	-- intended user can attach to each.
	\c ${POSTGRES_DB}
	REVOKE CONNECT ON DATABASE ${POSTGRES_DB} FROM PUBLIC;
	GRANT  CONNECT ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_NON_ROOT_USER};
	REVOKE CONNECT ON DATABASE ${WORKFLOW_DB} FROM PUBLIC;
	GRANT  CONNECT ON DATABASE ${WORKFLOW_DB} TO ${WORKFLOW_DB_USER};
EOSQL