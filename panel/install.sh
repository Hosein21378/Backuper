#!/bin/bash
#
# PasarGuard Backup - Web Panel installer
#
#   sudo bash panel/install.sh                 # install and start
#   sudo bash panel/install.sh --port 9000     # custom port
#   sudo bash panel/install.sh --uninstall
#
set -e

REPO_RAW="${BACKUPER_REPO_RAW:-https://raw.githubusercontent.com/Hosein21378/pasarguard-backup/main}"
REPO_URL="https://github.com/Hosein21378/pasarguard-backup"
PANEL_BIN="/usr/local/bin/pasarguard-panel"
PANEL_LIB="/usr/local/lib/pasarguard-backup"
SCRIPT_PATH="$PANEL_LIB/pasarguard-backup.sh"
PANEL_PORT="${BACKUPER_PANEL_PORT:-8080}"
SERVICE="/etc/systemd/system/pasarguard-panel.service"
CONF="/root/.pasarguard_panel.conf"

RED='\033[1;31m'; GREEN='\033[1;32m'; BLUE='\033[1;36m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this installer as root (sudo)."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PANEL_PORT="$2"; shift 2 ;;
        --uninstall)
            systemctl disable --now pasarguard-panel 2>/dev/null || true
            rm -f "$SERVICE" "$PANEL_BIN"
            systemctl daemon-reload 2>/dev/null || true
            ok "The panel was removed (your backups were not touched)."
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required."
command -v curl >/dev/null 2>&1 || die "curl is required."

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -d "$PANEL_LIB"

# --- pasarguard-backup.sh -----------------------------------------------------------
if [[ -f "$HERE/pasarguard-backup.sh" ]]; then
    install -m 755 "$HERE/pasarguard-backup.sh" "$SCRIPT_PATH"
elif [[ -f "$HERE/../pasarguard-backup.sh" ]]; then
    install -m 755 "$HERE/../pasarguard-backup.sh" "$SCRIPT_PATH"
else
    info "Downloading pasarguard-backup.sh ..."
    curl -fsSL "$REPO_RAW/pasarguard-backup.sh" -o "$SCRIPT_PATH" || die "Failed to download pasarguard-backup.sh"
    chmod 755 "$SCRIPT_PATH"
fi

# --- panel -----------------------------------------------------------------
if [[ -f "$HERE/pasarguard-panel.py" ]]; then
    install -m 755 "$HERE/pasarguard-panel.py" "$PANEL_BIN"
else
    info "Downloading the panel ..."
    curl -fsSL "$REPO_RAW/panel/pasarguard-panel.py" -o "$PANEL_BIN" || die "Failed to download the panel"
    chmod 755 "$PANEL_BIN"
fi
ok "Panel installed: $PANEL_BIN"

# --- credentials -----------------------------------------------------------
if [[ -f "$CONF" ]] && grep -q 'password_hash' "$CONF"; then
    ok "Existing panel password kept ($CONF)."
    info "Change it with: pasarguard-panel --set-password"
else
    OUT="$("$PANEL_BIN" --set-password)"
    echo "$OUT"
    PANEL_PASSWORD="$(echo "$OUT" | awk '/^password:/ {print $2}')"
fi

# --- service ---------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    cat > "$SERVICE" <<EOF
[Unit]
Description=PasarGuard Backup - Web Panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$PANEL_BIN --port $PANEL_PORT --script $SCRIPT_PATH
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable pasarguard-panel >/dev/null 2>&1 || true
    systemctl restart pasarguard-panel
    sleep 1
    if systemctl is-active --quiet pasarguard-panel; then
        ok "Service pasarguard-panel is running."
        MANAGE="systemctl status pasarguard-panel / journalctl -u pasarguard-panel -f"
    else
        warn "The service did not start. Check: journalctl -u pasarguard-panel -n 50"
        MANAGE="journalctl -u pasarguard-panel -n 50"
    fi
else
    warn "systemd not found, starting the panel with nohup."
    pkill -f pasarguard-panel.py >/dev/null 2>&1 || true
    nohup "$PANEL_BIN" --port "$PANEL_PORT" --script "$SCRIPT_PATH" >/root/.pasarguard_panel.log 2>&1 &
    sleep 1
    MANAGE="tail -f /root/.pasarguard_panel.log"
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP="${IP:-<server-ip>}"

echo
echo "=============================================="
echo -e "${GREEN} PasarGuard Backup panel is ready${RESET}"
echo "=============================================="
echo " URL      : http://$IP:$PANEL_PORT"
echo " User     : admin"
if [[ -n "${PANEL_PASSWORD:-}" ]]; then
    echo " Password : $PANEL_PASSWORD"
else
    echo " Password : (unchanged - see $CONF)"
fi
echo " Manage   : $MANAGE"
echo " Project  : $REPO_URL"
echo
echo " If the port is not reachable, open it in your firewall:"
echo "   ufw allow $PANEL_PORT/tcp    # or: firewall-cmd --add-port=$PANEL_PORT/tcp"
echo "=============================================="
