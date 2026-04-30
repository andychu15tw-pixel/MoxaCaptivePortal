#!/bin/bash
# /usr/local/sbin/captive-healthcheck.sh
# Runs as a systemd service. Every 60s:
#   - probe chilli's UAM port (3990) on tun0 IP
#   - probe FreeRADIUS auth port (UDP 1812) via radclient ping
#   - if a check fails twice in a row, restart the offending service.

set -u

CHILLI_UAM_HOST="192.168.182.1"
CHILLI_UAM_PORT=3990
INTERVAL=60
FAIL_THRESHOLD=2

declare -A fails

probe_chilli() {
    timeout 3 bash -c "</dev/tcp/${CHILLI_UAM_HOST}/${CHILLI_UAM_PORT}" 2>/dev/null
}

probe_radius() {
    # Status-Server to localhost; require any response (Access-Accept or Reject is fine — both prove daemon up)
    [[ -f /etc/captive-portal/secrets.env ]] || return 0
    local secret
    secret="$(grep '^CHILLI_RADIUS_SECRET=' /etc/captive-portal/secrets.env | cut -d= -f2-)"
    [[ -n "$secret" ]] || return 0
    echo "Message-Authenticator=0x00" | \
        timeout 3 radclient -c 1 -r 1 127.0.0.1 status "$secret" >/dev/null 2>&1
}

restart_if_failing() {
    local name="$1" probe_fn="$2" service="$3"
    if ! "$probe_fn"; then
        fails[$name]=$(( ${fails[$name]:-0} + 1 ))
        if [[ ${fails[$name]} -ge $FAIL_THRESHOLD ]]; then
            logger -t captive-healthcheck "Restarting $service after ${fails[$name]} failed probes"
            systemctl restart "$service"
            fails[$name]=0
        fi
    else
        fails[$name]=0
    fi
}

while true; do
    restart_if_failing chilli  probe_chilli  chilli
    restart_if_failing radius  probe_radius  freeradius
    sleep "$INTERVAL"
done
