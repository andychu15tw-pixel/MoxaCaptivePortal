#!/bin/bash
# Phase G — Cellular WAN (v2)
#
#   Bring up wwan0 via ModemManager + mmcli, set up keepalived for WAN failover.
#
# This phase is a stub for v1; cellular hardware on the target Moxa unit
# (V2400 / V3400) needs identification first. Detect modem before configuring.

source "$(dirname "$0")/lib.sh"
need_root

log "Phase G — Cellular WAN (v2 — stub)"

# 1. Detect modem
if ! mmcli -L 2>/dev/null | grep -q "/Modem/"; then
    warn "No modem detected by ModemManager."
    warn "Check hardware:"
    warn "  lsusb | grep -iE 'qualcomm|sierra|huawei|quectel|fibocom|telit'"
    warn "  dmesg | grep -i 'modem\\|cdc-wdm\\|qmi\\|mbim'"
    exit 0
fi

# 2. Connect — APN must be set per carrier. Edit before running.
APN="${APN:-internet}"
log "Connecting modem with APN=$APN"
modem_path="$(mmcli -L | grep -oP '/org/freedesktop/ModemManager1/Modem/\d+' | head -n1)"
mmcli -m "$modem_path" --simple-connect="apn=${APN},ip-type=ipv4v6" || \
    warn "mmcli simple-connect failed — bearer may already exist"

# 3. WAN failover via keepalived (placeholder)
warn "WAN failover (keepalived) not yet configured — see docs/runbook-v1.md TBD"

ok "Phase G stub complete (cellular hardware-dependent)."
