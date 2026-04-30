#!/bin/bash
# Phase A — Base OS prep
#   - apt install all required packages
#   - configure sysctl for forwarding / conntrack
#   - configure network interfaces (WAN dhcp, LAN handed to chilli)
#   - load required kernel modules
#
# Idempotent: safe to re-run.

source "$(dirname "$0")/lib.sh"
need_root
need_debian12

# --- Tunables (override via env) ---
WAN_IF="${WAN_IF:-eth0}"
LAN_IF="${LAN_IF:-eth1}"

log "Phase A — base prep (WAN=$WAN_IF, LAN=$LAN_IF)"

# 1. Verify interfaces exist
for ifc in "$WAN_IF" "$LAN_IF"; do
    ip link show "$ifc" >/dev/null 2>&1 \
        || die "Interface $ifc not found. Set WAN_IF / LAN_IF env vars and re-run."
done
ok "Interfaces present"

# 2. Update apt index once
log "Updating apt index"
apt-get update -y

# 3. Install all required packages in one shot
#    NOTE: coova-chilli is NOT in Debian 11/12 repos (removed after Debian 9).
#    It is built from source in install/00b-build-chilli.sh — run that next.
log "Installing packages (this may take a while)"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    nftables \
    freeradius freeradius-mysql freeradius-utils \
    mariadb-server \
    apache2 \
    php php-mysql php-mbstring php-gd php-curl php-xml php-zip \
    php-db php-pear \
    libapache2-mod-php \
    modemmanager \
    dnsmasq-base \
    iproute2 conntrack iputils-ping curl wget \
    rsyslog logrotate \
    snmpd snmp \
    keepalived \
    openssl ca-certificates \
    gettext-base \
    haserl \
    libcgi-pm-perl \
    git build-essential autoconf automake libtool pkg-config \
    libssl-dev libcurl4-openssl-dev libjson-c-dev libnl-3-dev libnl-genl-3-dev \
    gengetopt debhelper devscripts
ok "Packages installed"

# 4. sysctl — forwarding + conntrack
deploy_config sysctl/99-gateway.conf /etc/sysctl.d/99-gateway.conf
sysctl --system >/dev/null
ok "sysctl applied"

# 5. Load conntrack modules now (in case sysctl ran before module load)
modprobe nf_conntrack || true
modprobe nf_nat || true

# 6. Network interfaces
#    Render template substituting WAN_IF / LAN_IF.
log "Configuring /etc/network/interfaces"
backup_once /etc/network/interfaces
sed -e "s/^auto eth0/auto $WAN_IF/" \
    -e "s/^iface eth0 /iface $WAN_IF /" \
    -e "s/^auto eth1/auto $LAN_IF/" \
    -e "s/^iface eth1 /iface $LAN_IF /" \
    "$CONFIG_DIR/network/interfaces.gateway" > /etc/network/interfaces
ok "/etc/network/interfaces written"

# 7. Disable services that may conflict with chilli/captive setup
#    (NetworkManager often grabs interfaces — disable on gateway boxes)
if systemctl is-enabled NetworkManager >/dev/null 2>&1; then
    warn "Disabling NetworkManager — gateway uses ifupdown"
    systemctl disable --now NetworkManager
fi

# 8. Persist WAN/LAN names for later phases
mkdir -p /etc/captive-portal
cat > /etc/captive-portal/interfaces.env <<EOF
WAN_IF=$WAN_IF
LAN_IF=$LAN_IF
EOF
chmod 644 /etc/captive-portal/interfaces.env

ok "Phase A complete. Reboot recommended before continuing if interfaces were renamed."
log "Next: sudo ./00b-build-chilli.sh   # build CoovaChilli from source"
log "Then:  sudo ./01-mariadb.sh"
