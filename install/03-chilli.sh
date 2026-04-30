#!/bin/bash
# Phase C — CoovaChilli
#   - render /etc/chilli.conf and /etc/chilli/defaults from templates
#   - enable + start chilli
#   - verify tun0 is up
#
# Idempotent.

source "$(dirname "$0")/lib.sh"
need_root

[[ -f /etc/captive-portal/interfaces.env ]] || die "Run 00-base.sh first"
. /etc/captive-portal/interfaces.env

CHILLI_RADIUS_SECRET="$(load_or_create_secret CHILLI_RADIUS_SECRET 24)"
CHILLI_UAM_SECRET="$(load_or_create_secret CHILLI_UAM_SECRET 24)"

export WAN_IF LAN_IF CHILLI_RADIUS_SECRET CHILLI_UAM_SECRET

log "Phase C — CoovaChilli (LAN=$LAN_IF, WAN=$WAN_IF)"

# 1. Render configs
render_template "$CONFIG_DIR/chilli/defaults"    /etc/chilli/defaults
render_template "$CONFIG_DIR/chilli/chilli.conf" /etc/chilli.conf
# /etc/chilli.conf has the RADIUS secret — root-only.
# /etc/chilli/defaults is sourced by login.chi (run as www-data) — must be readable.
chmod 600 /etc/chilli.conf
chmod 644 /etc/chilli/defaults

# 2. Enable in /etc/default/chilli (Debian wrapper)
if [[ -f /etc/default/chilli ]]; then
    backup_once /etc/default/chilli
    sed -i 's/^START_CHILLI=.*/START_CHILLI=1/' /etc/default/chilli
fi

# 2b. Coova source `make install` drops a SysV init script at /etc/init.d/chilli
#     with empty Default-Start, breaking `systemctl enable`. Remove it; our
#     systemd unit (installed by 00b-build-chilli.sh) takes over.
if [[ -f /etc/init.d/chilli ]]; then
    log "Removing SysV /etc/init.d/chilli (using systemd unit)"
    rm -f /etc/init.d/chilli
    update-rc.d -f chilli remove >/dev/null 2>&1 || true
fi

# 3. Make sure tun module is loaded
modprobe tun || die "tun kernel module not available"

# 4. Restart
systemctl enable chilli
systemctl restart chilli

# 5. Wait for tun0 to come up
log "Waiting for tun0..."
for i in {1..15}; do
    if ip link show tun0 >/dev/null 2>&1; then
        ok "tun0 is up"
        break
    fi
    sleep 1
    [[ $i -eq 15 ]] && die "tun0 did not appear. Check: journalctl -u chilli -n 50"
done

# 6. Verify uamlisten reachable
if ip -4 addr show tun0 | grep -q '192.168.182.1'; then
    ok "uamlisten 192.168.182.1 assigned to tun0"
else
    warn "192.168.182.1 not on tun0. ip addr:"
    ip -4 addr show tun0 || true
fi

# 7. Standalone dnsmasq on tun0 — chilli 1.6 (with our build flags) does NOT
#    intercept DNS at the tun0 level, so clients pointing at 192.168.182.1:53
#    must hit a real listener.
log "Deploying captive-dnsmasq.service"
deploy_config systemd/captive-dnsmasq.service /etc/systemd/system/captive-dnsmasq.service
systemctl daemon-reload
systemctl enable captive-dnsmasq
systemctl restart captive-dnsmasq
sleep 1
if ss -tunlp 2>/dev/null | grep -q '192.168.182.1:53'; then
    ok "captive-dnsmasq listening on 192.168.182.1:53"
else
    warn "captive-dnsmasq did not bind 192.168.182.1:53 — check: journalctl -u captive-dnsmasq -n 30"
fi
rm -f /etc/NetworkManager/dnsmasq.d/99-captive-portal.conf

ok "Phase C complete."
log "Next: sudo ./04-portal-branding.sh"
