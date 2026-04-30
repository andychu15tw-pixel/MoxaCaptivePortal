#!/bin/bash
# Phase E — daloRADIUS + Apache vhost
#   - download daloRADIUS latest release tarball from GitHub
#   - drop into /opt/daloradius (NOT /var/www — Moxa thingspro symlinks /var/www
#     to a restricted path; Apache cannot follow it)
#   - import daloRADIUS schema additions
#   - build daloradius.conf.php from upstream sample, sed-patch DB creds
#   - generate self-signed TLS cert (replace later with Let's Encrypt)
#   - enable Apache modules + vhost (HTTP + HTTPS)
#   - register chilli as a NAS in daloRADIUS DB
#
# Idempotent.

source "$(dirname "$0")/lib.sh"
need_root

[[ -f /etc/captive-portal/db.env ]] || die "Run 01-mariadb.sh first"
. /etc/captive-portal/db.env
DB_PASS="$(load_or_create_secret RADIUS_DB_PASS 24)"

# /var/www on Moxa is a symlink to /var/thingspro/www/ (restricted). Install
# daloRADIUS at a real path /opt to avoid Apache symlink-traversal issues.
DALO_DIR="/opt/daloradius"

# Resolve latest release tag at runtime; allow override via env DALO_VERSION
if [[ -n "${DALO_VERSION:-}" ]]; then
    DALO_TAG="$DALO_VERSION"
else
    log "Querying github for latest daloRADIUS release"
    DALO_TAG="$(curl -s https://api.github.com/repos/lirantal/daloradius/releases/latest \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')"
    [[ -n "$DALO_TAG" ]] || DALO_TAG="master"
fi
DALO_URL="https://github.com/lirantal/daloradius/archive/refs/tags/${DALO_TAG}.tar.gz"
[[ "$DALO_TAG" == "master" ]] && DALO_URL="https://github.com/lirantal/daloradius/archive/refs/heads/master.tar.gz"
DALO_TARBALL="daloradius-${DALO_TAG}.tar.gz"

log "Phase E — daloRADIUS ${DALO_TAG}"

# 1. Download + extract
if [[ ! -d "$DALO_DIR" ]]; then
    log "Downloading $DALO_URL"
    tmp="$(mktemp -d)"
    wget -O "$tmp/$DALO_TARBALL" "$DALO_URL"
    tar -xzf "$tmp/$DALO_TARBALL" -C "$tmp"
    extracted="$(find "$tmp" -maxdepth 1 -type d -name 'daloradius-*' | head -n1)"
    [[ -d "$extracted" ]] || die "Failed to extract daloRADIUS"
    mv "$extracted" "$DALO_DIR"
    rm -rf "$tmp"
    ok "daloRADIUS extracted to $DALO_DIR"
else
    ok "daloRADIUS already at $DALO_DIR (skipping download)"
fi

chown -R www-data:www-data "$DALO_DIR"

# 2. Import schema additions (idempotent — uses CREATE TABLE IF NOT EXISTS where possible)
log "Importing daloRADIUS schema additions"
for f in "$DALO_DIR"/contrib/db/mysql-daloradius.sql \
         "$DALO_DIR"/contrib/db/fr3-mysql-daloradius-and-freeradius.sql; do
    if [[ -f "$f" ]]; then
        log "  - $(basename "$f")"
        mariadb "$RADIUS_DB_NAME" < "$f" || warn "  failed (table may already exist) — continuing"
    fi
done
ok "Schema additions applied"

# 3. Build daloradius.conf.php from upstream sample (keeps ALL keys defined,
#    avoiding "Undefined index" warnings), patching only DB credentials.
log "Building daloradius.conf.php from upstream sample"
SAMPLE="$DALO_DIR/library/daloradius.conf.php.sample"
TARGET="$DALO_DIR/library/daloradius.conf.php"
[[ -f "$SAMPLE" ]] || die "Missing $SAMPLE — daloRADIUS install incomplete"

cp "$SAMPLE" "$TARGET"
sed -i \
    -e "s|^\(\$configValues\['CONFIG_DB_ENGINE'\][[:space:]]*=[[:space:]]*\)'.*';|\1'mysqli';|" \
    -e "s|^\(\$configValues\['CONFIG_DB_HOST'\][[:space:]]*=[[:space:]]*\)'.*';|\1'$RADIUS_DB_HOST';|" \
    -e "s|^\(\$configValues\['CONFIG_DB_PORT'\][[:space:]]*=[[:space:]]*\)'.*';|\1'3306';|" \
    -e "s|^\(\$configValues\['CONFIG_DB_USER'\][[:space:]]*=[[:space:]]*\)'.*';|\1'$RADIUS_DB_USER';|" \
    -e "s|^\(\$configValues\['CONFIG_DB_PASS'\][[:space:]]*=[[:space:]]*\)'.*';|\1'$DB_PASS';|" \
    -e "s|^\(\$configValues\['CONFIG_DB_NAME'\][[:space:]]*=[[:space:]]*\)'.*';|\1'$RADIUS_DB_NAME';|" \
    "$TARGET"
ok "Rendered $TARGET (sample-based)"
chown www-data:www-data "$DALO_DIR/library/daloradius.conf.php"
chmod 0640 "$DALO_DIR/library/daloradius.conf.php"

# 4. Log dir
mkdir -p /var/log/daloradius
chown www-data:www-data /var/log/daloradius

# 5. Self-signed TLS cert (skip if already present)
CERT="/etc/ssl/certs/captive-portal.crt"
KEY="/etc/ssl/private/captive-portal.key"
if [[ ! -f "$CERT" ]]; then
    log "Generating self-signed TLS cert (10 years)"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$KEY" -out "$CERT" \
        -subj "/CN=moxa-cp-gw" >/dev/null 2>&1
    chmod 600 "$KEY"
    ok "TLS cert at $CERT"
else
    ok "TLS cert already present at $CERT"
fi

# 6. Apache modules
log "Enabling Apache modules"
a2enmod ssl rewrite headers cgi alias >/dev/null

# 7. Vhost
deploy_config apache/dalo-vhost.conf /etc/apache2/sites-available/dalo.conf
a2dissite 000-default >/dev/null 2>&1 || true
a2ensite dalo >/dev/null

# 8. Reload
apache2ctl configtest || die "Apache config test failed"
systemctl enable apache2
systemctl restart apache2
ok "Apache restarted"

# 9. Register chilli as a NAS in daloRADIUS DB (so operators can see it)
CHILLI_SECRET="$(load_or_create_secret CHILLI_RADIUS_SECRET 24)"
mariadb "$RADIUS_DB_NAME" <<SQL
INSERT IGNORE INTO nas (nasname, shortname, type, ports, secret, server, community, description)
    VALUES ('127.0.0.1', 'chilli', 'coovachilli', NULL, '$CHILLI_SECRET', NULL, NULL, 'CoovaChilli on this gateway');
SQL
ok "Chilli registered in daloRADIUS NAS list"

ok "Phase E complete."
log ""
log "====================================================================="
log "  daloRADIUS:  https://<gw-ip>/daloradius/login.php"
log "  Default operator login: administrator / radius   (CHANGE IMMEDIATELY)"
log "  TLS cert is self-signed — browsers will warn until you replace it."
log "====================================================================="
log "Next: sudo ./06-nftables.sh"
