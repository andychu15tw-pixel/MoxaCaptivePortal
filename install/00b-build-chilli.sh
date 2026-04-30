#!/bin/bash
# Phase A.5 — Build CoovaChilli from source
#
# coova-chilli was removed from Debian after stretch (Debian 9). On
# Debian 11/12 (bullseye/bookworm) the only options are:
#   1. Build from upstream github (this script)
#   2. Pull old stretch .deb from snapshot.debian.org (unsupported)
#
# Build deps were installed by 00-base.sh.
# Idempotent: re-running re-builds only if /usr/sbin/chilli is missing or
# CHILLI_FORCE_REBUILD=1 is set.

source "$(dirname "$0")/lib.sh"
need_root

CHILLI_REPO="${CHILLI_REPO:-https://github.com/coova/coova-chilli.git}"
CHILLI_REF="${CHILLI_REF:-1.6}"   # last upstream release tag; override via env
BUILD_DIR="/usr/local/src/coova-chilli"

log "Phase A.5 — build CoovaChilli ${CHILLI_REF}"

# 0. Skip if already installed and not forcing rebuild
if [[ -x /usr/sbin/chilli && "${CHILLI_FORCE_REBUILD:-0}" != "1" ]]; then
    ok "chilli already at /usr/sbin/chilli — skipping (set CHILLI_FORCE_REBUILD=1 to rebuild)"
    exit 0
fi

# 1. Clone or update
if [[ ! -d "$BUILD_DIR/.git" ]]; then
    log "Cloning $CHILLI_REPO"
    rm -rf "$BUILD_DIR"
    git clone "$CHILLI_REPO" "$BUILD_DIR"
fi

cd "$BUILD_DIR"
log "Checking out $CHILLI_REF"
git fetch --tags --force
git checkout "$CHILLI_REF"

# 2. Bootstrap + configure
log "Running bootstrap + configure"
./bootstrap

# Force --without-curl. UAM portal flow does not need chilliredir's curl
# (Apache + hotspotlogin.cgi handle redirects natively). Auto-detect was
# unreliable on Moxa repos: pkg-config / link-tests pass but configure's
# own AC_CHECK_LIB(-lcurl) still fails.
# To re-enable curl support later, set CHILLI_WITH_CURL=1 in the env.
CURL_FLAG="--without-curl"
if [[ "${CHILLI_WITH_CURL:-0}" == "1" ]]; then
    CURL_FLAG="--with-curl"
    log "CHILLI_WITH_CURL=1 — building with curl support"
else
    log "Building without curl (chilliredir disabled — not needed for our UAM flow)"
fi

CFLAGS="-O2 -Wno-error" ./configure \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --mandir=/usr/share/man \
    --enable-largelimits \
    --enable-binstatusfile \
    --enable-statusfile \
    --enable-redir \
    --enable-chilliscript \
    --enable-uamuiport \
    --enable-miniportal \
    --enable-layer3 \
    --enable-proxyvsa \
    --enable-miniconfig \
    --enable-eapol \
    --enable-uamdomainfile \
    --with-openssl \
    $CURL_FLAG \
    --with-poll

# 3. Build
# Pre-build fix: cmdline.patch in src/ is incompatible with newer gengetopt
# (Debian 11/12 ships gengetopt 2.23+). The patch was authored against gengetopt
# 2.22 output and fails at runtime with "Hunk #1 FAILED at 1902".
# Truncating the patch makes `patch` a no-op — chilli still builds with default
# cmdline.c output, just without the upstream cosmetic fix.
if [[ -f src/cmdline.patch ]]; then
    log "Neutralizing src/cmdline.patch (gengetopt version mismatch)"
    : > src/cmdline.patch
fi

# Disable parallel build to avoid race in cmdline.c generation
log "Compiling (single-threaded to avoid cmdline.c race)"
make

# 4. Install
log "Installing to /usr"
make install

# 5. Provide systemd unit (upstream ships sysv only)
cat > /etc/systemd/system/chilli.service <<'EOF'
[Unit]
Description=CoovaChilli Captive Portal
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/var/run/chilli.pid
EnvironmentFile=-/etc/chilli/defaults
ExecStartPre=/usr/sbin/modprobe tun
ExecStart=/usr/sbin/chilli
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# 6. Make sure default www / config dirs exist (upstream creates these via make
#    install but be defensive)
install -d -m 0755 /etc/chilli
install -d -m 0755 /etc/chilli/www
install -d -m 0755 /var/run

# 7. Copy upstream sample www assets if /etc/chilli/www is empty
if [[ -z "$(ls -A /etc/chilli/www 2>/dev/null)" ]]; then
    if [[ -d "$BUILD_DIR/www" ]]; then
        log "Seeding /etc/chilli/www from upstream samples"
        cp -a "$BUILD_DIR/www/." /etc/chilli/www/
    fi
fi

# 8. Verify binary
#   chilli 1.6 has no --version flag (any unknown arg launches the daemon),
#   so just check existence + executability + ldd resolves.
if [[ -x /usr/sbin/chilli ]]; then
    if ldd /usr/sbin/chilli 2>&1 | grep -q "not found"; then
        warn "chilli has unresolved shared libraries:"
        ldd /usr/sbin/chilli | grep "not found"
        die "chilli build incomplete"
    fi
    ok "chilli installed: $(stat -c '%s bytes' /usr/sbin/chilli), ldd clean"
else
    die "chilli build failed — /usr/sbin/chilli missing or not executable"
fi

ok "Phase A.5 complete."
log "Next: sudo ./01-mariadb.sh"
