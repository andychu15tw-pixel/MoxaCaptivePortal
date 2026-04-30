#!/bin/bash
# Phase B-2 — FreeRADIUS
#   - import schema into MariaDB
#   - configure sql module (DB connection)
#   - enable sql in default + inner-tunnel sites
#   - register CoovaChilli as a RADIUS client
#   - seed a test user
#
# Idempotent.

source "$(dirname "$0")/lib.sh"
need_root

[[ -f /etc/captive-portal/db.env ]] || die "Run 01-mariadb.sh first"
. /etc/captive-portal/db.env

DB_PASS="$(load_or_create_secret RADIUS_DB_PASS 24)"
CHILLI_SECRET="$(load_or_create_secret CHILLI_RADIUS_SECRET 24)"

FR_DIR="/etc/freeradius/3.0"
SCHEMA="$FR_DIR/mods-config/sql/main/mysql/schema.sql"
SETUP_SQL="$FR_DIR/mods-config/sql/main/mysql/setup.sql"

log "Phase B-2 — FreeRADIUS"

# 1. Import RADIUS schema (idempotent — schema uses CREATE TABLE IF NOT EXISTS)
[[ -f "$SCHEMA" ]] || die "Schema not found at $SCHEMA — is freeradius-mysql installed?"
log "Importing FreeRADIUS schema into '$RADIUS_DB_NAME'"
mariadb "$RADIUS_DB_NAME" < "$SCHEMA"
ok "Schema imported"

# 2. Replace sql module config with our minimal MySQL-only template.
#    Editing the upstream multi-dialect file with sed was fragile (regex hit
#    mongodb subsection's `server = ...` lines and stripped indentation).
#    Cleaner: render template, keep the upstream file as .orig backup.
SQL_MOD="$FR_DIR/mods-available/sql"
log "Replacing $SQL_MOD with rendered MySQL-only template"
backup_once "$SQL_MOD"

RADIUS_DB_PASS="$DB_PASS" \
RADIUS_DB_USER="$RADIUS_DB_USER" \
RADIUS_DB_HOST="$RADIUS_DB_HOST" \
RADIUS_DB_NAME="$RADIUS_DB_NAME" \
    render_template "$CONFIG_DIR/freeradius/sql-mysql.conf.tmpl" "$SQL_MOD" \
    '$RADIUS_DB_HOST $RADIUS_DB_USER $RADIUS_DB_PASS $RADIUS_DB_NAME'

chown freerad:freerad "$SQL_MOD"
chmod 0640 "$SQL_MOD"

# Enable sql module
ln -sf "$SQL_MOD" "$FR_DIR/mods-enabled/sql"
ok "sql module enabled"

# 3. Enable sql in sites — default + inner-tunnel
#    Uncomment the bare 'sql' line in authorize, accounting, post-auth, session sections.
log "Wiring sql into sites"
for site in default inner-tunnel; do
    f="$FR_DIR/sites-available/$site"
    [[ -f "$f" ]] || continue
    backup_once "$f"
    # Uncomment '#\tsql' or '#sql' lines (FreeRADIUS default has them commented)
    sed -i 's|^\([[:space:]]*\)#[[:space:]]*sql$|\1sql|g' "$f"
    ln -sf "$f" "$FR_DIR/sites-enabled/$site"
done
ok "sql enabled in sites"

# 4. Register CoovaChilli as a RADIUS client
#
#    The default clients.conf ships a `client localhost { ipaddr = 127.0.0.1 ... }`
#    block. Our chilli client is also at 127.0.0.1 → FreeRADIUS rejects with
#    "Failed to add duplicate client". We comment the default block out (idempotent
#    via marker line) so our chilli.conf can own 127.0.0.1.
log "Disabling default client localhost (conflicts with chilli on 127.0.0.1)"
if ! grep -q '^# DISABLED-BY-CAPTIVE-PORTAL' "$FR_DIR/clients.conf"; then
    backup_once "$FR_DIR/clients.conf"
    awk '
        /^client[[:space:]]+localhost([[:space:]]|\{)/ && !in_blk {
            print "# DISABLED-BY-CAPTIVE-PORTAL"
            in_blk=1
        }
        in_blk {
            print "# " $0
            if (/^\}/) in_blk=0
            next
        }
        { print }
    ' "$FR_DIR/clients.conf" > "$FR_DIR/clients.conf.new"
    mv "$FR_DIR/clients.conf.new" "$FR_DIR/clients.conf"
    chown freerad:freerad "$FR_DIR/clients.conf"
fi

mkdir -p "$FR_DIR/clients.d"
log "Registering chilli client"
CHILLI_RADIUS_SECRET="$CHILLI_SECRET" \
    render_template "$CONFIG_DIR/freeradius/clients-chilli.conf" \
                    "$FR_DIR/clients.d/chilli.conf"
# Ensure clients.conf includes clients.d
if ! grep -qF '$INCLUDE clients.d/' "$FR_DIR/clients.conf"; then
    echo '$INCLUDE clients.d/' >> "$FR_DIR/clients.conf"
fi
ok "chilli registered as NAS"

# 5. Permissions
chown -R freerad:freerad "$FR_DIR"
chmod 640 "$SQL_MOD"
chmod 640 "$FR_DIR/clients.d/chilli.conf"

# 6. Seed a test user (idempotent — INSERT IGNORE).
#    daloRADIUS Users Listing requires a row in `userinfo` (it joins
#    radcheck ↔ userinfo by username). Skipping userinfo means the user
#    works for RADIUS auth but is invisible in the Web UI.
#    The userinfo table is created by daloRADIUS schema in 05-daloradius.sh,
#    so this section runs after both phase 02 and 05 — but is safe at any
#    point because daloRADIUS schema is also imported during phase 02 (see
#    daloRADIUS contrib SQL files).
log "Seeding test user"
mariadb "$RADIUS_DB_NAME" <<SQL
INSERT IGNORE INTO radcheck (username, attribute, op, value)
    VALUES ('testuser', 'Cleartext-Password', ':=', 'test1234');
INSERT IGNORE INTO radreply (username, attribute, op, value)
    VALUES ('testuser', 'Session-Timeout', ':=', '3600');
INSERT IGNORE INTO radreply (username, attribute, op, value)
    VALUES ('testuser', 'Idle-Timeout', ':=', '600');
SQL

# Seed userinfo entry only if the table exists (daloRADIUS schema present).
if mariadb "$RADIUS_DB_NAME" -e 'SHOW TABLES LIKE "userinfo"' 2>/dev/null | grep -q userinfo; then
    mariadb "$RADIUS_DB_NAME" <<SQL
INSERT IGNORE INTO userinfo (username, firstname, lastname, email, creationdate, creationby)
    VALUES ('testuser', 'Test', 'User', 'test@example.com', NOW(), 'admin');
SQL
    ok "Test user seeded in radcheck + radreply + userinfo"
else
    ok "Test user seeded in radcheck + radreply (userinfo skipped — table not yet present)"
    warn "Re-run 02-freeradius.sh after 05-daloradius.sh to populate userinfo, or accept missing UI listing"
fi

# 7. Restart + verify
systemctl enable freeradius
systemctl restart freeradius
sleep 2
systemctl is-active --quiet freeradius || die "FreeRADIUS failed to start. Run: journalctl -u freeradius -n 50"

# 8. Smoke test — radtest against localhost
log "Smoke test: radtest testuser test1234 127.0.0.1"
if echo "User-Name=testuser,User-Password=test1234" | \
   radclient -x 127.0.0.1:1812 auth "$CHILLI_SECRET" 2>&1 | grep -q "Access-Accept"; then
    ok "RADIUS auth smoke test passed"
else
    warn "RADIUS auth smoke test did NOT return Access-Accept — investigate /var/log/freeradius/radius.log"
fi

ok "Phase B-2 complete."
log "Next: sudo ./03-chilli.sh"
