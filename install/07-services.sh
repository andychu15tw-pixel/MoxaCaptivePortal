#!/bin/bash
# Phase H + I — logging routes, snmpd, healthcheck
#   - rsyslog: route chilli + nftables drops to dedicated files
#   - logrotate: daily / 14d for our logs
#   - snmpd: v3 user creation
#   - healthcheck: systemd service that restarts chilli / freeradius on probe failure
#
# Idempotent.

source "$(dirname "$0")/lib.sh"
need_root

log "Phase H — logging"

# 1. rsyslog rules
deploy_config rsyslog/30-captive-portal.conf /etc/rsyslog.d/30-captive-portal.conf
touch /var/log/chilli.log /var/log/firewall.log
# Use whichever user/group exists for syslog (Debian normally has 'syslog:adm';
# stripped Moxa images may have only root:adm).
if id syslog >/dev/null 2>&1; then
    chown syslog:adm /var/log/chilli.log /var/log/firewall.log
else
    chown root:adm /var/log/chilli.log /var/log/firewall.log 2>/dev/null \
        || chown root:root /var/log/chilli.log /var/log/firewall.log
fi
chmod 640 /var/log/chilli.log /var/log/firewall.log
systemctl restart rsyslog
ok "rsyslog rules deployed"

# 2. logrotate
deploy_config rsyslog/logrotate-captive-portal /etc/logrotate.d/captive-portal
ok "logrotate rule deployed"

log "Phase H — SNMP"

# 3. snmpd v3 user — only create if not already present
SNMP_USER="moxaadmin"
SNMP_AUTH_PASS="$(load_or_create_secret SNMP_AUTH_PASS 16)"
SNMP_PRIV_PASS="$(load_or_create_secret SNMP_PRIV_PASS 16)"

SNMP_PERSIST=/var/lib/snmp/snmpd.conf
mkdir -p /var/lib/snmp
touch "$SNMP_PERSIST"
chmod 600 "$SNMP_PERSIST"

if ! grep -q "createUser ${SNMP_USER}" "$SNMP_PERSIST" 2>/dev/null; then
    systemctl stop snmpd 2>/dev/null || true
    # Append createUser directly. snmpd reads this on startup, hashes the
    # passphrases, and rewrites the file replacing createUser with usmUser.
    echo "createUser ${SNMP_USER} SHA \"${SNMP_AUTH_PASS}\" AES \"${SNMP_PRIV_PASS}\"" \
        >> "$SNMP_PERSIST"
    ok "SNMPv3 user '$SNMP_USER' seeded (passwords in /etc/captive-portal/secrets.env)"
else
    ok "SNMPv3 user '$SNMP_USER' already exists"
fi

deploy_config snmpd/snmpd.conf /etc/snmp/snmpd.conf
systemctl enable snmpd
systemctl restart snmpd

log "Phase I — healthcheck"

# 4. healthcheck script + systemd unit
install -m 0755 "$CONFIG_DIR/systemd/captive-healthcheck.sh" /usr/local/sbin/captive-healthcheck.sh
deploy_config systemd/captive-healthcheck.service /etc/systemd/system/captive-healthcheck.service
systemctl daemon-reload
systemctl enable --now captive-healthcheck
ok "Healthcheck service enabled"

# 5. Restart=always on critical services
for svc in chilli freeradius apache2 mariadb; do
    mkdir -p "/etc/systemd/system/${svc}.service.d"
    cat > "/etc/systemd/system/${svc}.service.d/restart.conf" <<EOF
[Service]
Restart=always
RestartSec=10s
EOF
done
systemctl daemon-reload
ok "Restart policy applied to chilli / freeradius / apache2 / mariadb"

ok "Phases H + I complete."
log ""
log "====================================================================="
log "  Deployment finished."
log "  Verify with: docs/verification.md"
log "  Logs:"
log "    /var/log/chilli.log"
log "    /var/log/firewall.log"
log "    /var/log/daloradius/daloradius.log"
log "    /var/log/freeradius/radius.log"
log "    journalctl -u captive-healthcheck -f"
log "====================================================================="
