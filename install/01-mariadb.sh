#!/bin/bash
# Phase B-1 — MariaDB
#   - secure default install
#   - create radius DB + user
#   - secrets persisted to /etc/captive-portal/secrets.env
#
# Idempotent.

source "$(dirname "$0")/lib.sh"
need_root

DB_NAME="radius"
DB_USER="radius"
DB_HOST="localhost"

log "Phase B-1 — MariaDB"

systemctl enable --now mariadb

# 1. Wait briefly for socket
for i in {1..10}; do
    mariadb -e "SELECT 1" >/dev/null 2>&1 && break
    sleep 1
done

# 2. Generate / load DB password
DB_PASS="$(load_or_create_secret RADIUS_DB_PASS 24)"

# 3. Lock down root if not already (idempotent)
mariadb <<SQL
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL

# 4. Create DB + user
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'$DB_HOST' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'$DB_HOST' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'$DB_HOST';
FLUSH PRIVILEGES;
SQL
ok "Database '$DB_NAME' ready, user '$DB_USER'@'$DB_HOST' configured"

# 5. Persist DB connection info for later phases
cat > /etc/captive-portal/db.env <<EOF
RADIUS_DB_NAME=$DB_NAME
RADIUS_DB_USER=$DB_USER
RADIUS_DB_HOST=$DB_HOST
EOF
chmod 644 /etc/captive-portal/db.env

ok "Phase B-1 complete."
log "Next: sudo ./02-freeradius.sh"
