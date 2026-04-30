#!/bin/bash
# Phase D — Portal branding
#   Override the static assets served around CoovaChilli's HotspotLogin.cgi:
#     - logo.svg
#     - style.css
#     - login.html (optional landing page)
#
#   Does NOT modify hotspotlogin.cgi itself — the package's CGI is left alone
#   so package updates do not blow away local edits. To customize CGI text,
#   edit /etc/chilli/www/hotspotlogin.cgi directly after this phase.
#
# Idempotent.

source "$(dirname "$0")/lib.sh"
need_root

CHILLI_WWW="/etc/chilli/www"

log "Phase D — portal branding (logo / css / html)"

[[ -d "$CHILLI_WWW" ]] || die "$CHILLI_WWW not found — is coova-chilli installed?"

# 1. Drop in branded assets. backup_once preserves the package originals.
for asset in logo.svg style.css login.html index.php; do
    src="$CONFIG_DIR/chilli/www/$asset"
    dst="$CHILLI_WWW/$asset"
    [[ -f "$src" ]] || { warn "Missing $src — skipping"; continue; }
    backup_once "$dst"
    install -m 0644 "$src" "$dst"
    ok "Deployed $dst"
done

# 2. Install hotspotlogin.cgi wrapper (executes haserl on login.chi).
#    Coova 1.6 ships login.chi but no hotspotlogin.cgi — the wrapper bridges
#    Apache's cgi-script handler to haserl.
install -m 0755 "$CONFIG_DIR/chilli/www/hotspotlogin.cgi" "$CHILLI_WWW/hotspotlogin.cgi"
ok "Deployed $CHILLI_WWW/hotspotlogin.cgi (haserl wrapper)"

ok "Phase D complete."
log "Tip: replace $CHILLI_WWW/logo.svg with your customer logo at any time."
log "Next: sudo ./05-daloradius.sh"
