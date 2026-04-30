#!/bin/bash
# Phase F — nftables firewall + NAT
#
# Idempotent.

source "$(dirname "$0")/lib.sh"
need_root

[[ -f /etc/captive-portal/interfaces.env ]] || die "Run 00-base.sh first"
. /etc/captive-portal/interfaces.env

# Management subnet — admins reach SSH/Web UI/SNMP from this CIDR.
# Default 0.0.0.0/0 (anywhere) so first deploy does not lock out remote SSH.
# Lock down for production: MGMT_NET=10.0.0.0/24 ./06-nftables.sh
MGMT_NET="${MGMT_NET:-0.0.0.0/0}"

export WAN_IF MGMT_NET

log "Phase F — nftables (WAN_IF=$WAN_IF, MGMT_NET=$MGMT_NET)"

render_template "$CONFIG_DIR/nftables/nftables.conf" /etc/nftables.conf
chmod 0644 /etc/nftables.conf

# Validate before applying
if ! nft -c -f /etc/nftables.conf; then
    die "nftables.conf failed validation. Restoring backup."
fi

systemctl enable --now nftables
systemctl restart nftables

# Show summary
log "Active ruleset:"
nft list ruleset | head -n 60

ok "Phase F complete."
log "Next: sudo ./07-services.sh"
