#!/usr/bin/env bash
#
# Wakapi/Wakatime Setup Script
#
# Configures wakatime-cli to point at self-hosted Wakapi instance
# and installs wakatime-cli if missing.
#
# Fixes the core issue: wakatime uses folder names as "projects" with no
# client grouping. Solution: use "client/project" naming convention.
# e.g., "ppanda/rebecc-ai", "zeroum/provisioner", "bridgemt/brainbot-back"
#
# Wakapi then shows:
#   ppanda          8h total
#     ppanda/rebecc-ai    3h
#     ppanda/infra        2h
#     ppanda/scripts      1h
#     ppanda/core         2h
#   zeroum          4h total
#     zeroum/provisioner  2h
#     zeroum/configs      2h
#
# You can also use Wakapi's "Labels" feature in the UI to group projects
# under client names, but the naming convention approach works automatically.

set -euo pipefail

WAKAPI_URL="${WAKAPI_URL:-https://devtime.apps.puddi.ng:3000/api}"
# From 1Password: PPD - Wakapi/devtime API Key (ppanda/internal)
#   export WAKAPI_API_KEY="$(op read 'op://ppanda/internal/PPD - Wakapi-devtime API Key/credential')"
WAKAPI_API_KEY="${WAKAPI_API_KEY:?set WAKAPI_API_KEY env (see 1Password: PPD - Wakapi/devtime API Key)}"

USERS=(root zeroum bridgemt utech bilhon)

install_wakatime_cli() {
    echo "=== Installing wakatime-cli ==="

    if command -v wakatime-cli &>/dev/null; then
        echo "wakatime-cli already installed: $(which wakatime-cli)"
        return 0
    fi

    if command -v pip3 &>/dev/null; then
        pip3 install wakatime 2>/dev/null && echo "Installed via pip3" && return 0
    fi

    # Try binary install
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
    esac

    local url="https://github.com/wakatime/wakatime-cli/releases/latest/download/wakatime-cli-linux-${arch}.zip"
    echo "Downloading wakatime-cli from $url"

    local tmpdir
    tmpdir=$(mktemp -d)
    if curl -sL "$url" -o "$tmpdir/wakatime-cli.zip" && \
       unzip -q "$tmpdir/wakatime-cli.zip" -d "$tmpdir" 2>/dev/null; then
        mv "$tmpdir/wakatime-cli-linux-${arch}" /usr/local/bin/wakatime-cli
        chmod +x /usr/local/bin/wakatime-cli
        echo "Installed to /usr/local/bin/wakatime-cli"
    else
        echo "WARNING: Could not install wakatime-cli automatically."
        echo "Install manually: pip3 install wakatime"
    fi
    rm -rf "$tmpdir"
}

configure_user() {
    local user="$1"
    local home

    if [ "$user" = "root" ]; then
        home="/root"
    else
        home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || echo "/home/$user")
    fi

    if [ ! -d "$home" ]; then
        echo "  SKIP: home dir $home not found"
        return
    fi

    local cfg="$home/.wakatime.cfg"
    echo "  Configuring $cfg"

    cat > "$cfg" << CFGEOF
[settings]
api_key = $WAKAPI_API_KEY
api_url = $WAKAPI_URL
timeout = 240
CFGEOF

    # Set ownership if not root
    if [ "$user" != "root" ]; then
        chown "$user:$user" "$cfg" 2>/dev/null || true
    fi

    echo "  OK: $cfg → $WAKAPI_URL"
}

main() {
    echo "=============================="
    echo " Wakapi/Wakatime Setup"
    echo " Server: $WAKAPI_URL"
    echo "=============================="
    echo

    install_wakatime_cli
    echo

    echo "=== Configuring users ==="
    for user in "${USERS[@]}"; do
        echo "User: $user"
        configure_user "$user"
    done
    echo

    echo "=== Verifying connectivity ==="
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Basic $(echo -n "$WAKAPI_API_KEY" | base64)" \
        "${WAKAPI_URL}/users/current" 2>/dev/null || echo "000")

    if [ "$status" = "200" ]; then
        echo "  Wakapi API: OK (HTTP $status)"
    else
        echo "  Wakapi API: FAILED (HTTP $status)"
        echo "  Check: is Wakapi running at $WAKAPI_URL ?"
        echo "  Note: Wakapi may use Bearer auth, not Basic. Check docs."
    fi

    echo
    echo "=== Next steps ==="
    echo "1. Make wrapper executable: chmod +x $(dirname "$0")/claude_wakatime_wrapper.sh"
    echo "2. Add alias to each user's shell rc:"
    echo "   alias claude='$(dirname "$0")/claude_wakatime_wrapper.sh'"
    echo "3. Or install as a Claude Code hook (recommended — see devtime_hook.sh)"
    echo
}

main "$@"
