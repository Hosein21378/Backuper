#!/bin/bash

# Global constants
readonly SCRIPT_SUFFIX="_backuper_script.sh"
readonly TAG="_backuper."
readonly BACKUP_SUFFIX="${TAG}zip"
readonly DATABASE_SUFFIX="${TAG}sql"
readonly LOGS_SUFFIX="${TAG}log"
readonly VERSION="v1.0.0"

# ---------------------------------------------------------------------------
# Branding - change these values to make the project your own
# ---------------------------------------------------------------------------
readonly PROJECT_NAME="Backuper"
readonly PROJECT_OWNER="Hosein21378"
readonly PROJECT_OWNER_LINK="https://github.com/Hosein21378"
readonly GITHUB_REPO="Hosein21378/Backuper"
readonly REPO_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/master"

# ---------------------------------------------------------------------------
# Non-interactive mode (used by the web panel and by automation)
#
#   BACKUPER_NONINTERACTIVE=1 bash backuper.sh install
#     BACKUPER_REMARK            required, 3+ chars (letters, numbers, _)
#     BACKUPER_TEMPLATE          1-18  (0 = custom, no template)
#     BACKUPER_TIMER             minutes between backups (1-1440)
#     BACKUPER_PLATFORM          telegram | discord | gmail
#     BACKUPER_TG_TOKEN / BACKUPER_TG_CHAT / BACKUPER_TG_TOPIC
#     BACKUPER_DISCORD_WEBHOOK
#     BACKUPER_GMAIL_ADDRESS / BACKUPER_GMAIL_PASSWORD
#     BACKUPER_PASSWORD          optional archive password
#     BACKUPER_DIRS_EXTRA        optional extra paths ("/a /b")
#
#   BACKUPER_NONINTERACTIVE=1 bash backuper.sh restore
#     BACKUPER_RESTORE_PLATFORM  telegram | discord | gmail | local
#     BACKUPER_RESTORE_REMARK    optional remark (loads the saved profile)
#     BACKUPER_RESTORE_MSG       Telegram message link or file id
#     BACKUPER_RESTORE_PATH      local archive path
#     BACKUPER_ZIP_PASSWORD      password of a protected archive
#     BACKUPER_RESTORE_YES=1     skip the confirmation
#     BACKUPER_RESTORE_DB        yes|no  (import the database dump)
#     BACKUPER_RESTORE_RESTART   yes|no  (restart docker containers)
# ---------------------------------------------------------------------------


# ANSI color codes
declare -A COLORS=(
    [red]='\033[1;31m' [pink]='\033[1;35m' [green]='\033[1;92m'
    [spring]='\033[38;5;46m' [orange]='\033[1;38;5;208m' [cyan]='\033[1;36m' [reset]='\033[0m'
)

# Logging & Printing functions
print() { echo -e "${COLORS[cyan]}$*${COLORS[reset]}"; }
log() { echo -e "${COLORS[cyan]}[INFO]${COLORS[reset]} $*"; }
warn() { echo -e "${COLORS[orange]}[WARN]${COLORS[reset]} $*" >&2; }
error() { echo -e "${COLORS[red]}[ERROR]${COLORS[reset]} $*" >&2; exit 1; }
wrong() { echo -e "${COLORS[red]}[WRONG]${COLORS[reset]} $*" >&2; }
success() { echo -e "${COLORS[spring]}${COLORS[green]}[SUCCESS]${COLORS[reset]} $*"; }

# Interactive functions
input() { read -p "$(echo -e "${COLORS[orange]}▶ $1${COLORS[reset]} ")" "$2"; }
confirm() {
    # Skipped when the script is driven by the web panel (non-interactive mode)
    if noni; then return 0; fi
    read -p "$(echo -e "${COLORS[pink]}Press any key to continue...${COLORS[reset]}")"
}

# Non-interactive mode: all values are taken from BACKUPER_* environment variables.
# Used by the web panel and by automation (cron / CI).
noni() { [ -n "${BACKUPER_NONINTERACTIVE:-}" ]; }

# Error handling
trap 'error "An error occurred. Exiting..."' ERR

# Utility functions
check_root() {
    [[ $EUID -eq 0 ]] || error "This script must be run as root"
}

detect_package_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    else
        error "Unsupported package manager"
    fi
}

update_os() {
    local package_manager=$(detect_package_manager)
    log "Updating the system using $package_manager..."
    
    case $package_manager in
        apt)
            apt-get update -y && apt-get upgrade -y || error "Failed to update the system"
            ;;
        dnf|yum)
            $package_manager update -y || error "Failed to update the system"
            ;;
        pacman)
            pacman -Syu --noconfirm || error "Failed to update the system"
            ;;
    esac
    success "System updated successfully"
}

install_dependencies() {
    local package_manager=$(detect_package_manager)
    local packages=("wget" "curl" "zip" "unzip" "cron" "msmtp" "mutt" "postgresql-client")

    log "Installing dependencies: ${packages[*]}..."
    
    case $package_manager in
        apt)
            apt-get install -y "${packages[@]}" || error "Failed to install dependencies"
            if ! apt-get install -y default-mysql-client; then
                apt-get install -y mariadb-client || error "Failed to install MySQL/MariaDB client"
            fi
            ;;
        dnf|yum)
            packages+=("mariadb")
            $package_manager install -y "${packages[@]}" || error "Failed to install dependencies"
            ;;
        pacman)
            packages+=("mariadb")
            pacman -Sy --noconfirm "${packages[@]}" || error "Failed to install dependencies"
            ;;
    esac
    success "Dependencies installed successfully"
}

install_yq() {
    if command -v yq &>/dev/null; then
        success "yq is already installed."
        return
    fi

    log "Installing yq..."
    local ARCH=$(uname -m)
    local YQ_BINARY="yq_linux_amd64"

    [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && YQ_BINARY="yq_linux_arm64"

    wget -q "https://github.com/mikefarah/yq/releases/latest/download/$YQ_BINARY" -O /usr/bin/yq || error "Failed to download yq."
    chmod +x /usr/bin/yq || error "Failed to set execute permissions on yq."

    success "yq installed successfully."
}
install_panel() {
    clear
    print "======== Web Panel [$VERSION] ========"
    print ""
    print "The panel gives you a web interface for creating backups, running them,"
    print "watching the logs and restoring a backup - from any browser."
    print ""

    local local_panel=""
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [ -n "$script_dir" ] && [ -f "$script_dir/panel/install.sh" ]; then
        local_panel="$script_dir/panel/install.sh"
    fi

    if command -v backuper-panel &> /dev/null; then
        print "The panel is already installed on this server."
        print ""
        local answer=""
        input "Do you want to start/restart it? (yes/no): " answer
        if [[ "$answer" == "yes" ]]; then
            start_panel_service
        fi
        confirm
        return 0
    fi

    local answer=""
    input "Install the web panel now? (yes/no): " answer
    [[ "$answer" == "yes" ]] || return 0

    if [ -n "$local_panel" ]; then
        log "Installing from: $local_panel"
        bash "$local_panel" || { wrong "Panel installation failed."; confirm; return 1; }
    else
        log "Downloading the panel installer..."
        if ! curl -sSL "$REPO_RAW/panel/install.sh" -o /tmp/backuper-panel-install.sh; then
            wrong "Failed to download the panel installer from $REPO_RAW"
            confirm
            return 1
        fi
        bash /tmp/backuper-panel-install.sh || { wrong "Panel installation failed."; confirm; return 1; }
        rm -f /tmp/backuper-panel-install.sh
    fi

    confirm
}

start_panel_service() {
    if command -v systemctl &> /dev/null && systemctl list-unit-files 2>/dev/null | grep -q '^backuper-panel.service'; then
        systemctl enable backuper-panel &> /dev/null || true
        systemctl restart backuper-panel || { wrong "Failed to start backuper-panel.service"; return 1; }
        success "Panel service started."
        print "Open: http://$(hostname -I | awk '{print $1}'):8080"
        return 0
    fi

    pkill -f backuper-panel.py &> /dev/null || true
    nohup backuper-panel --port 8080 --no-auth &>> /root/.backuper_panel.log &
    sleep 1
    success "Panel started in the background (log: /root/.backuper_panel.log)."
    print "Open: http://$(hostname -I | awk '{print $1}'):8080"
    return 0
}

menu() {
    update_os
    install_dependencies
    install_yq
    while true; do
        clear
        print "======== Backuper Menu [$VERSION] ========"
        print ""
        print "1️) Install Backuper"
        print "2) Restore Backup"
        print "3) Remove All Backups"
        print "4) Run All Backup Scripts"
        print "5) Web Panel"
        print "6) Exit"
        print ""
        input "Choose an option:" choice
        case $choice in
            1)
                start_backup
                ;;
            2)
                restore_backup
                ;;
            3)
                cleanup_backups
                ;;
            4)
                if compgen -G "/root/*${SCRIPT_SUFFIX}" > /dev/null; then
                    for script in /root/*${SCRIPT_SUFFIX}; do
                        log "Running backup script: $script"
                        bash "$script"
                    done
                else
                    warn "No backup scripts found in /root directory"
                fi
                confirm
                ;;
            5)
                install_panel
                ;;
            6)
                print "Thank you for using ${PROJECT_NAME}. Goodbye!"
                exit 0
                ;;
            *)
                wrong "Invalid option, Please select a valid option!"
                ;;
        esac
    done
}

cleanup_backups() {
    print "Removing all backups and cron jobs..."
    
    rm -rf /root/*"$SCRIPT_SUFFIX" /root/*"$TAG"* /root/*_backuper.sh /root/ac-backup*.sh /root/*backuper*.sh
    rm -rf /root/.backuper_*.conf /root/.backuper_*_upload.log /root/.backuper_restore /root/prerestore_*.zip

    crontab -l 2>/dev/null | grep -v "$SCRIPT_SUFFIX" | crontab -

    success "All backups and cron jobs have been removed."
    sleep 1
}

start_backup() {
    generate_remark
    generate_timer
    generate_template
    toggle_directories
    generate_platform
    generate_password
    generate_script
}

generate_remark() {
    clear
    print "[REMARK]\n"

    if noni; then
        REMARK="${BACKUPER_REMARK:-}"
        validate_remark || error "Invalid backup remark: ${REMARK:-<empty>}"
        if [[ -e "/root/_${REMARK}${SCRIPT_SUFFIX}" ]]; then
            error "A backup with the remark '${REMARK}' already exists. Remove it first or choose another remark."
        fi
        success "Backup remark: $REMARK"
        return 0
    fi

    print "We need a remark for the backup file (e.g., master, shop, server1).\n"

    while true; do
        input "Enter a remark: " REMARK

        if ! validate_remark; then
            :
        else
            success "Backup remark: $REMARK"
            break
        fi
    done
    sleep 1
}

validate_remark() {
    if ! [[ "$REMARK" =~ ^[a-zA-Z0-9_]+$ ]]; then
        wrong "Remark must contain only letters, numbers, or underscores."
        return 1
    elif [ ${#REMARK} -lt 3 ]; then
        wrong "Remark must be at least 3 characters long."
        return 1
    elif [ -e "${REMARK}${SCRIPT_SUFFIX}" ]; then
        wrong "File ${REMARK}${SCRIPT_SUFFIX} already exists. Choose a different remark."
        return 1
    fi
    return 0
}


generate_caption() {
    clear
    print "[CAPTION]\n"
    print "You can add a caption for your backup file (e.g., 'The main server of the company').\n"

    input "Enter your caption (Press Enter to skip): " CAPTION

    if [ -z "$CAPTION" ]; then
        success "No caption provided. Skipping..."
        CAPTION=""
    else
        CAPTION+='\n'
        success "Caption set: $CAPTION"
    fi

    sleep 1
}

minutes_to_cron() {
    local mins="$1"
    if [ "$mins" -le 59 ]; then
        echo "*/$mins * * * *"
    elif [ "$mins" -le 1439 ]; then
        local hours=$((mins / 60))
        local remaining_minutes=$((mins % 60))
        if [ "$remaining_minutes" -eq 0 ]; then
            echo "0 */$hours * * *"
        else
            echo "*/$remaining_minutes */$hours * * *"
        fi
    else
        echo "0 0 * * *"
    fi
}

generate_timer() {
    clear
    print "[TIMER]\n"

    if noni; then
        minutes="${BACKUPER_TIMER:-}"
        if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
            error "Backup interval must be a number of minutes."
        elif [ "$minutes" -lt 1 ] || [ "$minutes" -gt 1440 ]; then
            error "Backup interval must be between 1 and 1440 minutes."
        fi
        TIMER="$(minutes_to_cron "$minutes")"
        success "Cron job set to run every $minutes minutes: $TIMER"
        return 0
    fi

    print "Enter a time interval in minutes for sending backups."
    print "For example, '10' means backups will be sent every 10 minutes.\n"

    while true; do
        input "Enter the number of minutes (1-1440): " minutes

        if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
            wrong "Please enter a valid number."
        elif [ "$minutes" -lt 1 ] || [ "$minutes" -gt 1440 ]; then
            wrong "Number must be between 1 and 1440."
        else
            break
        fi
    done

    TIMER="$(minutes_to_cron "$minutes")"
    success "Cron job set to run every $minutes minutes: $TIMER"
    sleep 1
}


apply_template() {
    case "$1" in
        1) xui_template ;;
        2) sui_template ;;
        3) hiddify_template ;;
        4) remnawave_template ;;
        5) rebecca_template ;;
        6) marzneshin_template ;;
        7) marzneshin_logs_template ;;
        8) marzban_template ;;
        9) marzban_logs_template ;;
        10) mirzabot_template ;;
        11) walpanel_template ;;
        12) holderbot_template ;;
        13) marzhelp_template ;;
        14) phantom_template ;;
        15) ovpanel_template ;;
        16) ovnode_template ;;
        17) marzgozir_template ;;
        18) pasarguard_template ;;
        0) return 0 ;;
        *) return 1 ;;
    esac
}

generate_template() {
    clear
    print "[TEMPLATE]\n"
    print "Choose a backup template. You can add or remove custom DIRECTORIES after selecting.\n"
    print "1) X-ui"
    print "2) S-ui"
    print "3) Hiddify"
    print "4) Remnawave"
    print "5) Rebecca"
    print "6) Marzneshin"
    print "7) Marzneshin Logs"
    print "8) Marzban"
    print "9) Marzban Logs"
    print "10) MirzaBot"
    print "11) Walpanel"
    print "12) HolderBot"
    print "13) MarzHelp + Marzban"
    print "14) Phantom"
    print "15) OvPanel"
    print "16) OvNode"
    print "17) MarzGozir"
    print "18) PasarGuard"
    print "0) Custom"
    print ""

    if noni; then
        TEMPLATE="${BACKUPER_TEMPLATE:-0}"
        if ! apply_template "$TEMPLATE"; then
            error "Invalid template number: $TEMPLATE"
        fi
        return 0
    fi

    while true; do
        input "Enter your template number: " TEMPLATE
        if apply_template "$TEMPLATE"; then
            break
        fi
        wrong "Invalid option. Please choose a valid number!"
    done
}


add_directories() {
    local base_dir="$1"

    # Check if base directory exists
    [[ ! -d "$base_dir" ]] && { warn "Directory not found: $base_dir"; return; }

    # Find directories and filter based on exclude patterns
    mapfile -t items < <(find "$base_dir" -mindepth 1 -maxdepth 1 -type d \( -name "*mysql*" -prune -o -name "*mariadb*" -prune \) -o -print)

    for item in "${items[@]}"; do
        local exclude_item=false

        # Check if item matches any exclude pattern
        for pattern in "${exclude_patterns[@]}"; do
            if [[ "$item" =~ $pattern ]]; then
                exclude_item=true
                break
            fi
        done

        # Add item to backup list if it doesn't match any exclude pattern
        if ! $exclude_item; then
            success "Added to backup: $item"
            DIRECTORIES+=("$item")
        fi
    done
}

toggle_directories() {
    if noni; then
        local extra
        if [ -n "${BACKUPER_DIRS_EXTRA:-}" ]; then
            for extra in ${BACKUPER_DIRS_EXTRA}; do
                if [ ! -e "$extra" ]; then
                    error "Path does not exist: $extra"
                fi
                DIRECTORIES+=("$extra")
                success "Added to list: $extra"
            done
        fi
        BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
        return 0
    fi

    clear
    print "[TOGGLE DIRECTORIES]\n"
    print "Enter directories to add or remove. Type 'done' when finished.\n"
    
    while true; do
        print "\nCurrent directories:"
        for dir in "${DIRECTORIES[@]}"; do
            [[ -n "$dir" ]] && success "\t- $dir"
        done
        print ""

        input "Enter a path (or 'done' to finish): " path

        if [[ "$path" == "done" ]]; then
            break
        elif [[ ! -e "$path" ]]; then
            wrong "Path does not exist: $path"
        elif [[ " ${DIRECTORIES[*]} " =~ " ${path} " ]]; then
            DIRECTORIES=("${DIRECTORIES[@]/$path}")
            success "Removed from list: $path"
        else
            DIRECTORIES+=("$path")
            success "Added to list: $path"
        fi
    done
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
}


ovnode_template() {
    log "Checking OvNode configuration..."

    local OPENVPN_DB_FOLDER="/etc/openvpn"
    local OVNODE_DB_FOLDER="/opt/ov-node"

    # Check if the database file exists
    if [ ! -f "$OPENVPN_DB_FOLDER" ]; then
        error "OpenVPN file not found: $OPENVPN_DB_FOLDER"
        return 1
    fi
    if [ ! -f "$OVNODE_DB_FOLDER" ]; then
        error "Database file not found: $OVNODE_DB_FOLDER"
        return 1
    fi

    # Add the database file to BACKUP_DIRECTORIES
    add_directories "$OPENVPN_DB_FOLDER"
    add_directories "$OVNODE_DB_FOLDER"

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete OvNode"
    confirm
}

pasarguard_template() {
    log "Checking PasarGuard configuration..."
    local env_file="/opt/pasarguard/.env"

    [[ -f "$env_file" ]] || { error "Environment file not found: $env_file"; return 1; }

    local db_type db_name db_user db_password db_host db_port
    local BACKUP_DIRECTORIES=("/var/lib/pasarguard")  

    local DATABASE_URL=$(grep -v '^#' "$env_file" | grep 'SQLALCHEMY_DATABASE_URL' | awk -F '=' '{print $2}' | tr -d ' ' | tr -d '"' | tr -d "'")
    log "Detected DATABASE_URL: $DATABASE_URL"
    if [[ -z "$DATABASE_URL" || "$DATABASE_URL" == *"sqlite"* ]]; then
        db_type="sqlite"
        db_name=""
        db_user=""
        db_password=""
        db_host=""
        db_port=""
    else
        if [[ "$DATABASE_URL" =~ ^(postgresql|postgres|timescaledb)(\+[a-z0-9]+)?://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+)$ ]]; then
            db_type="${BASH_REMATCH[1]}"
            [[ "$db_type" == "postgres" ]] && db_type="postgresql"
            [[ "$db_type" == "timescaledb" ]] && db_type="postgresql"
            db_user="${BASH_REMATCH[3]}"
            db_password="${BASH_REMATCH[4]}"
            db_host="${BASH_REMATCH[5]}"
            db_port="${BASH_REMATCH[6]}"
            db_name="${BASH_REMATCH[7]}"
        elif [[ "$DATABASE_URL" =~ ^(postgresql|postgres|timescaledb)(\+[a-z0-9]+)?://([^:]+):([^@]+)@([^/]+)/(.+)$ ]]; then
            db_type="${BASH_REMATCH[1]}"
            [[ "$db_type" == "postgres" ]] && db_type="postgresql"
            [[ "$db_type" == "timescaledb" ]] && db_type="postgresql"
            db_user="${BASH_REMATCH[3]}"
            db_password="${BASH_REMATCH[4]}"
            db_host="${BASH_REMATCH[5]}"
            db_port="5432"
            db_name="${BASH_REMATCH[6]}"
        elif [[ "$DATABASE_URL" =~ ^(mysql|mariadb)(\+[a-z0-9]+)?://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+)$ ]]; then
            db_type="${BASH_REMATCH[1]}"
            db_user="${BASH_REMATCH[3]}"
            db_password="${BASH_REMATCH[4]}"
            db_host="${BASH_REMATCH[5]}"
            db_port="${BASH_REMATCH[6]}"
            db_name="${BASH_REMATCH[7]}"
        elif [[ "$DATABASE_URL" =~ ^(mysql|mariadb)(\+[a-z0-9]+)?://([^:]+):([^@]+)@([^/]+)/(.+)$ ]]; then
            db_type="${BASH_REMATCH[1]}"
            db_user="${BASH_REMATCH[3]}"
            db_password="${BASH_REMATCH[4]}"
            db_host="${BASH_REMATCH[5]}"
            db_port="3306"
            db_name="${BASH_REMATCH[6]}"
        else
            error "Invalid DATABASE_URL format in $env_file."
            return 1
        fi
    fi

    add_directories "/opt/pasarguard"
    add_directories "/var/lib/pasarguard"
    
    success "Database type: $db_type"
    success "Database user: $db_user"
    success "Database password: $db_password"
    success "Database host: $db_host"
    success "Database port: $db_port"
    success "Database name: $db_name"

    DB_PATH="/root/_${REMARK}${DATABASE_SUFFIX}"
    
    if [[ "$db_type" == "postgresql" ]]; then
        local pg_container=$(docker ps --filter "ancestor=postgres" --filter "ancestor=timescaledb/timescaledb" --format "{{.Names}}" | head -n 1)
        if [[ -z "$pg_container" ]]; then
            pg_container=$(docker ps --filter "publish=$db_port" --format "{{.Names}}" | head -n 1)
        fi
        BACKUP_DB_COMMAND="docker exec -e PGPASSWORD='$db_password' $pg_container pg_dump -U $db_user -d '$db_name' > $DB_PATH"
        RESTORE_DB_COMMAND="docker exec -i -e PGPASSWORD='$db_password' \$(docker ps --filter 'publish=$db_port' --format '{{.Names}}' | head -n 1) psql -U $db_user -d '$db_name' < $DB_PATH"
        DIRECTORIES+=($DB_PATH)
    elif [[ "$db_type" == "mysql" || "$db_type" == "mariadb" ]]; then
        BACKUP_DB_COMMAND="mysqldump --column-statistics=0 -h $db_host -P $db_port -u $db_user -p'$db_password' '$db_name' > $DB_PATH"
        RESTORE_DB_COMMAND="mysql -h $db_host -P $db_port -u $db_user -p'$db_password' '$db_name' < $DB_PATH"
        DIRECTORIES+=($DB_PATH)
    fi

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete PasarGuard"
    confirm
}


marzgozir_template() {
    log "Checking MarzGozir configuration..."

    local MARZGOZIR_DB_FOLDER="/opt/marzgozir/data"

    # Check if the database file exists
    if [ ! -f "$MARZGOZIR_DB_FOLDER" ]; then
        error "Database file not found: $MARZGOZIR_DB_FOLDER"
        return 1
    fi

    # Add the database file to BACKUP_DIRECTORIES
    add_directories "$MARZGOZIR_DB_FOLDER"

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete MarzGozir"
    confirm
}

remnawave_template() {
    log "Checking Remnawave configuration..."

    local REMNAWAVE_DR="/opt/remnawave"
    if [ ! -d "$REMNAWAVE_DR" ]; then
        error "Directory not found: $REMNAWAVE_DR"
        return 1
    fi

    env_file="/opt/remnawave/.env"
    if [ ! -f "$env_file" ]; then
        error "Environment file not found: $env_file"
        return 1
    fi

    # Extract SQLALCHEMY_DATABASE_URL from .env file
    local SQLALCHEMY_DATABASE_URL=$(grep -v '^#' "$env_file" | grep 'DATABASE_URL' | awk -F '=' '{print $2}' | tr -d ' ' | tr -d '"' | tr -d "'")

    if [[ "$SQLALCHEMY_DATABASE_URL" =~ ^postgresql://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+)$ ]]; then
        db_user="${BASH_REMATCH[1]}"
        db_password="${BASH_REMATCH[2]}"
        db_name="${BASH_REMATCH[5]}"
    else
        error "Invalid DATABASE_URL format in $env_file."
        return 1
    fi

    add_directories "$REMNAWAVE_DR"
    success "Database user: $db_user"
    success "Database password: $db_password"
    success "Database name: $db_name"

    DB_PATH="/root/_${REMARK}_${db_name}.sql"

    BACKUP_DB_COMMAND="docker exec -e PGPASSWORD='$db_password' \$(docker ps --filter 'publish=6767' --format '{{.Names}}' | head -n 1) pg_dump -U $db_user '$db_name' > $DB_PATH"
    RESTORE_DB_COMMAND="docker exec -i -e PGPASSWORD='$db_password' \$(docker ps --filter 'publish=6767' --format '{{.Names}}' | head -n 1) psql -U $db_user -d '$db_name' < $DB_PATH"
    DIRECTORIES+=($DB_PATH)

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete Remnawave"
    confirm

}


ovpanel_template() {
    log "Checking OvPanel configuration..."

    local OVPANEL_DB_FOLDER="/opt/ov-panel"

    # Check if the database file exists
    if [ ! -f "$OVPANEL_DB_FOLDER" ]; then
        error "Database file not found: $OVPANEL_DB_FOLDER"
        return 1
    fi


    # Add the database file to BACKUP_DIRECTORIES
    add_directories "$OVPANEL_DB_FOLDER/data"
    add_directories "$OVPANEL_DB_FOLDER/.env"

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete OvPanel"
    confirm
}

holderbot_template() {
    log "Checking HolderBot configuration..."
    
    # Set default value for HOLDER_FOLDER if not set
    local HOLDER_FOLDER="/opt/erfjab/holderbot/"

    # Check if the directory exists
    if [ ! -d "$HOLDER_FOLDER" ]; then
        error "Directory not found: $HOLDER_FOLDER"
        return 1
    fi

    # Add the directory to BACKUP_DIRECTORIES
    add_directories "$HOLDER_FOLDER"

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete HolderBot"
    confirm
}

walpanel_template() {
    log "Checking WalPanel configuration..."
    
    # Set default value for WALDB_FOLDER if not set
    local WALDB_FOLDER="/opt/walpanel/app/data"

    # Check if the directory exists
    if [ ! -d "$WALDB_FOLDER" ]; then
        error "Directory not found: $WALDB_FOLDER"
        return 1
    fi

    # Add the directory to BACKUP_DIRECTORIES
    add_directories "$WALDB_FOLDER"

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete WalPanel"
    confirm
}

phantom_template() {
    log "Checking Phantom configuration..."

    # Set default value for PHANTOM_FOLDER if not set
    local PHANTOM_FOLDER="/etc/phantom/config.db"

    # Check if the directory exists
    if [ ! -d "$PHANTOM_FOLDER" ]; then
        error "Directory not found: $PHANTOM_FOLDER"
        return 1
    fi

    # Add the directory to BACKUP_DIRECTORIES
    add_directories "$PHANTOM_FOLDER"

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete Phantom"
    confirm
}


xui_template() {
    log "Checking X-ui configuration..."
    
    # Set default value for XUI_DB_FOLDER if not set
    local XUI_DB_FOLDER="${XUI_DB_FOLDER:-/etc/x-ui}"

    # Check if the directory exists
    if [ ! -d "$XUI_DB_FOLDER" ]; then
        error "Directory not found: $XUI_DB_FOLDER"
        return 1
    fi

    # Add the directory to BACKUP_DIRECTORIES
    add_directories "$XUI_DB_FOLDER"

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete X-ui"
    confirm
}

sui_template() {
    log "Checking S-ui configuration..."
    
    # Set default value for XUI_DB_FOLDER if not set
    local SUI_DB_FOLDER="${SUI_DB_FOLDER:-/usr/local/s-ui/db}"

    # Check if the directory exists
    if [ ! -d "$SUI_DB_FOLDER" ]; then
        error "Directory not found: $SUI_DB_FOLDER"
        return 1
    fi

    # Add the directory to BACKUP_DIRECTORIES
    add_directories "$SUI_DB_FOLDER"

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete S-ui"
    confirm
}

marzneshin_logs_template() {
    log "Checking Marzneshin configuration..."
    local docker_compose_file="/etc/opt/marzneshin/docker-compose.yml"

    # Check if docker-compose file exists
    if [[ ! -f "$docker_compose_file" ]]; then
        error "Docker compose file not found: $docker_compose_file"
        return 1
    fi

    # Define log file path
    local DB_PATH="/root/_${REMARK}${LOGS_SUFFIX}"

    # Check if marzneshin command exists
    if ! command -v marzneshin &> /dev/null; then
        error "marzneshin command not found. Please ensure it is installed."
        return 1
    fi

    # Run marzneshin logs command
    if ! marzneshin logs --no-follow > "$DB_PATH"; then
        error "Failed to export Marzneshin logs to $DB_PATH"
        return 1
    fi

    # Add log file path to DIRECTORIES
    DIRECTORIES=()
    DIRECTORIES+=($DB_PATH)

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Marzneshin logs backup completed successfully."
    confirm
}

marzneshin_template() {
    log "Checking Marzneshin configuration..."
    local docker_compose_file="/etc/opt/marzneshin/docker-compose.yml"

    # Check if docker-compose file exists
    [[ -f "$docker_compose_file" ]] || { error "Docker compose file not found: $docker_compose_file"; return 1; }

    # Extract database configuration
    local db_type db_name db_password db_port
    DB_TYPE=$(yq eval '.services.db.image' "$docker_compose_file")
    DB_NAME=$(yq eval '.services.db.environment.MARIADB_DATABASE // .services.db.environment.MYSQL_DATABASE' "$docker_compose_file")
    DB_PASSWORD=$(yq eval '.services.db.environment.MARIADB_ROOT_PASSWORD // .services.db.environment.MYSQL_ROOT_PASSWORD' "$docker_compose_file")
    DB_PORT=$(yq eval '.services.db.ports[0]' "$docker_compose_file" | cut -d':' -f2)

    # Determine database type
    if [[ "$DB_TYPE" == *"mariadb"* ]]; then
        DB_TYPE="mariadb"
    elif [[ "$DB_TYPE" == *"mysql"* ]]; then
        DB_TYPE="mysql"
    else
        DB_TYPE="sqlite"
    fi

    # Validate database password for non-sqlite databases
    if [[ "$DB_TYPE" != "sqlite" && -z "$DB_PASSWORD" ]]; then
        error "Database password not found"
        return 1
    fi

    # Setup backup configuration
    local DB_PATH="/root/_${REMARK}${DATABASE_SUFFIX}"
    DIRECTORIES=()

    # Scan default DIRECTORIES
    log "Scanning DIRECTORIES..."
    add_directories "/etc/opt/marzneshin"

    # Extract volumes from docker-compose
    log "Extracting volumes from docker-compose..."
    for service in $(yq eval '.services | keys | .[]' "$docker_compose_file"); do
        for volume in $(yq eval ".services.$service.volumes | .[]" "$docker_compose_file" 2>/dev/null | awk -F ':' '{print $1}'); do
            [[ -d "$volume" && ! "$volume" =~ /(mysql|mariadb)$ ]] && add_directories "$volume"
        done
    done

    # Generate backup command for non-sqlite databases
    if [[ "$DB_TYPE" != "sqlite" ]]; then
        BACKUP_DB_COMMAND="mysqldump -h 127.0.0.1 --column-statistics=0 -P $DB_PORT -u root -p'$DB_PASSWORD' '$DB_NAME' > $DB_PATH"
        RESTORE_DB_COMMAND="mysql -h 127.0.0.1 -P $DB_PORT -u root -p'$DB_PASSWORD' '$DB_NAME' < $DB_PATH"
        DIRECTORIES+=($DB_PATH)
    fi

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete Marzneshin"
    confirm
}

marzban_logs_template() {
    log "Checking Marzban configuration..."
    local docker_compose_file="/opt/marzban/docker-compose.yml"

    # Check if docker-compose file exists
    if [[ ! -f "$docker_compose_file" ]]; then
        error "Docker compose file not found: $docker_compose_file"
        return 1
    fi

    # Define log file path
    local DB_PATH="/root/_${REMARK}${LOGS_SUFFIX}"

    # Check if marzban command exists
    if ! command -v marzban &> /dev/null; then
        error "marzban command not found. Please ensure it is installed."
        return 1
    fi

    # Run marzban logs command
    if ! marzban logs --no-follow > "$DB_PATH"; then
        error "Failed to export marzban logs to $DB_PATH"
        return 1
    fi

    # Add log file path to DIRECTORIES
    DIRECTORIES=()
    DIRECTORIES+=($DB_PATH)

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "marzban logs backup completed successfully."
    confirm
}

marzban_template() {
    log "Checking environment file..."
    local env_file="/opt/marzban/.env"

    [[ -f "$env_file" ]] || { error "Environment file not found: $env_file"; return 1; }

    local db_type db_name db_user db_password db_host db_port
    local BACKUP_DIRECTORIES=("/var/lib/marzban")  # Add default volume

    # Extract SQLALCHEMY_DATABASE_URL from .env file
    local SQLALCHEMY_DATABASE_URL=$(grep -v '^#' "$env_file" | grep 'SQLALCHEMY_DATABASE_URL' | awk -F '=' '{print $2}' | tr -d ' ' | tr -d '"' | tr -d "'")

    if [[ -z "$SQLALCHEMY_DATABASE_URL" || "$SQLALCHEMY_DATABASE_URL" == *"sqlite3"* ]]; then
        db_type="sqlite3"
        db_name=""
        db_user=""
        db_password=""
        db_host=""
        db_port=""
    else
        # Parse SQLALCHEMY_DATABASE_URL to extract database details
        if [[ "$SQLALCHEMY_DATABASE_URL" =~ ^(mysql\+pymysql|mariadb\+pymysql)://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+)$ ]]; then
            db_type="${BASH_REMATCH[1]%%+*}"  # Extract mysql or mariadb
            db_user="${BASH_REMATCH[2]}"
            db_password="${BASH_REMATCH[3]}"
            db_host="${BASH_REMATCH[4]}"
            db_port="${BASH_REMATCH[5]}"
            db_name="${BASH_REMATCH[6]}"
        elif [[ "$SQLALCHEMY_DATABASE_URL" =~ ^(mysql\+pymysql|mariadb\+pymysql)://([^:]+):([^@]+)@([0-9.]+)/(.+)$ ]]; then
            db_type="${BASH_REMATCH[1]%%+*}"  # Extract mysql or mariadb
            db_user="${BASH_REMATCH[2]}"
            db_password="${BASH_REMATCH[3]}"
            db_host="${BASH_REMATCH[4]}"
            db_port="3306"  # Default MySQL/MariaDB port
            db_name="${BASH_REMATCH[5]}"
        else
            error "Invalid SQLALCHEMY_DATABASE_URL format in $env_file."
            return 1
        fi
    fi
    add_directories "/opt/marzban"
    add_directories "/var/lib/marzban"
    success "Database type: $db_type"
    success "Database user: $db_user"
    success "Database password: $db_password"
    success "Database host: $db_host"
    success "Database port: $db_port"
    success "Database name: $db_name"

    local DB_PATH="/root/_${REMARK}${DATABASE_SUFFIX}"
    # Generate backup command for MySQL/MariaDB
    if [[ "$db_type" != "sqlite3" ]]; then
        BACKUP_DB_COMMAND="mysqldump --column-statistics=0 -h $db_host -P $db_port -u $db_user -p'$db_password' '$db_name' > $DB_PATH"
        RESTORE_DB_COMMAND="mysql -h $db_host -P $db_port -u $db_user -p'$db_password' '$db_name' < $DB_PATH"
        DIRECTORIES+=($DB_PATH)
    fi

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete Marzban"
    confirm
}


rebecca_template() {
    log "Checking environment file..."
    local env_file="/opt/rebecca/.env"

    [[ -f "$env_file" ]] || { error "Environment file not found: $env_file"; return 1; }

    local db_type db_name db_user db_password db_host db_port
    local BACKUP_DIRECTORIES=("/var/lib/rebecca")  # Add default volume

    # Extract SQLALCHEMY_DATABASE_URL from .env file
    local SQLALCHEMY_DATABASE_URL=$(grep -v '^#' "$env_file" | grep 'SQLALCHEMY_DATABASE_URL' | awk -F '=' '{print $2}' | tr -d ' ' | tr -d '"' | tr -d "'")

    if [[ -z "$SQLALCHEMY_DATABASE_URL" || "$SQLALCHEMY_DATABASE_URL" == *"sqlite3"* ]]; then
        db_type="sqlite3"
        db_name=""
        db_user=""
        db_password=""
        db_host=""
        db_port=""
    else
        # Parse SQLALCHEMY_DATABASE_URL to extract database details
        if [[ "$SQLALCHEMY_DATABASE_URL" =~ ^(mysql\+pymysql|mariadb\+pymysql)://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+)$ ]]; then
            db_type="${BASH_REMATCH[1]%%+*}"  # Extract mysql or mariadb
            db_user="${BASH_REMATCH[2]}"
            db_password="${BASH_REMATCH[3]}"
            db_host="${BASH_REMATCH[4]}"
            db_port="${BASH_REMATCH[5]}"
            db_name="${BASH_REMATCH[6]}"
        elif [[ "$SQLALCHEMY_DATABASE_URL" =~ ^(mysql\+pymysql|mariadb\+pymysql)://([^:]+):([^@]+)@([0-9.]+)/(.+)$ ]]; then
            db_type="${BASH_REMATCH[1]%%+*}"  # Extract mysql or mariadb
            db_user="${BASH_REMATCH[2]}"
            db_password="${BASH_REMATCH[3]}"
            db_host="${BASH_REMATCH[4]}"
            db_port="3306"  # Default MySQL/MariaDB port
            db_name="${BASH_REMATCH[5]}"
        else
            error "Invalid SQLALCHEMY_DATABASE_URL format in $env_file."
            return 1
        fi
    fi
    add_directories "/opt/rebecca"
    add_directories "/var/lib/rebecca"
    success "Database type: $db_type"
    success "Database user: $db_user"
    success "Database password: $db_password"
    success "Database host: $db_host"
    success "Database port: $db_port"
    success "Database name: $db_name"

    local DB_PATH="/root/_${REMARK}${DATABASE_SUFFIX}"
    # Generate backup command for MySQL/MariaDB
    if [[ "$db_type" != "sqlite3" ]]; then
        BACKUP_DB_COMMAND="mysqldump --column-statistics=0 -h $db_host -P $db_port -u $db_user -p'$db_password' '$db_name' > $DB_PATH"
        RESTORE_DB_COMMAND="mysql -h $db_host -P $db_port -u $db_user -p'$db_password' '$db_name' < $DB_PATH"
        DIRECTORIES+=($DB_PATH)
    fi

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete Rebecca"
    confirm
}


marzhelp_template() {
    log "Checking environment file..."
    local env_file="/opt/marzban/.env"

    [[ -f "$env_file" ]] || { error "Environment file not found: $env_file"; exit 1; }

    # Check for MYSQL_ROOT_PASSWORD in .env
    local MYSQL_ROOT_PASSWORD=$(grep -v '^#' "$env_file" | grep 'MYSQL_ROOT_PASSWORD' | awk -F '=' '{print $2}' | tr -d ' ' | tr -d '"' | tr -d "'")
    if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
        error "MYSQL_ROOT_PASSWORD not found in $env_file. Please add it to the Marzban env file."
        exit 1
    fi

    local db_type db_name db_user db_password db_host db_port
    local BACKUP_DIRECTORIES=("/var/lib/marzban")  # Add default volume

    # Extract SQLALCHEMY_DATABASE_URL from .env file
    local SQLALCHEMY_DATABASE_URL=$(grep -v '^#' "$env_file" | grep 'SQLALCHEMY_DATABASE_URL' | awk -F '=' '{print $2}' | tr -d ' ' | tr -d '"' | tr -d "'")

    if [[ -z "$SQLALCHEMY_DATABASE_URL" || "$SQLALCHEMY_DATABASE_URL" == *"sqlite3"* ]]; then
        error "SQLite database detected. This script only supports MySQL/MariaDB databases."
        exit 1
    fi

    # Parse SQLALCHEMY_DATABASE_URL to extract database details
    if [[ "$SQLALCHEMY_DATABASE_URL" =~ ^(mysql\+pymysql|mariadb\+pymysql)://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+)$ ]]; then
        db_type="${BASH_REMATCH[1]%%+*}"  # Extract mysql or mariadb
        db_user="${BASH_REMATCH[2]}"
        db_password="${BASH_REMATCH[3]}"
        db_host="${BASH_REMATCH[4]}"
        db_port="${BASH_REMATCH[5]}"
        db_name="${BASH_REMATCH[6]}"
    elif [[ "$SQLALCHEMY_DATABASE_URL" =~ ^(mysql\+pymysql|mariadb\+pymysql)://([^:]+):([^@]+)@([0-9.]+)/(.+)$ ]]; then
        db_type="${BASH_REMATCH[1]%%+*}"  # Extract mysql or mariadb
        db_user="${BASH_REMATCH[2]}"
        db_password="${BASH_REMATCH[3]}"
        db_host="${BASH_REMATCH[4]}"
        db_port="3306"  # Default MySQL/MariaDB port
        db_name="${BASH_REMATCH[5]}"
    else
        error "Invalid SQLALCHEMY_DATABASE_URL format in $env_file."
        exit 1
    fi

    # Check if marzhelp database exists
    log "Checking if marzhelp database exists..."
    if ! mysqlshow -h "$db_host" -P "$db_port" -u root -p"$MYSQL_ROOT_PASSWORD" marzhelp &>/dev/null; then
        error "marzhelp database not found or not accessible. Please ensure it exists and you have proper permissions."
        exit 1
    fi
    
    local MARZHELP_DB_PATH="/root/__${REMARK}${DATABASE_SUFFIX}"
    local MARZHELP_BACKUP_COMMAND="mysqldump -h $db_host -P $db_port -u root -p'$MYSQL_ROOT_PASSWORD' 'marzhelp' > $MARZHELP_DB_PATH"
    BACKUP_COMMANDS+=("$MARZHELP_BACKUP_COMMAND")
    DIRECTORIES+=("$MARZHELP_DB_PATH")

    add_directories "/opt/marzban"
    DIRECTORIES+=("/root/marzhelp.txt")
    add_directories "/var/lib/marzban"
    success "Database type: $db_type"
    success "Database user: $db_user"
    success "Database password: $db_password"
    success "Database host: $db_host"
    success "Database port: $db_port"
    success "Database name: $db_name"
    success "MarzHelp database exists and is accessible"

    local DB_PATH="/root/_${REMARK}${DATABASE_SUFFIX}"
    # Generate backup command for MySQL/MariaDB
    BACKUP_DB_COMMAND="mysqldump -h $db_host -P $db_port -u $db_user -p'$db_password' '$db_name' > $DB_PATH"
    DIRECTORIES+=($DB_PATH)

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    BACKUP_DB_COMMAND="$BACKUP_DB_COMMAND && $MARZHELP_BACKUP_COMMAND"
    RESTORE_DB_COMMAND="mysql -h $db_host -P $db_port -u $db_user -p'$db_password' '$db_name' < $DB_PATH && mysql -h $db_host -P $db_port -u root -p'$MYSQL_ROOT_PASSWORD' 'marzhelp' < $MARZHELP_DB_PATH"
    log "Complete Marzban + MarzHelp"
    confirm
}

mirzabot_template() {
    log "Checking MirzaBot file..."
    local mirzabot_file='/var/www/html/mirzabotconfig/config.php'
    
    [[ -f "$mirzabot_file" ]] || { error "MirzaBot file not found: $mirzabot_file"; return 1; }

    # Extract database values from config.php
    db_name=$(grep -m 1 "\$dbname" $mirzabot_file | sed -E "s/.*dbname\s*=\s*'([^']+)'.*/\1/")
    db_user=$(grep -m 1 "\$usernamedb" $mirzabot_file | sed -E "s/.*usernamedb\s*=\s*'([^']+)'.*/\1/")
    db_password=$(grep -m 1 "\$passworddb" $mirzabot_file | sed -E "s/.*passworddb\s*=\s*'([^']+)'.*/\1/")

    # Check if the values are extracted correctly
    if [ -z "$db_name" ] || [ -z "$db_password" ] || [ -z "$db_user" ]; then
        error "Failed to extract database values from $mirzabot_file."
        exit 1
    fi

    # Generate backup command for MySQL/MariaDB
    local DB_PATH="/root/_${REMARK}${DATABASE_SUFFIX}"
    BACKUP_DB_COMMAND="mysqldump -u $db_user -p'$db_password' '$db_name' > $DB_PATH"
    RESTORE_DB_COMMAND="mysql -h 127.0.0.1 -u $db_user -p'$db_password' '$db_name' < $DB_PATH"
    DIRECTORIES+=($DB_PATH)

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Complete MirzaBot"
    confirm
}

hiddify_template() {
    log "Checking Hiddify configuration..."
    
    # Set default value for HIDDIFY_DB_FOLDER if not set
    local HIDDIFY_DB_FOLDER="/opt/hiddify-manager/hiddify-panel/backup.sh"
    local BACKUP_FOLDER="/opt/hiddify-manager/hiddify-panel/backup"

    # Check if the backup script exists
    if [ ! -f "$HIDDIFY_DB_FOLDER" ]; then
        error "Backup script not found: $HIDDIFY_DB_FOLDER"
        return 1
    fi

    # Create backup directory if it doesn't exist
    if [ ! -d "$BACKUP_FOLDER" ]; then
        log "Creating backup directory: $BACKUP_FOLDER"
        mkdir -p "$BACKUP_FOLDER"
        if [ $? -ne 0 ]; then
            error "Failed to create backup directory: $BACKUP_FOLDER"
            return 1
        fi
    fi

    # Set full access permissions to the backup directory and script
    log "Setting permissions for backup directory and script..."
    chmod -R 755 "$BACKUP_FOLDER"
    chmod 755 "$HIDDIFY_DB_FOLDER"

    # Add the directory to BACKUP_DIRECTORIES
    add_directories "$BACKUP_FOLDER"

    # Set the backup command
    BACKUP_DB_COMMAND="bash $HIDDIFY_DB_FOLDER"

    # Export backup variables
    BACKUP_DIRECTORIES="${DIRECTORIES[*]}"
    log "Hiddify configuration completed successfully."
    confirm
}

generate_password() {
    COMPRESS="zip -9 -r"

    if noni; then
        PASSWORD="${BACKUPER_PASSWORD:-}"
        if [ -n "$PASSWORD" ]; then
            if [[ ! "$PASSWORD" =~ ^[a-zA-Z0-9]{8,}$ ]]; then
                error "Password must be at least 8 characters long and contain only letters and numbers."
            fi
            COMPRESS="zip -9 -r -e -P $PASSWORD -s ${LIMITSIZE}m"
            success "Archive password enabled."
        else
            PASSWORD=""
            COMPRESS="zip -9 -r -s ${LIMITSIZE}m"
            success "No password will be set for the archive."
        fi
        return 0
    fi

    clear
    print "[PASSWORD PROTECTION]\n"
    print "You can set a password for the archive. The password must contain both letters and numbers, and be at least 8 characters long.\n"
    print "If you don't want a password, just press Enter.\n"

    while true; do
        input "Enter the password for the archive (or press Enter to skip): " PASSWORD
        
        # If password is empty, skip password protection
        if [ -z "$PASSWORD" ]; then
            success "No password will be set for the archive."
            COMPRESS="zip -9 -r -s ${LIMITSIZE}m"
            break
        fi

        # Validate password
        if [[ ! "$PASSWORD" =~ ^[a-zA-Z0-9]{8,}$ ]]; then
            wrong "Password must be at least 8 characters long and contain only letters and numbers. Please try again."
            continue
        fi

        input "Confirm the password: " CONFIRM_PASSWORD
        
        if [ "$PASSWORD" == "$CONFIRM_PASSWORD" ]; then
            success "Password confirmed."
            COMPRESS="$COMPRESS -e -P $PASSWORD -s ${LIMITSIZE}m"
            break
        else
            wrong "Passwords do not match. Please try again."
        fi
    done
}


generate_platform() {
    if noni; then
        case "${BACKUPER_PLATFORM:-}" in
            telegram)
                PLATFORM="telegram"
                telegram_progress
                ;;
            discord)
                PLATFORM="discord"
                discord_progress
                ;;
            gmail)
                PLATFORM="gmail"
                gmail_progress
                ;;
            *)
                error "Invalid or missing platform. Use telegram, discord or gmail."
                ;;
        esac
        return 0
    fi

    clear
    print "[PLATFORM]\n"
    print "Select one platform to send your backup.\n"
    print "1) Telegram"
    print "2) Discord"
    print "3) Gmail"
    print ""

    while true; do
        input "Enter your choice : " choice

        case $choice in
            1)
                PLATFORM="telegram"
                telegram_progress
                break
                ;;
            2)
                PLATFORM="discord"
                discord_progress
                break
                ;;
            3)
                PLATFORM="gmail"
                gmail_progress
                break
                ;;
            *)
                wrong "Invalid option, Please select with number."
                ;;
        esac
    done
    sleep 1
}


telegram_test_connection() {
    local response
    log "Checking Telegram bot..."
    if [[ -n "${TOPIC_ID:-}" ]]; then
        response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d message_thread_id="$TOPIC_ID" -d text="Hi, Backuper Test Message!")
    else
        response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d text="Hi, Backuper Test Message!")
    fi
    [[ "$response" -eq 200 ]]
}

telegram_finalize() {
    if [[ -n "$TOPIC_ID" ]]; then
        PLATFORM_COMMAND="curl -s -F \"chat_id=$CHAT_ID\" -F \"message_thread_id=$TOPIC_ID\" -F \"document=@\$FILE\" -F \"caption=\$CAPTION\" -F \"parse_mode=HTML\" \"https://api.telegram.org/bot$BOT_TOKEN/sendDocument\""
    else
        PLATFORM_COMMAND="curl -s -F \"chat_id=$CHAT_ID\" -F \"document=@\$FILE\" -F \"caption=\$CAPTION\" -F \"parse_mode=HTML\" \"https://api.telegram.org/bot$BOT_TOKEN/sendDocument\""
    fi

    CAPTION="
📦 <b>${PROJECT_NAME}</b>
<b>From </b><code>\${ip}</code>
<a href='${PROJECT_OWNER_LINK}'>${PROJECT_OWNER}</a>"
    LIMITSIZE=49
    success "Telegram configuration completed successfully."
}

telegram_progress() {
    clear
    print "[TELEGRAM]\n"

    if noni; then
        BOT_TOKEN="${BACKUPER_TG_TOKEN:-}"
        CHAT_ID="${BACKUPER_TG_CHAT:-}"
        TOPIC_ID="${BACKUPER_TG_TOPIC:-}"
        [[ "$BOT_TOKEN" =~ ^[0-9]+:[a-zA-Z0-9_-]{35}$ ]] || error "Invalid Telegram bot token format."
        [[ "$CHAT_ID" =~ ^-?[0-9]+$ ]] || error "Invalid Telegram chat ID format."
        [[ -z "$TOPIC_ID" || "$TOPIC_ID" =~ ^[0-9]+$ ]] || error "Invalid Telegram topic ID."
        telegram_test_connection || error "Telegram credentials are not valid. Check the bot token, chat ID and topic ID (and start the bot)."
        success "Bot token and chat ID are valid."
        telegram_finalize
        return 0
    fi

    print "To use Telegram, you need to provide a bot token and a chat ID.\n"

    while true; do
        # Get bot token
        while true; do
            input "Enter the bot token: " BOT_TOKEN
            if [[ -z "$BOT_TOKEN" ]]; then
                wrong "Bot token cannot be empty!"
            elif [[ ! "$BOT_TOKEN" =~ ^[0-9]+:[a-zA-Z0-9_-]{35}$ ]]; then
                wrong "Invalid bot token format!"
            else
                break
            fi
        done

        # Get chat ID
        while true; do
            input "Enter the chat ID: " CHAT_ID
            if [[ -z "$CHAT_ID" ]]; then
                wrong "Chat ID cannot be empty!"
            elif [[ ! "$CHAT_ID" =~ ^-?[0-9]+$ ]]; then
                wrong "Invalid chat ID format!"
            else
                break
            fi
        done

        while true; do
            input "Enter the topic ID (Press Enter to skip): " TOPIC_ID
            if [[ -z "$TOPIC_ID" ]]; then
                success "No topic ID provided. Messages will be sent to the main chat."
                TOPIC_ID=""
                break
            elif [[ ! "$TOPIC_ID" =~ ^[0-9]+$ ]]; then
                wrong "Invalid topic ID format! Must be a number."
            else
                success "Topic ID set: $TOPIC_ID"
                break
            fi
        done

        if telegram_test_connection; then
            success "Bot token and chat ID are valid."
            break
        else
            wrong "Invalid bot token, chat ID, topic ID, or Telegram API error! [tip: start bot]"
        fi
    done

    telegram_finalize
    sleep 1
}


discord_test_connection() {
    local response
    log "Checking Discord Webhook..."
    response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$DISCORD_WEBHOOK" -H "Content-Type: application/json" -d '{"content": "Hi, Backuper Test Message!"}')
    [[ "$response" -eq 204 ]]
}

discord_finalize() {
    PLATFORM_COMMAND="curl -s -F \"file=@\$FILE\" -F \"payload_json={\\\"content\\\": \\\"\$CAPTION\\\"}\" \"$DISCORD_WEBHOOK\""
    CAPTION="📦 **${PROJECT_NAME}**\n**From** \`${ip}\`\n[${PROJECT_OWNER}](${PROJECT_OWNER_LINK})"
    LIMITSIZE=24
    success "Discord configuration completed successfully."
}

discord_progress() {
    clear
    print "[DISCORD]\n"

    if noni; then
        DISCORD_WEBHOOK="${BACKUPER_DISCORD_WEBHOOK:-}"
        [[ "$DISCORD_WEBHOOK" =~ ^https://discord\.com/api/webhooks/ ]] || error "Invalid Discord webhook URL."
        discord_test_connection || error "Discord webhook is not valid."
        success "Webhook URL is valid."
        discord_finalize
        return 0
    fi

    print "To use Discord, you need to provide a Webhook URL.\n"

    while true; do
        # Get Discord Webhook URL
        while true; do
            input "Enter the Discord Webhook URL: " DISCORD_WEBHOOK
            if [[ -z "$DISCORD_WEBHOOK" ]]; then
                wrong "Webhook URL cannot be empty!"
            elif [[ ! "$DISCORD_WEBHOOK" =~ ^https://discord\.com/api/webhooks/ ]]; then
                wrong "Invalid Discord Webhook URL format!"
            else
                break
            fi
        done

        if discord_test_connection; then
            success "Webhook URL is valid."
            break
        else
            wrong "Invalid Webhook URL or Discord API error!"
        fi
    done

    discord_finalize
    sleep 1
}




gmail_test_connection() {
    log "Testing Gmail SMTP authentication..."
    echo -e "Subject: Test Email\n\nThis is a test message." | msmtp \
        --host=smtp.gmail.com \
        --port=587 \
        --tls=on \
        --auth=on \
        --user="$GMAIL_ADDRESS" \
        --passwordeval="echo '$GMAIL_PASSWORD'" \
        -f "$GMAIL_ADDRESS" \
        "$GMAIL_ADDRESS"
}

gmail_finalize() {
    cat > ~/.msmtprc <<EOF
account gmail
host smtp.gmail.com
port 587
auth on
tls on
tls_starttls on
user $GMAIL_ADDRESS
password $GMAIL_PASSWORD
from $GMAIL_ADDRESS
logfile ~/.msmtp.log
account default : gmail
EOF

    chmod 600 ~/.msmtprc

    cat > ~/.muttrc <<EOF
set sendmail="/usr/bin/msmtp"
set use_from=yes
set realname="Backup System"
set from="$GMAIL_ADDRESS"
set envelope_from=yes
EOF

    chmod 600 ~/.muttrc
    CAPTION="<html><body><p><b>📦 ${PROJECT_NAME}</b></p><p><b>From </b><code>\${ip}</code></p><p><a href='${PROJECT_OWNER_LINK}'>${PROJECT_OWNER}</a></p></body></html>"
    PLATFORM_COMMAND="echo \$CAPTION | mutt -e 'set content_type=text/html' -s '${PROJECT_NAME}' -a \"\$FILE\" -- \"$GMAIL_ADDRESS\""
    LIMITSIZE=24
    success "Gmail configuration completed successfully."
}

gmail_progress() {
    clear
    print "[GMAIL]\n"

    if noni; then
        GMAIL_ADDRESS="${BACKUPER_GMAIL_ADDRESS:-}"
        GMAIL_PASSWORD="${BACKUPER_GMAIL_PASSWORD:-}"
        GMAIL_PASSWORD="${GMAIL_PASSWORD// /}"
        [[ "$GMAIL_ADDRESS" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || error "Invalid Gmail address."
        [[ -n "$GMAIL_PASSWORD" ]] || error "Gmail app password is required."
        gmail_test_connection || error "Gmail authentication failed. Check the address and the app password."
        success "Authentication successful! Configuring msmtp and mutt..."
        gmail_finalize
        return 0
    fi

    print "To use Gmail, you need to provide your email and an app password.\n"
    print "🔴 Do NOT use your real password! Generate an 'App Password' from Google settings.\n"

    while true; do
        while true; do
            input "Enter your Gmail address: " GMAIL_ADDRESS
            if [[ -z "$GMAIL_ADDRESS" ]]; then
                wrong "Email cannot be empty!"
            elif [[ ! "$GMAIL_ADDRESS" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                wrong "Invalid email format!"
            else
                break
            fi
        done

        while true; do
            input "Enter your Gmail app password: " GMAIL_PASSWORD
            if [[ -z "$GMAIL_PASSWORD" ]]; then
                wrong "Password cannot be empty!"
            else
                break
            fi
        done

        if gmail_test_connection; then
            success "Authentication successful! Configuring msmtp and mutt..."
            gmail_finalize
            break
        else
            wrong "Authentication failed! Check your email or app password and try again."
            sleep 3
            clear
        fi
    done

    sleep 1
}




###############################################################################
# RESTORE
###############################################################################

readonly RESTORE_TMP_DIR="/root/.backuper_restore"

restore_state_file() { echo "/root/.backuper_${1}.conf"; }
restore_upload_log() { echo "/root/.backuper_${1}_upload.log"; }

restore_reset() {
    REMARK=""
    PLATFORM=""
    BACKUP_DIRECTORIES=""
    DB_DUMP_PATH=""
    RESTORE_DB_COMMAND=""
    TG_TOKEN=""
    TG_CHAT=""
    TG_TOPIC=""
    DISCORD_WEBHOOK=""
    GMAIL_ADDRESS=""
    GMAIL_PASSWORD=""
    ZIP_PASSWORD=""
    ARCHIVE_FILES=()
    UNZIP_ARGS=()
    RESTORE_ZIP=""
    RESTORE_DIR=""
    RESTORE_SNAPSHOT=""
}

restore_load_state() {
    local file="$1"
    # shellcheck disable=SC1090
    if ! source "$file"; then
        wrong "Failed to load configuration: $file"
        return 1
    fi
    [[ -n "$REMARK" ]] || { wrong "Invalid configuration file: $file"; return 1; }
    success "Loaded saved configuration for remark: $REMARK (${PLATFORM:-unknown})"
    sleep 1
    return 0
}

restore_manual_config() {
    local remark="" choice=""

    print ""
    print "[MANUAL RESTORE]"
    print ""
    while true; do
        input "Backup remark (e.g. master): " remark
        if [[ ! "$remark" =~ ^[a-zA-Z0-9_]+$ ]]; then
            wrong "Remark must contain only letters, numbers or underscores."
        elif [ ${#remark} -lt 3 ]; then
            wrong "Remark must be at least 3 characters long."
        else
            break
        fi
    done
    REMARK="$remark"

    print ""
    print "Where is the backup stored?"
    print "1) Telegram"
    print "2) Discord"
    print "3) Gmail"
    print "4) Local file on this server"
    print "0) Back"
    print ""
    while true; do
        input "Choose an option: " choice
        case $choice in
            0) return 1 ;;
            1) PLATFORM="telegram"; break ;;
            2) PLATFORM="discord"; break ;;
            3) PLATFORM="gmail"; break ;;
            4) PLATFORM="local"; break ;;
            *) wrong "Invalid option, Please select a valid option!" ;;
        esac
    done
    return 0
}

restore_override_source() {
    local src=""
    print ""
    input "Source to restore from [${PLATFORM:-local}] (Enter to keep, or telegram/discord/gmail/local): " src
    case "$src" in
        "" ) return 0 ;;
        telegram|discord|gmail|local) PLATFORM="$src" ;;
        *) wrong "Unknown source, keeping: ${PLATFORM:-local}" ;;
    esac
    return 0
}

restore_choose_source() {
    local states=() choice="" i=1 f remark platform

    if noni; then
        REMARK="${BACKUPER_RESTORE_REMARK:-}"
        if [ -n "$REMARK" ] && [ -f "$(restore_state_file "$REMARK")" ]; then
            # shellcheck disable=SC1090
            source "$(restore_state_file "$REMARK")" || true
            REMARK="${BACKUPER_RESTORE_REMARK:-$REMARK}"
        fi
        [ -n "${BACKUPER_RESTORE_PLATFORM:-}" ] && PLATFORM="$BACKUPER_RESTORE_PLATFORM"
        if [ -z "$PLATFORM" ]; then
            error "Restore source is required (BACKUPER_RESTORE_PLATFORM = telegram, discord, gmail or local)."
        fi
        return 0
    fi
    mapfile -t states < <(find /root -maxdepth 1 -type f -name '.backuper_*.conf' 2>/dev/null | sort)

    if [[ ${#states[@]} -gt 0 ]]; then
        print "Saved configurations on this server:"
        for f in "${states[@]}"; do
            remark=$(sed -n 's/^REMARK=//p' "$f" | head -n 1 | tr -d "'")
            platform=$(sed -n 's/^PLATFORM=//p' "$f" | head -n 1 | tr -d "'")
            print "$i) ${remark}  [${platform:-unknown}]"
            i=$((i + 1))
        done
        print "$i) Manual restore (enter the details yourself)"
        print "0) Back"
        print ""
        while true; do
            input "Choose an option: " choice
            if [[ "$choice" == "0" ]]; then
                return 1
            elif [[ "$choice" == "$i" ]]; then
                restore_manual_config || return 1
                return 0
            elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
                restore_load_state "${states[$((choice - 1))]}" || return 1
                restore_override_source
                return 0
            else
                wrong "Invalid option, Please select a valid option!"
            fi
        done
    fi

    print "No saved backup configuration was found on this server."
    print "You can still restore a backup by entering the details manually."
    print ""
    restore_manual_config || return 1
    return 0
}

###############################################################################
# Archive download - Telegram
###############################################################################

restore_parse_telegram_docs() {
    # Reads Telegram API JSON from stdin and prints "file_name<TAB>file_id"
    sed -e 's/"thumbnail":{[^{}]*}//g' \
        | grep -o '"document":{[^{}]*}' 2>/dev/null \
        | while IFS= read -r doc; do
            local name file_id
            name=$(printf '%s' "$doc" | sed -n 's/.*"file_name":"\([^"]*\)".*/\1/p')
            file_id=$(printf '%s' "$doc" | sed -n 's/.*"file_id":"\([^"]*\)".*/\1/p')
            if [[ -n "$name" && -n "$file_id" ]]; then
                printf '%s\t%s\n' "$name" "$file_id"
            fi
        done
}

restore_newest_group() {
    # Keeps only the files that belong to the newest backup set (same timestamp prefix)
    local names=() n prefix newest=""
    while IFS= read -r n; do
        [ -n "$n" ] && names+=("$n")
    done
    [ ${#names[@]} -eq 0 ] && return 0
    for n in "${names[@]}"; do
        prefix="${n%%_*}"
        if [ -z "$newest" ] || [[ "$prefix" > "$newest" ]]; then
            newest="$prefix"
        fi
    done
    for n in "${names[@]}"; do
        [ "${n%%_*}" = "$newest" ] && printf '%s\n' "$n"
    done
    return 0
}

restore_merge_split_zip() {
    # $1 = last part (*.zip), rest of the parts are discovered next to it.
    # Echoes the path of the merged archive, or nothing when the archive is not split.
    local zipfile="$1"
    local base="${zipfile%.zip}"
    local parts=() f out merged

    while IFS= read -r f; do
        [ -n "$f" ] && parts+=("$f")
    done < <(find "$(dirname "$zipfile")" -maxdepth 1 -type f -name "$(basename "$base").z[0-9][0-9]" | sort)

    [ ${#parts[@]} -eq 0 ] && return 0

    out="$(dirname "$zipfile")/merged.zip"
    rm -f "$out" 2>/dev/null || true

    if command -v python3 &> /dev/null; then
        if restore_python_merge "$out" "${parts[@]}" "$zipfile"; then
            printf '%s\n' "$out"
            return 0
        fi
        warn "The python based merge failed, trying zip -s 0 ..."
    fi

    if ( cd "$(dirname "$zipfile")" && zip -q -s 0 "$(basename "$zipfile")" --out "$out" ) && [ -s "$out" ]; then
        printf '%s\n' "$out"
        return 0
    fi
    return 1
}

restore_python_merge() {
    # $1 = output archive, $2..$n = parts in order (z01 .. zip)
    local out="$1"
    shift
    python3 - "$out" "$@" <<'PYEOF'
import os
import struct
import sys

out = sys.argv[1]
parts = sys.argv[2:]

if not parts:
    sys.exit(2)

bases = []
offset = 0
with open(out, "wb") as dst:
    for part in parts:
        bases.append(offset)
        with open(part, "rb") as src:
            while True:
                chunk = src.read(1024 * 1024)
                if not chunk:
                    break
                dst.write(chunk)
                offset += len(chunk)

with open(out, "r+b") as f:
    size = os.path.getsize(out)
    f.seek(max(0, size - 70000))
    tail = f.read()
    idx = tail.rfind(b"PK\x05\x06")
    if idx < 0:
        sys.exit(3)
    eocd = size - len(tail) + idx
    f.seek(eocd)
    rec = f.read(22)
    disk_cd = struct.unpack("<H", rec[6:8])[0]
    count = struct.unpack("<H", rec[10:12])[0]
    cd_size = struct.unpack("<I", rec[12:16])[0]
    cd_off = struct.unpack("<I", rec[16:20])[0]

    # Zip64 or broken record: let the caller fall back to zip -s 0
    if count == 0xFFFF or cd_off == 0xFFFFFFFF or disk_cd >= len(bases):
        sys.exit(4)

    cd_start = bases[disk_cd] + cd_off
    if cd_start + cd_size > size:
        sys.exit(5)

    pos = cd_start
    for _ in range(count):
        f.seek(pos)
        head = f.read(46)
        if len(head) < 46 or head[:4] != b"PK\x01\x02":
            sys.exit(6)
        disk = struct.unpack("<H", head[34:36])[0]
        rel = struct.unpack("<I", head[42:46])[0]
        name_len, extra_len, comment_len = struct.unpack("<HHH", head[28:34])
        global_off = (bases[disk] if disk < len(bases) else 0) + rel
        f.seek(pos + 42)
        f.write(struct.pack("<I", global_off))
        f.seek(pos + 34)
        f.write(b"\x00\x00")
        pos += 46 + name_len + extra_len + comment_len

    f.seek(eocd + 4)
    f.write(b"\x00\x00\x00\x00")
    f.seek(eocd + 16)
    f.write(struct.pack("<I", cd_start))
sys.exit(0)
PYEOF
}

restore_filter_backup_files() {
    # Filters "name<TAB>id" lines and keeps only files of the newest backup set
    local remark="$1" names=() ids=() name id
    local -a keep_names=() keep_ids=()

    while IFS=$'\t' read -r name id; do
        [[ -z "$name" || -z "$id" ]] && continue
        [[ "$name" =~ _backuper\.(zip|z[0-9][0-9])$ ]] || continue
        if [[ -n "$remark" && "$name" != *"_${remark}${TAG}"* ]]; then
            continue
        fi
        keep_names+=("$name")
        keep_ids+=("$id")
    done

    [[ ${#keep_names[@]} -eq 0 ]] && return 1

    # Newest group = same timestamp prefix (e.g. 1031-1530)
    local newest_prefix="${keep_names[0]%%_*}"
    for name in "${keep_names[@]}"; do
        [[ "$name" > "${newest_prefix}_" ]] && newest_prefix="${name%%_*}"
    done

    for ((i = 0; i < ${#keep_names[@]}; i++)); do
        [[ "${keep_names[$i]}" == "${newest_prefix}_"* ]] || continue
        printf '%s\t%s\n' "${keep_names[$i]}" "${keep_ids[$i]}"
    done
    return 0
}

restore_telegram_manual_file() {
    # Ask the user for a message link or a file_id + file name
    local answer="" from="" msg="" name="" file_id="" resp=""

    if noni; then
        answer="${BACKUPER_RESTORE_MSG:-}"
        if [ -z "$answer" ]; then
            error "Telegram message link or file id is required (BACKUPER_RESTORE_MSG)."
        fi
        if [[ "$answer" =~ ^https?://t\.me/(.+)/([0-9]+)$ ]]; then
            local chat_part="${BASH_REMATCH[1]}"
            msg="${BASH_REMATCH[2]}"
            if [[ "$chat_part" == c/* ]]; then
                from="-100${chat_part#c/}"
            else
                from="@${chat_part}"
            fi
            resp=$(curl -s --max-time 60 "https://api.telegram.org/bot${TG_TOKEN}/forwardMessage" \
                -d chat_id="$TG_CHAT" -d from_chat_id="$from" -d message_id="$msg" 2>/dev/null) || resp=""
            printf '%s' "$resp" | restore_parse_telegram_docs | restore_filter_backup_files "$REMARK" > "$RESTORE_DIR/docs.txt" 2>/dev/null || true
        else
            name=$(basename "${answer##*:}")
            printf '%s\t%s\n' "$name" "$answer" >> "$RESTORE_DIR/docs.txt"
        fi
        if [ ! -s "$RESTORE_DIR/docs.txt" ]; then
            error "Could not resolve the Telegram message. Check the link/id and the bot permissions."
        fi
        return 0
    fi

    print ""
    print "Paste one of the following:"
    print "  • A Telegram message link (https://t.me/c/<chat>/<message>)"
    print "  • A document file_id"
    print "  • Press Enter to scan the bot updates again"
    print ""
    while true; do
        input "Message link / file_id: " answer

        if [[ -z "$answer" ]]; then
            log "Scanning bot updates..."
            if resp=$(curl -s --max-time 60 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?limit=100"); then
                if printf '%s' "$resp" | restore_parse_telegram_docs | restore_filter_backup_files "$REMARK" > "$RESTORE_DIR/docs.txt" 2>/dev/null && [[ -s "$RESTORE_DIR/docs.txt" ]]; then
                    success "Backup found in the bot updates."
                    return 0
                fi
            fi
            wrong "Nothing found. Forward the backup message(s) to the bot first, or paste a link/file_id."
            continue
        fi

        if [[ "$answer" =~ ^https?://t\.me/(.+)/([0-9]+)$ ]]; then
            local chat_part="${BASH_REMATCH[1]}"
            msg="${BASH_REMATCH[2]}"
            if [[ "$chat_part" == c/* ]]; then
                from="-100${chat_part#c/}"
            else
                from="@${chat_part}"
            fi
            log "Forwarding the message to the backup chat to get the file id..."
            resp=$(curl -s --max-time 60 "https://api.telegram.org/bot${TG_TOKEN}/forwardMessage" \
                -d chat_id="$TG_CHAT" -d from_chat_id="$from" -d message_id="$msg" 2>/dev/null) || resp=""
            printf '%s' "$resp" | restore_parse_telegram_docs | restore_filter_backup_files "$REMARK" > "$RESTORE_DIR/docs.txt" 2>/dev/null || true
            if [[ -s "$RESTORE_DIR/docs.txt" ]]; then
                success "Backup message resolved."
                return 0
            fi
            wrong "Could not read the file from that message. Make sure the bot is a member/admin of that chat."
            continue
        fi

        # Treat the answer as a file_id - we also need the original name
        file_id="$answer"
        input "Enter the original file name of this part (e.g. 1031-1530_master_backuper.zip): " name
        if [[ ! "$name" =~ _backuper\.(zip|z[0-9][0-9])$ ]]; then
            wrong "Invalid file name. It must end with ${TAG}zip or ${TAG}z01"
            continue
        fi
        printf '%s\t%s\n' "$name" "$file_id" >> "$RESTORE_DIR/docs.txt"
        success "Part added: $name"
        input "Add another part? (yes/no): " answer
        [[ "$answer" == "yes" ]] || return 0
    done
}

restore_fetch_telegram() {
    local token="${TG_TOKEN:-${BACKUPER_TG_TOKEN:-}}" chat="${TG_CHAT:-${BACKUPER_TG_CHAT:-}}" topic="${TG_TOPIC:-${BACKUPER_TG_TOPIC:-}}"

    if noni && [[ -z "$token" || -z "$chat" ]]; then
        error "Telegram token and chat ID are required (BACKUPER_TG_TOKEN / BACKUPER_TG_CHAT)."
    fi

    if [[ -z "$token" || -z "$chat" ]]; then
        print ""
        print "[TELEGRAM]"
        print ""
        while true; do
            input "Enter the bot token: " token
            if [[ ! "$token" =~ ^[0-9]+:[a-zA-Z0-9_-]{35}$ ]]; then
                wrong "Invalid bot token format!"
            else
                break
            fi
        done
        while true; do
            input "Enter the chat ID that receives the backups: " chat
            if [[ ! "$chat" =~ ^-?[0-9]+$ ]]; then
                wrong "Invalid chat ID format!"
            else
                break
            fi
        done
        input "Enter the topic ID (Press Enter to skip): " topic
        [[ "$topic" =~ ^[0-9]+$ ]] || topic=""
    fi
    TG_TOKEN="$token"
    TG_CHAT="$chat"
    TG_TOPIC="$topic"

    : > "$RESTORE_DIR/docs.txt"

    local upload_log
    upload_log=$(restore_upload_log "$REMARK")
    if [[ -f "$upload_log" ]]; then
        log "Looking for the last upload record on this server..."
        restore_parse_telegram_docs < "$upload_log" | restore_filter_backup_files "$REMARK" > "$RESTORE_DIR/docs.txt" 2>/dev/null || true
        [[ -s "$RESTORE_DIR/docs.txt" ]] && success "Found the last uploaded backup."
    fi

    if [[ ! -s "$RESTORE_DIR/docs.txt" ]]; then
        log "Asking Telegram for the latest messages..."
        local resp
        if resp=$(curl -s --max-time 60 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?limit=100"); then
            printf '%s' "$resp" | restore_parse_telegram_docs | restore_filter_backup_files "$REMARK" > "$RESTORE_DIR/docs.txt" 2>/dev/null || true
        else
            warn "Could not contact the Telegram API."
        fi
    fi

    if [[ ! -s "$RESTORE_DIR/docs.txt" ]]; then
        warn "No backup file was found automatically."
        restore_telegram_manual_file || return 1
    fi

    # Download every part
    local name file_id finfo fpath dest
    while IFS=$'\t' read -r name file_id; do
        [[ -z "$name" ]] && continue
        log "Preparing $name ..."
        if ! finfo=$(curl -s --max-time 120 "https://api.telegram.org/bot${TG_TOKEN}/getFile?file_id=${file_id}"); then
            wrong "Failed to call the Telegram API for: $name"
            return 1
        fi
        fpath=$(printf '%s' "$finfo" | sed -n 's/.*"file_path":"\([^"]*\)".*/\1/p')
        if [[ -z "$fpath" ]]; then
            wrong "Telegram did not return a download path for: $name"
            print "Response: $finfo"
            print "Hint: bots can only download files up to 20 MB. Download this part with a"
            print "Telegram client and restore it with the \"Local file\" option instead."
            return 1
        fi
        dest="$RESTORE_DIR/$name"
        if ! curl -s --fail --retry 3 --retry-delay 3 --max-time 1800 -o "$dest" \
            "https://api.telegram.org/file/bot${TG_TOKEN}/${fpath}"; then
            wrong "Failed to download: $name"
            print "Hint: bots can only download files up to 20 MB. Download this part with a"
            print "Telegram client and restore it with the \"Local file\" option instead."
            return 1
        fi
        ARCHIVE_FILES+=("$dest")
        success "Downloaded: $name ($(du -h "$dest" 2>/dev/null | cut -f1))"
    done < "$RESTORE_DIR/docs.txt"

    [[ ${#ARCHIVE_FILES[@]} -gt 0 ]] || { wrong "No backup file was downloaded."; return 1; }
    return 0
}

###############################################################################
# Archive download - Discord
###############################################################################

restore_parse_discord_attachments() {
    # Reads Discord API JSON from stdin and prints "file_name<TAB>url"
    grep -o '"filename":"[^"]*"\|"url":"https://cdn\.discordapp\.com[^"]*"' 2>/dev/null \
        | awk -F'"' '
            /"filename"/ { name = $4; next }
            /"url"/ {
                if (name ~ /_backuper\.(zip|z[0-9][0-9])$/) print name "\t" $4
                name = ""
            }'
}

restore_discord_credentials() {
    local webhook="${DISCORD_WEBHOOK:-${BACKUPER_DISCORD_WEBHOOK:-}}"

    if noni && [[ -z "$webhook" ]]; then
        error "Discord webhook URL is required (BACKUPER_DISCORD_WEBHOOK)."
    fi

    if [[ -z "$webhook" ]]; then
        print ""
        print "[DISCORD]"
        print ""
        while true; do
            input "Enter the Discord Webhook URL: " webhook
            if [[ ! "$webhook" =~ ^https://(discord|discordapp)\.com/api/webhooks/ ]]; then
                wrong "Invalid Discord Webhook URL format!"
            else
                break
            fi
        done
        DISCORD_WEBHOOK="$webhook"
    fi

    local rest="${webhook#https://discord.com/api/webhooks/}"
    rest="${rest#https://discordapp.com/api/webhooks/}"
    DISCORD_WEBHOOK_ID="${rest%%/*}"
    DISCORD_WEBHOOK_TOKEN="${rest#*/}"
    DISCORD_WEBHOOK_TOKEN="${DISCORD_WEBHOOK_TOKEN%%\?*}"
    DISCORD_WEBHOOK_TOKEN="${DISCORD_WEBHOOK_TOKEN%%/*}"
}

restore_fetch_discord() {
    restore_discord_credentials
    : > "$RESTORE_DIR/attachments.txt"

    local upload_log
    upload_log=$(restore_upload_log "$REMARK")
    if [[ -f "$upload_log" ]]; then
        log "Looking for the last upload record on this server..."
        restore_parse_discord_attachments < "$upload_log" | restore_filter_backup_files "$REMARK" > "$RESTORE_DIR/attachments.txt" 2>/dev/null || true
        [[ -s "$RESTORE_DIR/attachments.txt" ]] && success "Found the last uploaded backup."
    fi

    if [[ ! -s "$RESTORE_DIR/attachments.txt" ]]; then
        local answer="" msg_id="" resp=""
        print ""
        print "Paste the Discord message link of the backup"
        print "(right click the message → Copy Message Link),"
        print "or just the message ID."
        print ""
        while true; do
            input "Message link / ID: " answer
            if [[ "$answer" =~ /([0-9]+)$ ]]; then
                msg_id="${BASH_REMATCH[1]}"
            elif [[ "$answer" =~ ^[0-9]+$ ]]; then
                msg_id="$answer"
            else
                wrong "Invalid message link or ID."
                continue
            fi

            log "Fetching the message from Discord..."
            if resp=$(curl -s --max-time 120 "https://discord.com/api/webhooks/${DISCORD_WEBHOOK_ID}/${DISCORD_WEBHOOK_TOKEN}/messages/${msg_id}"); then
                if printf '%s' "$resp" | restore_parse_discord_attachments | restore_filter_backup_files "$REMARK" > "$RESTORE_DIR/attachments.txt" 2>/dev/null && [[ -s "$RESTORE_DIR/attachments.txt" ]]; then
                    success "Backup message resolved."
                    break
                fi
            fi
            wrong "Could not find backup attachments in that message."
            input "Try another message ID? (yes/no): " answer
            [[ "$answer" == "yes" ]] || return 1
        done
    fi

    local name url dest
    while IFS=$'\t' read -r name url; do
        [[ -z "$name" || -z "$url" ]] && continue
        dest="$RESTORE_DIR/$name"
        log "Downloading $name ..."
        if ! curl -s --fail --retry 3 --retry-delay 3 --max-time 1800 -o "$dest" "$url"; then
            wrong "Failed to download: $name"
            return 1
        fi
        ARCHIVE_FILES+=("$dest")
        success "Downloaded: $name ($(du -h "$dest" 2>/dev/null | cut -f1))"
    done < "$RESTORE_DIR/attachments.txt"

    [[ ${#ARCHIVE_FILES[@]} -gt 0 ]] || { wrong "No backup file was downloaded."; return 1; }
    return 0
}

###############################################################################
# Archive download - Gmail
###############################################################################

restore_gmail_extract_attachments() {
    # $1 = .eml file, $2 = output directory (base64 bodies are written next to it)
    awk -v out="$2" '
        BEGIN { inbody = 0; fname = "" }
        /^--/ { inbody = 0; fname = ""; next }
        {
            if (!inbody) {
                if (tolower($0) ~ /filename="/) {
                    if (match($0, /filename="[^"]*_backuper[^"]*"/)) {
                        s = substr($0, RSTART + 10, RLENGTH - 11)
                        gsub(/[ \t\r]/, "", s)
                        fname = out "/" s ".b64"
                    }
                }
                if ($0 ~ /^[[:space:]]*$/) { if (fname != "") inbody = 1 }
            } else {
                print $0 >> fname
            }
        }' "$1"
}

restore_fetch_gmail() {
    local address="${GMAIL_ADDRESS:-${BACKUPER_GMAIL_ADDRESS:-}}" password="${GMAIL_PASSWORD:-${BACKUPER_GMAIL_PASSWORD:-}}"

    if noni && [[ -z "$address" || -z "$password" ]]; then
        error "Gmail address and app password are required (BACKUPER_GMAIL_ADDRESS / BACKUPER_GMAIL_PASSWORD)."
    fi

    if [[ -z "$address" || -z "$password" ]]; then
        print ""
        print "[GMAIL]"
        print ""
        while true; do
            input "Enter your Gmail address: " address
            if [[ ! "$address" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                wrong "Invalid email format!"
            else
                break
            fi
        done
        while true; do
            input "Enter your Gmail app password: " password
            if [[ -z "$password" ]]; then
                wrong "Password cannot be empty!"
            else
                break
            fi
        done
    fi
    password="${password// /}"
    GMAIL_ADDRESS="$address"
    GMAIL_PASSWORD="$password"

    log "Searching Gmail for Backuper emails..."
    local search=""
    if ! search=$(curl -s --max-time 180 --url "imaps://imap.gmail.com:993/INBOX" \
        --user "${address}:${password}" -X "UID SEARCH SUBJECT \"${PROJECT_NAME}\"" 2>&1); then
        wrong "Failed to connect to Gmail (IMAP). Check the address and app password."
        return 1
    fi

    local uids=()
    read -r -a uids <<< "$(printf '%s\n' "$search" | sed -n 's/^\* SEARCH //p' | tr -d '\r')"
    if [[ ${#uids[@]} -eq 0 ]]; then
        wrong "No backup email was found in the Inbox (subject: Backuper)."
        return 1
    fi
    log "Found ${#uids[@]} backup email(s). Checking the newest ones..."

    local i uid eml f found=0
    for ((i = ${#uids[@]} - 1; i >= 0; i--)); do
        uid="${uids[$i]}"
        eml="$RESTORE_DIR/mail_${uid}.eml"
        if ! curl -s --max-time 1800 --url "imaps://imap.gmail.com:993/INBOX" \
            --user "${address}:${password}" -X "UID FETCH ${uid} BODY[]" -o "$eml"; then
            warn "Failed to fetch email UID $uid"
            continue
        fi

        rm -f "$RESTORE_DIR"/*.b64 2>/dev/null || true
        restore_gmail_extract_attachments "$eml" "$RESTORE_DIR"

        local any=0
        for f in "$RESTORE_DIR"/*.b64; do
            [[ -e "$f" ]] || continue
            if base64 -di "$f" > "${f%.b64}" 2>/dev/null; then
                rm -f "$f"
                any=1
            fi
        done

        if [[ $any -eq 1 ]]; then
            ARCHIVE_FILES=()
            local candidate candidate_name
            while IFS= read -r candidate; do
                candidate_name=$(basename "$candidate")
                if [[ -n "$REMARK" && "$candidate_name" != *"_${REMARK}${TAG}"* ]]; then
                    continue
                fi
                ARCHIVE_FILES+=("$candidate")
            done < <(find "$RESTORE_DIR" -maxdepth 1 -type f \( -name "*${TAG}zip" -o -name "*${TAG}z[0-9][0-9]" \) | sort)
            if [[ ${#ARCHIVE_FILES[@]} -gt 0 ]]; then
                found=1
                success "Downloaded ${#ARCHIVE_FILES[@]} part(s) from the email."
                rm -f "$eml"
                break
            fi
        fi
        rm -f "$eml"
        [[ $(( ${#uids[@]} - 1 - i )) -ge 4 ]] && break
    done

    [[ $found -eq 1 ]] || { wrong "No backup attachment was found in the emails."; return 1; }
    return 0
}

###############################################################################
# Archive download - local file
###############################################################################

restore_fetch_local() {
    local path="" choice=""

    if noni; then
        path="${BACKUPER_RESTORE_PATH:-}"
        if [ -z "$path" ]; then
            error "Archive path is required (BACKUPER_RESTORE_PATH)."
        fi
        if [ ! -e "$path" ]; then
            error "Path does not exist: $path"
        fi
        if [ -d "$path" ]; then
            local afiles=()
            while IFS= read -r f; do afiles+=("$f"); done < <(find "$path" -maxdepth 1 -type f \( -name "*${TAG}zip" -o -name "*${TAG}z[0-9][0-9]" \) | sort)
            if [ ${#afiles[@]} -eq 0 ]; then
                error "No Backuper archive was found in: $path"
            fi
            ARCHIVE_FILES=("${afiles[@]}")
        elif [[ "$path" == *.z[0-9][0-9] ]]; then
            local lbase
            lbase="$(dirname "$path")/$(basename "${path%.z*}")"
            while IFS= read -r f; do ARCHIVE_FILES+=("$f"); done < <(find "$(dirname "$path")" -maxdepth 1 -type f \( -name "$(basename "$lbase").z[0-9][0-9]" -o -name "$(basename "$lbase").zip" \) | sort)
        else
            ARCHIVE_FILES=("$path")
        fi

        local lf
        for lf in "${ARCHIVE_FILES[@]}"; do
            cp -f "$lf" "$RESTORE_DIR/" || error "Failed to copy: $lf"
        done
        local lcopies=()
        while IFS= read -r lf; do lcopies+=("$lf"); done < <(find "$RESTORE_DIR" -maxdepth 1 -type f | sort)
        ARCHIVE_FILES=("${lcopies[@]}")
        success "Using archive part(s) from: $path"
        return 0
    fi

    print ""
    print "[LOCAL FILE]"
    print "Enter the full path of the backup archive on this server."
    print "You can also enter a directory that contains the archive parts."
    print ""

    while true; do
        input "Path: " path
        path="${path%\"}"
        path="${path#\"}"
        path="${path/#\~/$HOME}"
        [[ -z "$path" ]] && { wrong "Path cannot be empty."; continue; }

        if [[ -d "$path" ]]; then
            local files=()
            while IFS= read -r f; do files+=("$f"); done < <(find "$path" -maxdepth 1 -type f \( -name "*${TAG}zip" -o -name "*${TAG}z[0-9][0-9]" \) | sort)
            if [[ ${#files[@]} -eq 0 ]]; then
                wrong "No Backuper archive was found in: $path"
                continue
            fi
            ARCHIVE_FILES=()
            while IFS= read -r f; do
                [ -n "$f" ] && ARCHIVE_FILES+=("$path/$f")
            done < <(printf '%s\n' "${files[@]}" | xargs -n 1 basename | sort | restore_newest_group)
            [ ${#ARCHIVE_FILES[@]} -eq 0 ] && ARCHIVE_FILES=("${files[@]}")
            break
        elif [[ -f "$path" ]]; then
            if [[ "$path" == *.z[0-9][0-9] ]]; then
                local base
                base="$(dirname "$path")/$(basename "${path%.z*}")"
                while IFS= read -r f; do ARCHIVE_FILES+=("$f"); done < <(find "$(dirname "$path")" -maxdepth 1 -type f \( -name "$(basename "$base").z[0-9][0-9]" -o -name "$(basename "$base").zip" \) | sort)
            else
                ARCHIVE_FILES=("$path")
            fi
            break
        else
            wrong "Path does not exist: $path"
            input "Try again? (yes/no): " choice
            [[ "$choice" == "yes" ]] || return 1
        fi
    done

    local f
    for f in "${ARCHIVE_FILES[@]}"; do
        cp -f "$f" "$RESTORE_DIR/" || { wrong "Failed to copy: $f"; return 1; }
    done

    local copies=()
    while IFS= read -r f; do copies+=("$f"); done < <(find "$RESTORE_DIR" -maxdepth 1 -type f ! -name 'docs.txt' ! -name 'attachments.txt' | sort)
    ARCHIVE_FILES=("${copies[@]}")
    success "Using archive part(s) from: $path"
    return 0
}

###############################################################################
# Archive handling
###############################################################################

restore_fetch_archive() {
    RESTORE_DIR="$RESTORE_TMP_DIR"
    rm -rf "$RESTORE_DIR" 2>/dev/null || true
    mkdir -p "$RESTORE_DIR"
    ARCHIVE_FILES=()
    UNZIP_ARGS=()

    case "$PLATFORM" in
        telegram) restore_fetch_telegram ;;
        discord)  restore_fetch_discord ;;
        gmail)    restore_fetch_gmail ;;
        local|"") restore_fetch_local ;;
        *) wrong "Unknown backup source: $PLATFORM"; return 1 ;;
    esac
}

restore_prepare_zip() {
    [[ ${#ARCHIVE_FILES[@]} -gt 0 ]] || { wrong "No backup archive was found."; return 1; }

    local f zipfile="" parts=()
    for f in "${ARCHIVE_FILES[@]}"; do
        [[ "$f" == *.zip ]] && zipfile="$f"
    done

    if [[ -z "$zipfile" ]]; then
        wrong "The main part of the archive (*${TAG}zip) was not found."
        print "For split backups you need every part: ${TAG}z01, ${TAG}z02, ... and ${TAG}zip"
        return 1
    fi

    log "Merging the split parts into a single archive (if any)..."
    local merged=""
    if ! merged=$(restore_merge_split_zip "$zipfile"); then
        wrong "Failed to merge the split archive parts."
        print "Make sure all parts were downloaded: ${TAG}z01, ${TAG}z02, ... and ${TAG}zip"
        return 1
    fi

    if [[ -n "$merged" ]]; then
        RESTORE_ZIP="$merged"
        success "Split parts merged successfully."
    else
        RESTORE_ZIP="$zipfile"
    fi

    # Check the archive and its password
    local testout=""
    if ! testout=$(unzip -t "$RESTORE_ZIP" 2>&1); then
        if [[ "$testout" == *"ncorrect password"* || "$testout" == *"password"* ]]; then
            print ""
            print "This archive is password protected."
            local tries=0
            ZIP_PASSWORD="${BACKUPER_ZIP_PASSWORD:-$ZIP_PASSWORD}"
            if noni && [ -z "$ZIP_PASSWORD" ]; then
                error "This archive is password protected. Provide the password (BACKUPER_ZIP_PASSWORD)."
            fi
            if [[ -n "$ZIP_PASSWORD" ]]; then
                if unzip -t -P "$ZIP_PASSWORD" "$RESTORE_ZIP" > /dev/null 2>&1; then
                    UNZIP_ARGS=(-P "$ZIP_PASSWORD")
                    success "Saved password accepted."
                    return 0
                fi
            fi
            while (( tries < 3 )); do
                input "Archive password: " ZIP_PASSWORD
                if unzip -t -P "$ZIP_PASSWORD" "$RESTORE_ZIP" > /dev/null 2>&1; then
                    UNZIP_ARGS=(-P "$ZIP_PASSWORD")
                    success "Password accepted."
                    return 0
                fi
                wrong "Wrong password."
                tries=$((tries + 1))
            done
            return 1
        fi
        wrong "The archive is corrupted: ${testout:0:200}"
        return 1
    fi
    return 0
}

restore_apply() {
    local entries_file="$RESTORE_DIR/entries.lst"
    if ! unzip -Z1 "$RESTORE_ZIP" > "$entries_file"; then
        wrong "Failed to read the archive content."
        return 1
    fi

    local total
    total=$(wc -l < "$entries_file")

    if grep -qE '(^|/)\.\.(/|$)' "$entries_file"; then
        wrong "The archive contains unsafe paths and was rejected."
        return 1
    fi

    print ""
    print "Archive content ($total entries):"
    awk -F/ '{ if (NF > 1) print "/" $1 "/" $2; else print "/" $1 }' "$entries_file" \
        | sed 's|/*$||' | sort -u | head -n 25 | sed 's/^/  - /'
    print ""

    local answer=""
    if [ "${BACKUPER_RESTORE_YES:-}" = "1" ] || [ "${BACKUPER_RESTORE_YES:-}" = "yes" ]; then
        log "Restore confirmed (non-interactive mode)."
    else
        input "Type 'yes' to continue with the restore: " answer
        if [[ "$answer" != "yes" ]]; then
            warn "Restore cancelled."
            return 1
        fi
    fi

    # Safety copy of the files that will be overwritten
    local existing="$RESTORE_DIR/existing.lst"
    local entry abs
    while IFS= read -r entry; do
        entry="${entry%/}"
        [[ -z "$entry" ]] && continue
        abs="/$entry"
        [[ -e "$abs" ]] && printf '%s\n' "$abs"
    done < "$entries_file" > "$existing"

    if [[ -s "$existing" ]]; then
        local snapshot
        snapshot="/root/prerestore_$(TZ='Asia/Tehran' date +%y%m%d-%H%M)_${REMARK}.zip"
        log "Creating a safety copy of the current files: $snapshot"
        if zip -q -r "$snapshot" -@ < "$existing"; then
            RESTORE_SNAPSHOT="$snapshot"
            success "Safety copy created: $snapshot"
        else
            warn "Could not create a safety copy."
            if [ "${BACKUPER_RESTORE_YES:-}" = "1" ] || [ "${BACKUPER_RESTORE_YES:-}" = "yes" ]; then
                warn "Continuing without a safety copy."
            else
                input "Continue anyway? (yes/no): " answer
                [[ "$answer" == "yes" ]] || return 1
            fi
        fi
    fi

    log "Extracting the archive to / ..."
    if ! unzip -o -q "${UNZIP_ARGS[@]}" "$RESTORE_ZIP" -d /; then
        wrong "Failed to extract the archive."
        return 1
    fi
    success "Files restored successfully."
    return 0
}

###############################################################################
# Database restore
###############################################################################

restore_db_dumps() {
    find /root -maxdepth 1 -type f -name "*${DATABASE_SUFFIX}" 2>/dev/null | sort
}

restore_parse_database_url() {
    local url="$1"
    DB_TYPE=""
    DB_USER=""
    DB_PASSWORD=""
    DB_HOST=""
    DB_PORT=""
    DB_NAME=""

    [[ -z "$url" ]] && return 1

    if [[ "$url" =~ ^(postgresql|postgres|timescaledb)(\+[a-z0-9]+)?://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+)$ ]]; then
        DB_TYPE="postgresql"
        DB_USER="${BASH_REMATCH[3]}"
        DB_PASSWORD="${BASH_REMATCH[4]}"
        DB_HOST="${BASH_REMATCH[5]}"
        DB_PORT="${BASH_REMATCH[6]}"
        DB_NAME="${BASH_REMATCH[7]}"
    elif [[ "$url" =~ ^(postgresql|postgres|timescaledb)(\+[a-z0-9]+)?://([^:]+):([^@]+)@([^/]+)/(.+)$ ]]; then
        DB_TYPE="postgresql"
        DB_USER="${BASH_REMATCH[3]}"
        DB_PASSWORD="${BASH_REMATCH[4]}"
        DB_HOST="${BASH_REMATCH[5]}"
        DB_PORT="5432"
        DB_NAME="${BASH_REMATCH[6]}"
    elif [[ "$url" =~ ^(mysql|mariadb)(\+[a-z0-9]+)?://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+)$ ]]; then
        DB_TYPE="${BASH_REMATCH[1]}"
        DB_USER="${BASH_REMATCH[3]}"
        DB_PASSWORD="${BASH_REMATCH[4]}"
        DB_HOST="${BASH_REMATCH[5]}"
        DB_PORT="${BASH_REMATCH[6]}"
        DB_NAME="${BASH_REMATCH[7]}"
    elif [[ "$url" =~ ^(mysql|mariadb)(\+[a-z0-9]+)?://([^:]+):([^@]+)@([^/]+)/(.+)$ ]]; then
        DB_TYPE="${BASH_REMATCH[1]}"
        DB_USER="${BASH_REMATCH[3]}"
        DB_PASSWORD="${BASH_REMATCH[4]}"
        DB_HOST="${BASH_REMATCH[5]}"
        DB_PORT="3306"
        DB_NAME="${BASH_REMATCH[6]}"
    else
        return 1
    fi
    DB_NAME="${DB_NAME%%\?*}"
    return 0
}

restore_detect_db_defaults() {
    local env url
    for env in /opt/marzban/.env /opt/rebecca/.env /opt/remnawave/.env /opt/pasarguard/.env /opt/marzneshin/.env /etc/opt/marzneshin/.env; do
        [[ -f "$env" ]] || continue
        url=$(grep -v '^#' "$env" 2>/dev/null | grep -m 1 -E 'DATABASE_URL' | cut -d '=' -f 2- | tr -d '"' | tr -d "'" | tr -d ' ' || true)
        if [ -n "${url:-}" ] && restore_parse_database_url "$url"; then
            log "Detected database settings from: $env"
            return 0
        fi
    done
    return 1
}

restore_pg_run() {
    # $1 = SQL string, or "-" to import $2
    if [[ -n "${PG_CONTAINER:-}" ]]; then
        if [[ "$1" == "-" ]]; then
            docker exec -i -e PGPASSWORD="$DB_PASSWORD" "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" < "$2"
        else
            docker exec -i -e PGPASSWORD="$DB_PASSWORD" "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -c "$1"
        fi
    else
        if [[ "$1" == "-" ]]; then
            PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" < "$2"
        else
            PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "$1"
        fi
    fi
}

restore_mysql_run() {
    if [[ "$1" == "-" ]]; then
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" < "$2"
    else
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "$1"
    fi
}

restore_import_database_manual() {
    local dumps=("$@")
    local dump="${dumps[0]}"
    local type=""

    if head -c 20000 "$dump" 2>/dev/null | grep -qi "PostgreSQL database dump"; then
        type="postgresql"
    elif head -c 20000 "$dump" 2>/dev/null | grep -qi -E "MySQL dump|MariaDB dump"; then
        type="mysql"
    else
        warn "Unknown database dump format: $dump"
        return 0
    fi

    DB_TYPE="$type"
    DB_HOST="127.0.0.1"
    DB_PORT="$([[ "$type" == "postgresql" ]] && echo 5432 || echo 3306)"
    DB_USER=""
    DB_PASSWORD=""
    DB_NAME=""
    restore_detect_db_defaults || true

    print ""
    print "Database connection settings for the import:"
    local value
    input "Database host [$DB_HOST]: " value
    [[ -n "$value" ]] && DB_HOST="$value"
    input "Database port [$DB_PORT]: " value
    [[ -n "$value" ]] && DB_PORT="$value"
    input "Database user [$DB_USER]: " value
    [[ -n "$value" ]] && DB_USER="$value"
    input "Database password [${DB_PASSWORD:+hidden}]: " value
    [[ -n "$value" ]] && DB_PASSWORD="$value"
    input "Database name [$DB_NAME]: " value
    [[ -n "$value" ]] && DB_NAME="$value"

    if [[ -z "$DB_USER" || -z "$DB_NAME" ]]; then
        wrong "Database user and name are required."
        return 0
    fi

    PG_CONTAINER=""
    if [[ "$DB_TYPE" == "postgresql" ]] && command -v docker &> /dev/null; then
        PG_CONTAINER=$(docker ps --format '{{.Names}}' --filter "publish=${DB_PORT}" 2>/dev/null | head -n 1)
        if [[ -z "$PG_CONTAINER" ]]; then
            PG_CONTAINER=$(docker ps --format '{{.Names}}' --filter "ancestor=postgres" 2>/dev/null | head -n 1)
        fi
    fi

    local answer=""
    input "Delete the current data before importing? (yes/no): " answer
    if [[ "$answer" == "yes" ]]; then
        if [[ "$DB_TYPE" == "postgresql" ]]; then
            log "Recreating the public schema..."
            restore_pg_run "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;" || warn "Could not recreate the schema."
        else
            log "Dropping and recreating the database..."
            restore_mysql_run "DROP DATABASE IF EXISTS \`${DB_NAME}\`; CREATE DATABASE \`${DB_NAME}\`;" || warn "Could not recreate the database."
        fi
    fi

    local f
    for f in "${dumps[@]}"; do
        log "Importing $f ..."
        if [[ "$DB_TYPE" == "postgresql" ]]; then
            if restore_pg_run "-" "$f"; then success "Imported: $f"; else wrong "Import failed: $f"; fi
        else
            if restore_mysql_run "-" "$f"; then success "Imported: $f"; else wrong "Import failed: $f"; fi
        fi
    done
    return 0
}

restore_import_database() {
    local dumps=() answer=""
    mapfile -t dumps < <(restore_db_dumps)

    if [[ ${#dumps[@]} -eq 0 ]]; then
        log "No database dump was found in the backup. Skipping the database restore."
        return 0
    fi

    print ""
    print "Database dump(s) found:"
    local f
    for f in "${dumps[@]}"; do print "  - $f"; done

    local db_choice="${BACKUPER_RESTORE_DB:-}"

    if [[ -n "$RESTORE_DB_COMMAND" ]]; then
        print ""
        print "Saved database restore command:"
        print "${COLORS[orange]}  $RESTORE_DB_COMMAND${COLORS[reset]}"
        print ""
        if [[ -n "$db_choice" ]]; then
            answer="$db_choice"
        else
            input "Restore the database now? (yes/no): " answer
        fi
        if [[ "$answer" == "yes" ]]; then
            if eval "$RESTORE_DB_COMMAND"; then
                success "Database restored successfully."
            else
                wrong "The database restore command failed."
                print "You can run it manually later: $RESTORE_DB_COMMAND"
            fi
        else
            warn "Database restore skipped. You can run this command later:"
            print "  $RESTORE_DB_COMMAND"
        fi
        return 0
    fi

    if [[ -n "$db_choice" ]]; then
        answer="$db_choice"
    elif noni; then
        answer="no"
        warn "No saved database restore command. Set BACKUPER_RESTORE_DB=yes to import it manually."
    else
        input "Restore the database manually now? (yes/no): " answer
    fi
    if [[ "$answer" == "yes" ]]; then
        restore_import_database_manual "${dumps[@]}"
    else
        warn "Database restore skipped."
    fi
    return 0
}

###############################################################################
# Restore entry point
###############################################################################

restore_restart_services() {
    local answer=""
    if ! command -v docker &> /dev/null; then
        return 0
    fi
    if [[ -z "$(docker ps -q 2>/dev/null)" ]]; then
        return 0
    fi
    if [[ -n "${BACKUPER_RESTORE_RESTART:-}" ]]; then
        answer="$BACKUPER_RESTORE_RESTART"
    elif noni; then
        answer="no"
    else
        input "Restart all running docker containers now? (yes/no): " answer
    fi
    if [[ "$answer" == "yes" ]]; then
        local ids=()
        mapfile -t ids < <(docker ps -q 2>/dev/null)
        if docker restart "${ids[@]}" > /dev/null 2>&1; then
            success "Docker containers restarted."
        else
            warn "Some containers could not be restarted. Check them manually."
        fi
    else
        print "Remember to restart your panel service manually."
    fi
}

restore_backup() {
    restore_reset

    clear
    print "======== Restore Backup [$VERSION] ========"
    print ""
    print "This will download a backup created by Backuper from the same platform"
    print "you send your backups to, and restore it on this server."
    print ""
    print "${COLORS[orange]}Note: files on this server will be overwritten.${COLORS[reset]}"
    print "A safety copy of the current files is created in /root before restoring."
    print ""

    if ! restore_choose_source; then
        return 0
    fi

    if ! restore_fetch_archive; then
        warn "Download failed. Temporary files are kept in: $RESTORE_TMP_DIR"
        confirm
        return 0
    fi

    if ! restore_prepare_zip; then
        warn "Could not prepare the archive. Temporary files are kept in: $RESTORE_TMP_DIR"
        confirm
        return 0
    fi

    if ! restore_apply; then
        rm -rf "$RESTORE_TMP_DIR" 2>/dev/null || true
        confirm
        return 0
    fi

    restore_import_database || true

    rm -rf "$RESTORE_TMP_DIR" 2>/dev/null || true

    print ""
    success "🎉 Restore completed successfully!"
    if [[ -n "${RESTORE_SNAPSHOT:-}" ]]; then
        print "Previous files were saved in: ${RESTORE_SNAPSHOT}"
    fi
    print ""
    print "Next steps:"
    print "  1) Restart your panel service so it loads the restored data."
    print "  2) Check the panel and its users."
    print "  3) If the panel runs in Docker, verify the file owners inside its data directory."
    print ""
    restore_restart_services
    confirm
}

generate_script() {
    clear
    local BACKUP_PATH="/root/_${REMARK}${SCRIPT_SUFFIX}"
    log "Generating backup script: $BACKUP_PATH"
    DB_CLEANUP=""
    if [[ -n "$DB_PATH" ]]; then
        DB_CLEANUP="rm -rf "$DB_PATH" 2>/dev/null || true"
    fi
    
    # Create the backup script
    cat <<EOL > "$BACKUP_PATH"
#!/bin/bash
set -e 

# Variables
echo "===== \$(TZ='Asia/Tehran' date '+%Y-%m-%d %H:%M') ====="
ip=\$(hostname -I | awk '{print \$1}')
timestamp=\$(TZ='Asia/Tehran' date +%m%d-%H%M)
CAPTION="${CAPTION}"
backup_name="/root/\${timestamp}_${REMARK}${BACKUP_SUFFIX}"
base_name="/root/\${timestamp}_${REMARK}${TAG}"
upload_log="/root/.backuper_${REMARK}_upload.log"
: > "\$upload_log" 2>/dev/null || true

# Clean up old backup files (only specific backup files)
rm -rf *"${REMARK}${TAG}"* 2>/dev/null || true
$DB_CLEANUP

# Backup database
$BACKUP_DB_COMMAND

# Compress files
if ! $COMPRESS "\$backup_name" ${BACKUP_DIRECTORIES[@]}; then
    message="Failed to compress ${REMARK} files. Please check the server."
    echo "\$message"
    exit 1
fi

# Send backup files
if ls \${base_name}* > /dev/null 2>&1; then
    for FILE in \${base_name}*; do
        echo "Sending file: \$FILE"
        if response=\$($PLATFORM_COMMAND); then
            if [[ "\$response" == *"ok":false* ]]; then
                message="Failed to send \${REMARK} backup part: \$FILE. Please check the server."
                echo "\$message"
                echo "\$response"
                exit 1
            fi
            echo "Backup part sent successfully: \$FILE"
            printf '%s\n' "\$response" >> "\$upload_log" 2>/dev/null || true
        else
            message="Failed to send ${REMARK} backup part: \$FILE. Please check the server."
            echo "\$message"
            exit 1
        fi
    done
    echo "All backup parts sent successfully"
else
    message="Backup file not found: \$backup_name. Please check the server."
    echo "\$message"
    exit 1
fi

rm -rf *"${REMARK}${TAG}"* 2>/dev/null || true
EOL

    # Save the restore configuration (used by the "Restore Backup" menu)
    local STATE_PATH
    STATE_PATH=$(restore_state_file "$REMARK")
    {
        echo "# Backuper restore configuration - generated automatically"
        echo "REMARK=$(printf '%q' "$REMARK")"
        echo "PLATFORM=$(printf '%q' "${PLATFORM:-}")"
        echo "BACKUP_DIRECTORIES=$(printf '%q' "${BACKUP_DIRECTORIES:-}")"
        echo "DB_DUMP_PATH=$(printf '%q' "${DB_PATH:-}")"
        echo "RESTORE_DB_COMMAND=$(printf '%q' "${RESTORE_DB_COMMAND:-}")"
        case "${PLATFORM:-}" in
            telegram)
                echo "TG_TOKEN=$(printf '%q' "${BOT_TOKEN:-}")"
                echo "TG_CHAT=$(printf '%q' "${CHAT_ID:-}")"
                echo "TG_TOPIC=$(printf '%q' "${TOPIC_ID:-}")"
                ;;
            discord)
                echo "DISCORD_WEBHOOK=$(printf '%q' "${DISCORD_WEBHOOK:-}")"
                ;;
            gmail)
                echo "GMAIL_ADDRESS=$(printf '%q' "${GMAIL_ADDRESS:-}")"
                echo "GMAIL_PASSWORD=$(printf '%q' "${GMAIL_PASSWORD:-}")"
                ;;
        esac
        if [ -n "${PASSWORD:-}" ]; then
            echo "ZIP_PASSWORD=$(printf '%q' "$PASSWORD")"
        fi
    } > "$STATE_PATH"
    chmod 600 "$STATE_PATH" 2>/dev/null || true
    success "Restore configuration saved: $STATE_PATH"

    # Make the script executable
    chmod +x "$BACKUP_PATH"
    success "Backup script created: $BACKUP_PATH"
    
    # Run the backup script with realtime output
    log "Running the backup script..."
    if bash "$BACKUP_PATH" 2>&1 | tee /tmp/backup.log; then
        success "Backup script run successfully."
        
        # Set up cron job
        log "Setting up cron job..."
        RUN_LOG="/root/.backuper_${REMARK}_run.log"
        if (crontab -l 2>/dev/null; echo "$TIMER $BACKUP_PATH >> $RUN_LOG 2>&1") | crontab -; then
            success "Cron job set up successfully. Backups will run every $minutes minutes."
        else
            error "Failed to set up cron job. Set it up manually: $TIMER $BACKUP_PATH"
            exit 1
        fi
        
        # Final success message
        success "🎉 Your backup system is set up and running!"
        success "Backup script location: $BACKUP_PATH"
        success "Cron job: Every $minutes minutes"
        success "First backup created and sent."
        success "Thank you for using ${PROJECT_NAME}. Enjoy automated backups!"
        exit 0
    else
        error "Failed to run backup script. Full output:"
        cat /tmp/backup.log
        message="Backup script failed to run. Please check the server."
        eval "$PLATFORM_COMMAND"
        rm -f /tmp/backup.log
        exit 1
    fi
}

main() {
    clear
    check_root

    case "${1:-}" in
        restore|--restore|-r)
            install_dependencies
            restore_backup
            exit 0
            ;;
        install|--install|-i)
            if noni; then
                # Non-interactive install (used by the web panel)
                install_dependencies
                install_yq
                start_backup
                exit 0
            fi
            menu
            exit 0
            ;;
        "" )
            menu
            ;;
        *)
            wrong "Unknown option: $1"
            print "Usage: bash backuper.sh [restore]"
            exit 1
            ;;
    esac
}

main "$@"
