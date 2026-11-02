#!/bin/bash
#
# PasarGuard Backup - one-line installer
#
# Install everything (backup engine + web panel) with a single command:
#
#   sudo bash -c "$(curl -sL https://github.com/Hosein21378/pasarguard-backup/raw/main/install.sh)"
#
# Options:
#   --panel-only        install only the web panel
#   --no-panel          install only the backup engine
#   --port N            web panel port (default 8080)
#   --uninstall         remove the web panel (backups are not touched)
#   --yes, -y           do not ask to create the first backup
#   restore             open the restore wizard
#   --help, -h          show this help
#
# Non-interactive setup (fully automatic):
#   BACKUPER_NONINTERACTIVE=1 BACKUPER_REMARK=pasarguard BACKUPER_TEMPLATE=18 \
#   BACKUPER_TIMER=360 BACKUPER_PLATFORM=telegram BACKUPER_TG_TOKEN=... \
#   BACKUPER_TG_CHAT=... sudo -E bash install.sh --yes
#
set -uo pipefail

REPO_RAW="${BACKUPER_REPO_RAW:-https://raw.githubusercontent.com/Hosein21378/pasarguard-backup/main}"
REPO_URL="https://github.com/Hosein21378/pasarguard-backup"
LIB_DIR="/usr/local/lib/pasarguard-backup"
ENGINE="$LIB_DIR/pasarguard-backup.sh"
BIN_DIR="/usr/local/bin"
CMD="$BIN_DIR/pasarguard-backup"
PANEL_BIN="$BIN_DIR/pasarguard-panel"
CONF_FILE="/root/.pasarguard_panel.conf"
PANEL_PORT="${BACKUPER_PANEL_PORT:-8080}"

RED='\033[1;31m'; GREEN='\033[1;32m'; BLUE='\033[1;36m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
}

MODE="full"        # full | panel | engine
ACTION="install"
ASSUME_YES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --panel-only) MODE="panel"; shift ;;
        --no-panel)   MODE="engine"; shift ;;
        --port)
            [[ -n "${2:-}" ]] || die "--port needs a value."
            PANEL_PORT="$2"; shift 2 ;;
        --uninstall)  ACTION="uninstall"; shift ;;
        --yes|-y)     ASSUME_YES=1; shift ;;
        restore|--restore|-r) ACTION="restore"; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

# Where the installer itself lives (empty when it is piped from curl)
HERE=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
fi

need_root() {
    [[ ${EUID} -eq 0 ]] || die "Run this installer as root:  sudo bash install.sh"
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but was not found."
}

# Download a file from the repository (or copy it from the local checkout)
fetch() {
    local remote_path="$1" target="$2"
    local local_copy="$HERE/$remote_path"
    if [[ -n "$HERE" && -f "$local_copy" ]]; then
        cp -f "$local_copy" "$target"
    else
        curl -fsSL "$REPO_RAW/$remote_path" -o "$target" || return 1
    fi
    return 0
}

install_engine() {
    install -d "$LIB_DIR"
    info "Installing the backup engine ..."
    if ! fetch "pasarguard-backup.sh" "$ENGINE"; then
        die "Failed to download pasarguard-backup.sh from $REPO_RAW"
    fi
    chmod 755 "$ENGINE"
    ln -sf "$ENGINE" "$CMD"
    ok "Engine installed: $CMD"
}

install_panel() {
    local tmp_installer log password
    info "Installing the web panel ..."
    if [[ -n "$HERE" && -f "$HERE/panel/install.sh" ]]; then
        tmp_installer="$HERE/panel/install.sh"
    else
        tmp_installer="/tmp/pasarguard-panel-install.sh"
        curl -fsSL "$REPO_RAW/panel/install.sh" -o "$tmp_installer" \
            || die "Failed to download panel/install.sh from $REPO_RAW"
    fi

    log="$(mktemp)"
    if ! BACKUPER_KEEP_ENGINE=1 bash "$tmp_installer" --port "$PANEL_PORT" --quiet 2>&1 | tee "$log"; then
        warn "The panel installer reported a problem. Last lines:"
        tail -n 15 "$log"
        rm -f "$log"
        return 1
    fi
    while IFS= read -r line; do
        case "$line" in
            password:*) PANEL_PASSWORD="${line#password: }" ;;
        esac
    done < "$log"
    rm -f "$log"
    PANEL_PASSWORD="${PANEL_PASSWORD:-}"
    return 0
}

summary() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    ip="${ip:-<server-ip>}"
    echo
    echo "=============================================="
    echo -e "${GREEN} PasarGuard Backup is installed${RESET}"
    echo "=============================================="
    echo " Engine  : $CMD"
    echo " Menu    : sudo pasarguard-backup"
    if [[ "$MODE" != "engine" ]]; then
        echo " Panel   : http://$ip:$PANEL_PORT"
        echo " User    : admin"
        if [[ -n "${PANEL_PASSWORD:-}" ]]; then
            echo " Password: $PANEL_PASSWORD"
        else
            echo " Password: (unchanged - see $CONF_FILE)"
        fi
    fi
    echo " Project : $REPO_URL"
    echo
    echo " Create your first backup : sudo pasarguard-backup"
    if [[ "$MODE" != "engine" ]]; then
        echo " Restore a backup         : sudo pasarguard-backup restore"
    fi
    echo "=============================================="
}

# ---------------------------------------------------------------------------
need_root
need curl
if [[ "$MODE" != "engine" ]]; then
    need python3
fi

case "$ACTION" in
    uninstall)
        if [[ -x "$PANEL_BIN" || -f /etc/systemd/system/pasarguard-panel.service ]]; then
            tmp="$(mktemp)"
            fetch "panel/install.sh" "$tmp" || die "Failed to download panel/install.sh"
            bash "$tmp" --uninstall
            rm -f "$tmp"
        fi
        rm -f "$CMD" /usr/local/bin/pasarguard-panel
        ok "PasarGuard Backup was removed. Your backups and configs are untouched."
        exit 0
        ;;
    restore)
        install -d "$LIB_DIR"
        fetch "pasarguard-backup.sh" "$ENGINE.tmp" || die "Failed to download pasarguard-backup.sh"
        chmod 755 "$ENGINE.tmp"
        mv -f "$ENGINE.tmp" "$ENGINE"
        exec bash "$ENGINE" restore
        ;;
esac

install_engine

if [[ "$MODE" != "engine" ]]; then
    install_panel || warn "The panel could not be installed. The engine still works."
fi

summary

# Offer the first backup right away
if [[ -z "$ASSUME_YES" ]]; then
    if [[ -n "${BACKUPER_NONINTERACTIVE:-}" ]]; then
        info "Running the non-interactive setup ..."
        exec bash "$ENGINE" install
    elif [[ -t 0 ]]; then
        echo
        read -r -p "Create your first backup now? [Y/n]: " answer
        case "$answer" in
            n|N|no|NO) echo "Run 'sudo pasarguard-backup' whenever you are ready." ;;
            *) exec bash "$ENGINE" ;;
        esac
    fi
fi
