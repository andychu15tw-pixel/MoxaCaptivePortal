#!/bin/bash
# Shared helpers for install/*.sh — source this at top of each phase script.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/configs"

# --- output ---
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; exit 1; }

# --- preconditions ---
need_root() {
    [[ $EUID -eq 0 ]] || die "Run as root (use sudo)"
}

need_debian12() {
    [[ -f /etc/os-release ]] || die "Not a Debian system"
    . /etc/os-release
    [[ "$ID" == "debian" && "$VERSION_ID" == "12" ]] \
        || warn "Expected Debian 12, got $ID $VERSION_ID — proceed with caution"
}

# Backup file before overwriting (idempotent — only first time).
backup_once() {
    local f="$1"
    [[ -f "$f" && ! -f "${f}.orig" ]] && cp -p "$f" "${f}.orig"
    return 0
}

# Install file from configs/ to /etc/... with backup.
deploy_config() {
    local src="$CONFIG_DIR/$1"
    local dst="$2"
    [[ -f "$src" ]] || die "Missing config: $src"
    backup_once "$dst"
    install -D -m 0644 "$src" "$dst"
    ok "Deployed $dst"
}

# Generate or load shared secrets — stored in /etc/captive-portal/secrets.env
SECRETS_FILE="/etc/captive-portal/secrets.env"
load_or_create_secret() {
    local key="$1"
    local len="${2:-32}"
    mkdir -p "$(dirname "$SECRETS_FILE")"
    chmod 700 "$(dirname "$SECRETS_FILE")"
    touch "$SECRETS_FILE" && chmod 600 "$SECRETS_FILE"

    if grep -q "^${key}=" "$SECRETS_FILE" 2>/dev/null; then
        grep "^${key}=" "$SECRETS_FILE" | cut -d= -f2-
    else
        local val
        val="$(openssl rand -hex "$len")"
        echo "${key}=${val}" >> "$SECRETS_FILE"
        echo "$val"
    fi
}

# Render a template — replace ${VAR} occurrences using current env.
# Optional 3rd arg: whitelist of vars (space-separated, e.g. '$FOO $BAR') so
# envsubst leaves unrelated ${...} alone (e.g. FreeRADIUS's ${.:name}, Apache
# ${APACHE_LOG_DIR}, etc.).
render_template() {
    local src="$1" dst="$2" vars="${3:-}"
    [[ -f "$src" ]] || die "Missing template: $src"
    backup_once "$dst"
    if [[ -n "$vars" ]]; then
        envsubst "$vars" < "$src" > "$dst"
    else
        envsubst < "$src" > "$dst"
    fi
    chmod 0644 "$dst"
    ok "Rendered $dst"
}
