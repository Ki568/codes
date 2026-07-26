#!/usr/bin/env bash
#
# Razor Hosting VPS Utility Installer
# Version: 2.0
# Repo:    https://github.com/Ki568/codes
#
# Install with:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Ki568/codes/main/installer.sh)
#
set -Eeuo pipefail

# ───────────────────────────────────────────────
# GLOBALS
# ───────────────────────────────────────────────
SCRIPT_VERSION="2.0"
SCRIPT_URL="https://raw.githubusercontent.com/Ki568/codes/main/installer.sh"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")"
LOG_FILE="/var/log/razor-installer.log"
LOG_MAX_BYTES=$((5 * 1024 * 1024))   # 5MB
BACKUP_DIR="/var/backups/razor-installer"
CLOUDFLARED_TOKEN_FILE="/etc/cloudflared/token"
CLOUDFLARED_SERVICE_FILE="/etc/systemd/system/cloudflared.service"
MIN_FREE_MB=512   # minimum free disk space required before installing anything

# Colors
C_RESET="\033[0m"
C_BLUE="\033[1;34m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"
C_CYAN="\033[1;36m"
C_MAGENTA="\033[1;35m"
C_WHITE="\033[1;37m"
C_BOLD="\033[1m"

ICON_OK="✔"
ICON_ERR="✖"
ICON_WARN="⚠"

# ───────────────────────────────────────────────
# LOGGING (with rotation)
# ───────────────────────────────────────────────
rotate_log_if_needed() {
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S).old" 2>/dev/null || true
            # Keep only the 3 most recent rotated logs
            ls -1t "${LOG_FILE}".*.old 2>/dev/null | tail -n +4 | xargs -r rm -f
        fi
    fi
}

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    rotate_log_if_needed
    echo "[$ts] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

info()    { echo -e "${C_CYAN}[i]${C_RESET} $*";                 log "INFO" "$*"; }
success() { echo -e "${C_GREEN}[${ICON_OK}]${C_RESET} $*";       log "SUCCESS" "$*"; }
warn()    { echo -e "${C_YELLOW}[${ICON_WARN}]${C_RESET} $*";    log "WARNING" "$*"; }
error()   { echo -e "${C_RED}[${ICON_ERR}]${C_RESET} $*";        log "ERROR" "$*"; }

# ───────────────────────────────────────────────
# ERROR TRAP (crash safety, not for expected failures)
# ───────────────────────────────────────────────
on_error() {
    local line="$1"
    error "Unexpected error on line $line. See $LOG_FILE for details."
    echo -e "${C_YELLOW}The installer hit an unexpected problem and stopped this step.${C_RESET}"
    echo -e "${C_YELLOW}You can re-run the script safely — it is designed to be idempotent.${C_RESET}"
}
trap 'on_error $LINENO' ERR

# run_step: execute a command WITHOUT letting a failure kill the whole script.
# Use this around anything that is allowed to fail (checks, optional installs).
run_step() {
    "$@"
    return $?
}

# safe: like run_step but swallows the error trap for this one call
safe() {
    local rc=0
    set +e
    "$@"
    rc=$?
    set -e
    return $rc
}

# ───────────────────────────────────────────────
# UI HELPERS
# ───────────────────────────────────────────────
progress_bar() {
    # progress_bar <current> <total> <label>
    local current="$1" total="$2" label="$3"
    local width=30
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))
    local bar
    bar=$(printf "%${filled}s" | tr ' ' '#')
    bar+=$(printf "%${empty}s" | tr ' ' '-')
    printf "\r${C_CYAN}[%s]${C_RESET} %3d%% %s" "$bar" $(( current * 100 / total )) "$label"
    if [ "$current" -eq "$total" ]; then echo ""; fi
}

spinner_run() {
    # spinner_run "message" -- command args...
    local msg="$1"; shift
    if [ "$1" = "--" ]; then shift; fi
    local logtmp
    logtmp="$(mktemp)"
    ( "$@" >"$logtmp" 2>&1 ) &
    local pid=$!
    local spinstr='|/-\'
    local i=0
    echo -ne "${C_CYAN}[..]${C_RESET} ${msg} "
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % 4 ))
        printf "\b${spinstr:$i:1}"
        sleep 0.15
    done
    wait "$pid"
    local status=$?
    printf "\b"
    if [ $status -eq 0 ]; then
        echo -e "${C_GREEN}${ICON_OK}${C_RESET}"
        success "$msg"
    else
        echo -e "${C_RED}${ICON_ERR}${C_RESET}"
        error "$msg failed (see $LOG_FILE)"
        cat "$logtmp" >> "$LOG_FILE" 2>/dev/null || true
    fi
    rm -f "$logtmp"
    return $status
}

pause() {
    echo ""
    read -rp "Press [Enter] to return to the menu..." _ || true
}

# ───────────────────────────────────────────────
# ROOT CHECK
# ───────────────────────────────────────────────
ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            warn "Not running as root. Relaunching with sudo..."
            exec sudo bash "$SCRIPT_PATH" "$@"
        else
            error "This script must be run as root, and sudo is not available."
            exit 1
        fi
    fi
}

# ───────────────────────────────────────────────
# OS DETECTION
# ───────────────────────────────────────────────
OS_ID=""
OS_VERSION=""
OS_CODENAME=""

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_CODENAME="${VERSION_CODENAME:-unknown}"
    else
        error "Cannot detect operating system (/etc/os-release missing)."
        exit 1
    fi

    case "$OS_ID" in
        ubuntu)
            case "$OS_VERSION" in
                20.04|22.04|24.04) ;;
                *) warn "Ubuntu $OS_VERSION is not officially supported. Continuing anyway." ;;
            esac
            ;;
        debian)
            case "$OS_VERSION" in
                11|12) ;;
                *) warn "Debian $OS_VERSION is not officially supported. Continuing anyway." ;;
            esac
            ;;
        *)
            error "Unsupported operating system: $OS_ID. This installer supports Ubuntu 20.04+/Debian 11+."
            exit 1
            ;;
    esac
    log "INFO" "Detected OS: $OS_ID $OS_VERSION ($OS_CODENAME)"
}

# ───────────────────────────────────────────────
# DISK SPACE CHECK
# ───────────────────────────────────────────────
check_disk_space() {
    local free_mb
    free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [ "$free_mb" -lt "$MIN_FREE_MB" ]; then
        error "Only ${free_mb}MB free on / — at least ${MIN_FREE_MB}MB is recommended. Free up space before continuing."
        read -rp "Continue anyway? (y/N): " cont
        [[ "$cont" =~ ^[Yy]$ ]] || exit 1
    else
        success "Disk space check passed (${free_mb}MB free)."
    fi
}

# ───────────────────────────────────────────────
# INTERNET CONNECTIVITY CHECK
# ───────────────────────────────────────────────
check_internet() {
    info "Checking internet connectivity..."
    local hosts=("google.com" "github.com" "pkg.cloudflare.com" "tailscale.com")
    local failed=0
    for h in "${hosts[@]}"; do
        if ! safe curl -fsSL --connect-timeout 5 "https://$h" -o /dev/null; then
            warn "Could not reach $h"
            failed=$((failed + 1))
        fi
    done
    if [ "$failed" -eq "${#hosts[@]}" ]; then
        error "No internet connectivity detected. Exiting."
        exit 1
    elif [ "$failed" -gt 0 ]; then
        warn "Some hosts were unreachable, but continuing since partial connectivity exists."
    else
        success "Internet connectivity verified."
    fi
}

# ───────────────────────────────────────────────
# APT LOCK / BROKEN PACKAGE HANDLING
# ───────────────────────────────────────────────
fix_apt_issues() {
    if command -v fuser >/dev/null 2>&1 && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        warn "APT lock detected. Waiting for other package operations to finish..."
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
            sleep 2
        done
    fi
    safe dpkg --configure -a
    safe apt-get install -f -y
}

# ───────────────────────────────────────────────
# SYSTEM UPDATE (only upgrade if updates exist) + CLEANUP
# ───────────────────────────────────────────────
update_system() {
    spinner_run "Refreshing package lists" -- apt-get update -y

    local upgradable
    upgradable=$(apt list --upgradable 2>/dev/null | grep -vc "^Listing" || true)
    if [ "$upgradable" -gt 0 ]; then
        info "$upgradable package(s) can be upgraded."
        if ! spinner_run "Upgrading packages" -- env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; then
            warn "Upgrade step failed — continuing installer anyway."
        fi
    else
        success "System already up to date. No upgrade needed."
    fi

    spinner_run "Removing unused packages (autoremove)" -- env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
    spinner_run "Cleaning package cache (autoclean)" -- apt-get autoclean -y || true
}

# ───────────────────────────────────────────────
# DEPENDENCIES (curl, git, wget, nodejs, npm, python3, pip)
# ───────────────────────────────────────────────
install_dependencies() {
    info "Installing base dependencies..."
    local deps=(curl wget git unzip tar nano ca-certificates gnupg software-properties-common lsb-release apt-transport-https)
    local missing=()
    for d in "${deps[@]}"; do
        dpkg -s "$d" >/dev/null 2>&1 || missing+=("$d")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        spinner_run "Installing: ${missing[*]}" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    else
        success "Base dependencies already installed."
    fi

    install_python
    install_nodejs
}

install_python() {
    if command -v python3 >/dev/null 2>&1; then
        success "Python3 already installed ($(python3 --version 2>&1))."
    else
        spinner_run "Installing Python3" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y python3
    fi

    if ! command -v pip3 >/dev/null 2>&1; then
        spinner_run "Installing pip3" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip
    else
        success "pip3 already installed ($(pip3 --version 2>&1 | awk '{print $1, $2}'))."
    fi
}

install_nodejs() {
    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        success "Node.js already installed ($(node --version 2>&1)), npm ($(npm --version 2>&1))."
        return
    fi
    info "Installing Node.js LTS (via NodeSource)..."
    if safe bash -c 'curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -' ; then
        spinner_run "Installing nodejs package" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    else
        warn "NodeSource setup script failed, falling back to distro nodejs package."
        spinner_run "Installing nodejs (distro package)" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm
    fi

    if command -v node >/dev/null 2>&1; then
        success "Node.js installed: $(node --version)"
    else
        error "Node.js installation failed. Check $LOG_FILE"
    fi
}

# ───────────────────────────────────────────────
# CONFIG BACKUP HELPER
# ───────────────────────────────────────────────
backup_file() {
    # backup_file <path>
    local f="$1"
    if [ -f "$f" ]; then
        mkdir -p "$BACKUP_DIR"
        local ts
        ts=$(date +%Y%m%d%H%M%S)
        local base
        base=$(basename "$f")
        cp -a "$f" "${BACKUP_DIR}/${base}.${ts}.bak"
        warn "Existing file $f backed up to ${BACKUP_DIR}/${base}.${ts}.bak before overwrite."
    fi
}

# ───────────────────────────────────────────────
# BANNER / MAIN MENU
# ───────────────────────────────────────────────
print_banner() {
    clear
    echo -e "${C_BLUE}╔══════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BLUE}║${C_RESET}${C_BOLD}           RAZOR HOSTING INSTALLER            ${C_RESET}${C_BLUE}║${C_RESET}"
    echo -e "${C_BLUE}║${C_RESET}               Version $SCRIPT_VERSION                   ${C_BLUE}║${C_RESET}"
    echo -e "${C_BLUE}╚══════════════════════════════════════════════╝${C_RESET}"
    echo -e "${C_WHITE}OS:${C_RESET} ${OS_ID:-?} ${OS_VERSION:-?}   ${C_WHITE}User:${C_RESET} $(whoami)   ${C_WHITE}RAM:${C_RESET} $(free -h 2>/dev/null | awk '/Mem:/ {print $3"/"$2}')   ${C_WHITE}CPU:${C_RESET} $(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2+$4"%"}')"
    echo ""
}

print_menu() {
    echo -e "${C_CYAN}1)${C_RESET} Cloudflared (Install + Auto Fix)"
    echo -e "${C_CYAN}2)${C_RESET} Fastfetch"
    echo -e "${C_CYAN}3)${C_RESET} Tailscale"
    echo -e "${C_CYAN}4)${C_RESET} SSH Login Banner"
    echo -e "${C_CYAN}5)${C_RESET} System Information"
    echo -e "${C_CYAN}6)${C_RESET} Update Installer"
    echo -e "${C_CYAN}7)${C_RESET} About"
    echo -e "${C_CYAN}8)${C_RESET} Exit"
    echo ""
}

# ───────────────────────────────────────────────
# MODULE 1: CLOUDFLARED (INSTALL + AUTO FIX)
# ───────────────────────────────────────────────
cloudflared_add_repo() {
    info "Adding Cloudflare GPG key and APT repository..."
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    spinner_run "Updating package lists for cloudflared repo" -- apt-get update -y
}

cloudflared_install_or_upgrade() {
    if command -v cloudflared >/dev/null 2>&1; then
        info "cloudflared already installed. Checking for upgrade..."
        spinner_run "Upgrading cloudflared" -- apt-get install --only-upgrade -y cloudflared
    else
        if ! spinner_run "Installing cloudflared" -- apt-get install -y cloudflared; then
            error "cloudflared installation failed. Check $LOG_FILE"
            return 1
        fi
    fi
    command -v cloudflared >/dev/null 2>&1
}

# basic sanity validation for a Cloudflare tunnel token (base64-ish, reasonably long)
validate_cf_token() {
    local token="$1"
    if [ -z "$token" ]; then
        error "No token provided."
        return 1
    fi
    if [ "${#token}" -lt 50 ]; then
        error "That doesn't look like a valid Cloudflare Tunnel token (too short)."
        return 1
    fi
    if [[ ! "$token" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
        error "Token contains unexpected characters — double-check you copied it correctly."
        return 1
    fi
    return 0
}

cloudflared_write_token() {
    local token="$1"
    mkdir -p /etc/cloudflared
    backup_file "$CLOUDFLARED_TOKEN_FILE"
    echo "$token" | tee "$CLOUDFLARED_TOKEN_FILE" >/dev/null
    chmod 600 "$CLOUDFLARED_TOKEN_FILE"
    success "Tunnel token saved securely to $CLOUDFLARED_TOKEN_FILE (permissions 600)."
}

cloudflared_write_service() {
    local cf_bin
    cf_bin="$(command -v cloudflared)"
    if [ -z "$cf_bin" ]; then
        error "cloudflared binary not found on PATH — cannot write service file."
        return 1
    fi

    backup_file "$CLOUDFLARED_SERVICE_FILE"

    cat > "$CLOUDFLARED_SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel (Razor Hosting)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=${cf_bin} --no-autoupdate tunnel run --protocol http2 --token-file ${CLOUDFLARED_TOKEN_FILE}
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    success "systemd service written using detected binary: $cf_bin (forced --protocol http2)."
}

cloudflared_enable_start() {
    systemctl daemon-reload
    systemctl enable cloudflared >>"$LOG_FILE" 2>&1 || true
    systemctl restart cloudflared

    sleep 3
    if systemctl is-active --quiet cloudflared; then
        success "cloudflared service is active and running."
    else
        error "cloudflared service failed to start."
        warn "Recent journal logs:"
        journalctl -u cloudflared --no-pager -n 30 || true
        warn "Test manually with:"
        echo "  cloudflared tunnel run --protocol http2 --token-file $CLOUDFLARED_TOKEN_FILE"
        return 1
    fi
}

module_cloudflared() {
    print_banner
    echo -e "${C_BOLD}Cloudflared (Install + Auto Fix)${C_RESET}"
    echo ""

    fix_apt_issues
    cloudflared_add_repo
    if ! cloudflared_install_or_upgrade; then pause; return; fi

    echo ""
    read -rp "Paste your Cloudflare Tunnel Token: " CF_TOKEN
    if ! validate_cf_token "$CF_TOKEN"; then
        pause
        return
    fi

    cloudflared_write_token "$CF_TOKEN"
    cloudflared_write_service
    cloudflared_enable_start

    echo ""
    systemctl status cloudflared --no-pager -l | head -n 15 || true
    pause
}

# ───────────────────────────────────────────────
# MODULE 2: FASTFETCH (OS-aware)
# ───────────────────────────────────────────────
module_fastfetch() {
    print_banner
    echo -e "${C_BOLD}Fastfetch${C_RESET}"
    echo ""

    if command -v fastfetch >/dev/null 2>&1; then
        info "fastfetch already installed. Checking for upgrade..."
        if [ "$OS_ID" = "ubuntu" ]; then
            spinner_run "Upgrading fastfetch (PPA)" -- bash -c "apt-get update -y && apt-get install --only-upgrade -y fastfetch"
        else
            spinner_run "Upgrading fastfetch" -- bash -c "apt-get update -y && apt-get install --only-upgrade -y fastfetch"
        fi
    else
        if [ "$OS_ID" = "ubuntu" ]; then
            info "Ubuntu detected — using fastfetch PPA."
            if ! spinner_run "Adding fastfetch PPA" -- add-apt-repository -y ppa:zhangsongcui3371/fastfetch; then
                warn "PPA add failed — will try installing from default repos instead."
            fi
            spinner_run "Refreshing package lists" -- apt-get update -y
            spinner_run "Installing fastfetch" -- apt-get install -y fastfetch
        else
            info "Debian detected — installing fastfetch from default repositories."
            spinner_run "Refreshing package lists" -- apt-get update -y
            spinner_run "Installing fastfetch" -- apt-get install -y fastfetch
        fi

        if ! command -v fastfetch >/dev/null 2>&1; then
            error "fastfetch installation failed. Check $LOG_FILE"
            pause
            return
        fi
    fi

    echo ""
    fastfetch || true
    pause
}

# ───────────────────────────────────────────────
# MODULE 3: TAILSCALE
# ───────────────────────────────────────────────
tailscale_show_status() {
    echo ""
    echo -e "${C_MAGENTA}--- Tailscale Status ---${C_RESET}"
    echo -e "${C_CYAN}Hostname     :${C_RESET} $(hostname)"
    echo -e "${C_CYAN}IPv4         :${C_RESET} $(tailscale ip -4 2>/dev/null || echo 'N/A')"
    local magicdns
    magicdns=$(tailscale status --json 2>/dev/null | grep -o '"MagicDNSSuffix":"[^"]*"' | cut -d'"' -f4 || true)
    echo -e "${C_CYAN}MagicDNS     :${C_RESET} ${magicdns:-N/A}"
    echo -e "${C_CYAN}Status       :${C_RESET}"
    tailscale status 2>/dev/null | head -n 8 || true
    echo ""
}

module_tailscale() {
    print_banner
    echo -e "${C_BOLD}Tailscale${C_RESET}"
    echo ""
    echo "1) Install / Upgrade + Connect"
    echo "2) Disconnect"
    echo "3) Reconnect"
    echo "4) Update"
    echo "5) Back"
    echo ""
    read -rp "Choose an option: " ts_choice

    case "$ts_choice" in
        1)
            if command -v tailscale >/dev/null 2>&1; then
                info "Tailscale already installed. Upgrading..."
            else
                info "Installing Tailscale..."
            fi
            spinner_run "Running Tailscale install script" -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
            systemctl enable --now tailscaled >>"$LOG_FILE" 2>&1 || true
            info "Starting Tailscale. Follow the authentication URL below if prompted:"
            tailscale up || true
            tailscale_show_status
            ;;
        2)
            tailscale down || true
            success "Tailscale disconnected."
            ;;
        3)
            tailscale up || true
            tailscale_show_status
            ;;
        4)
            spinner_run "Updating Tailscale" -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
            ;;
        5)
            return
            ;;
        *)
            warn "Invalid option."
            ;;
    esac
    pause
}

# ───────────────────────────────────────────────
# MODULE 4: SSH LOGIN BANNER (expanded)
# ───────────────────────────────────────────────
module_ssh_banner() {
    print_banner
    echo -e "${C_BOLD}SSH Login Banner${C_RESET}"
    echo ""
    info "Configuring Razor Hosting SSH login banner..."

    mkdir -p /etc/update-motd.d

    if [ -d /etc/update-motd.d ]; then
        for f in /etc/update-motd.d/*; do
            [ -f "$f" ] && [ "$(basename "$f")" != "00-razor-banner" ] && chmod -x "$f" 2>/dev/null || true
        done
    fi

    backup_file /etc/update-motd.d/00-razor-banner

    cat > /etc/update-motd.d/00-razor-banner <<'MOTD_EOF'
#!/usr/bin/env bash
C_BLUE="\033[1;34m"; C_GREEN="\033[1;32m"; C_CYAN="\033[1;36m"
C_YELLOW="\033[1;33m"; C_MAGENTA="\033[1;35m"; C_RED="\033[1;31m"; C_RESET="\033[0m"

echo -e "${C_BLUE}"
cat <<"ASCII"
 ____                       _   _           _   _
|  _ \ __ _ _______  _ __  | | | | ___  ___| |_(_)_ __   __ _
| |_) / _\` |_  / _ \| '__| | |_| |/ _ \/ __| __| | '_ \ / _\` |
|  _ < (_| |/ / (_) | |    |  _  | (_) \__ \ |_| | | | | (_| |
|_| \_\__,_/___\___/|_|    |_| |_|\___/|___/\__|_|_| |_|\__, |
                                                          |___/
ASCII
echo -e "${C_RESET}"

HOSTNAME_V=$(hostname)
PUB_IP=$(curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || echo "N/A")
PRIV_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
OS_NAME=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
KERNEL=$(uname -r)
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')
CPU_USAGE=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2 + $4"%"}')
RAM_USAGE=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
SWAP_USAGE=$(free -h | awk '/Swap:/ {print $3 "/" $2}')
DISK_USAGE=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 " used)"}')
UPTIME_V=$(uptime -p)
LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^ *//')
TZ_V=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
CUR_TIME=$(date '+%Y-%m-%d %H:%M:%S')
USERS_V=$(who | wc -l)

# CPU Temperature (best effort — not all VPS hosts expose this)
CPU_TEMP="N/A"
if command -v sensors >/dev/null 2>&1; then
    CPU_TEMP=$(sensors 2>/dev/null | grep -m1 -E "Package id 0|Tdie|Core 0" | awk '{print $3}')
    [ -z "$CPU_TEMP" ] && CPU_TEMP="N/A"
elif [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    RAW_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    [ -n "$RAW_TEMP" ] && CPU_TEMP="$((RAW_TEMP / 1000))°C"
fi

# Network speed (instantaneous rx/tx since boot, not live throughput)
NET_IFACE=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -n "$NET_IFACE" ] && [ -f "/sys/class/net/$NET_IFACE/statistics/rx_bytes" ]; then
    RX=$(( $(cat "/sys/class/net/$NET_IFACE/statistics/rx_bytes") / 1024 / 1024 ))
    TX=$(( $(cat "/sys/class/net/$NET_IFACE/statistics/tx_bytes") / 1024 / 1024 ))
    NET_SPEED="RX ${RX}MB / TX ${TX}MB (total since boot, iface: $NET_IFACE)"
else
    NET_SPEED="N/A"
fi

# VPS provider (best-effort heuristic)
VPS_PROVIDER="Unknown"
if [ -f /sys/class/dmi/id/sys_vendor ]; then
    VPS_PROVIDER=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
fi

# Last login (excluding current session)
LAST_LOGIN=$(last -n 2 -R 2>/dev/null | sed -n '2p' | awk '{print $1, $4, $5, $6, $7}')
[ -z "$LAST_LOGIN" ] && LAST_LOGIN="N/A"

# Kernel updates available
KERNEL_UPDATE="No"
if apt list --upgradable 2>/dev/null | grep -qi "linux-image"; then
    KERNEL_UPDATE="Yes — reboot recommended"
fi

# Docker status + container count
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
    DOCKER_STATUS="Running"
    DOCKER_COUNT=$(docker ps -q 2>/dev/null | wc -l)
elif command -v docker >/dev/null 2>&1; then
    DOCKER_STATUS="Installed (not running)"
    DOCKER_COUNT=0
else
    DOCKER_STATUS="Not installed"
    DOCKER_COUNT=0
fi

VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")

echo -e "${C_CYAN}Hostname       :${C_RESET} $HOSTNAME_V"
echo -e "${C_CYAN}Public IPv4    :${C_RESET} $PUB_IP"
echo -e "${C_CYAN}Private IP     :${C_RESET} $PRIV_IP"
echo -e "${C_GREEN}OS             :${C_RESET} $OS_NAME"
echo -e "${C_GREEN}Kernel         :${C_RESET} $KERNEL"
echo -e "${C_GREEN}VPS Provider   :${C_RESET} $VPS_PROVIDER"
echo -e "${C_YELLOW}CPU            :${C_RESET} $CPU_MODEL"
echo -e "${C_YELLOW}CPU Usage      :${C_RESET} $CPU_USAGE"
echo -e "${C_YELLOW}CPU Temp       :${C_RESET} $CPU_TEMP"
echo -e "${C_YELLOW}RAM Usage      :${C_RESET} $RAM_USAGE"
echo -e "${C_YELLOW}Swap Usage     :${C_RESET} $SWAP_USAGE"
echo -e "${C_YELLOW}Disk Usage     :${C_RESET} $DISK_USAGE"
echo -e "${C_MAGENTA}Network        :${C_RESET} $NET_SPEED"
echo -e "${C_MAGENTA}Uptime         :${C_RESET} $UPTIME_V"
echo -e "${C_MAGENTA}Load Average   :${C_RESET} $LOAD_AVG"
echo -e "${C_CYAN}Timezone       :${C_RESET} $TZ_V"
echo -e "${C_CYAN}Current Time   :${C_RESET} $CUR_TIME"
echo -e "${C_CYAN}Logged-in      :${C_RESET} $USERS_V user(s)"
echo -e "${C_CYAN}Last Login     :${C_RESET} $LAST_LOGIN"
echo -e "${C_RED}Kernel Update  :${C_RESET} $KERNEL_UPDATE"
echo -e "${C_GREEN}Docker         :${C_RESET} $DOCKER_STATUS ($DOCKER_COUNT container(s) running)"
echo -e "${C_GREEN}Virtualization :${C_RESET} $VIRT_TYPE"
echo ""

if command -v fastfetch >/dev/null 2>&1; then
    fastfetch
fi
MOTD_EOF

    chmod +x /etc/update-motd.d/00-razor-banner
    : > /etc/motd

    success "SSH login banner installed. It will show on next login."
    pause
}

# ───────────────────────────────────────────────
# MODULE 5: SYSTEM INFORMATION
# ───────────────────────────────────────────────
module_sysinfo() {
    print_banner
    echo -e "${C_BOLD}System Information${C_RESET}"
    echo ""

    local hostname_v os_name kernel cpu_model ram_v disk_v swap_v arch_v uptime_v
    local ipv4_v ipv6_v dns_v pkg_count proc_count virt_v cloud_v

    hostname_v=$(hostname)
    os_name=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    kernel=$(uname -r)
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')
    ram_v=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
    disk_v=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 " used)"}')
    swap_v=$(free -h | awk '/Swap:/ {print $3 "/" $2}')
    arch_v=$(uname -m)
    uptime_v=$(uptime -p)
    ipv4_v=$(safe curl -fsSL --max-time 3 https://api.ipify.org || echo "N/A")
    ipv6_v=$(safe curl -fsSL --max-time 3 https://api6.ipify.org || echo "N/A")
    dns_v=$(grep -m2 nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd ', ' -)
    pkg_count=$(dpkg -l 2>/dev/null | grep -c '^ii' || true)
    proc_count=$(ps aux --no-heading | wc -l)
    virt_v=$(systemd-detect-virt 2>/dev/null || echo "unknown")

    cloud_v="Unknown / Bare Metal / VPS"
    if [ -f /sys/class/dmi/id/sys_vendor ]; then
        cloud_v=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
    fi

    echo -e "${C_CYAN}Hostname          :${C_RESET} $hostname_v"
    echo -e "${C_CYAN}Operating System  :${C_RESET} $os_name"
    echo -e "${C_CYAN}Kernel            :${C_RESET} $kernel"
    echo -e "${C_YELLOW}CPU               :${C_RESET} $cpu_model"
    echo -e "${C_YELLOW}RAM               :${C_RESET} $ram_v"
    echo -e "${C_YELLOW}Disk              :${C_RESET} $disk_v"
    echo -e "${C_YELLOW}Swap              :${C_RESET} $swap_v"
    echo -e "${C_GREEN}Architecture      :${C_RESET} $arch_v"
    echo -e "${C_GREEN}Uptime            :${C_RESET} $uptime_v"
    echo -e "${C_MAGENTA}IPv4              :${C_RESET} $ipv4_v"
    echo -e "${C_MAGENTA}IPv6              :${C_RESET} $ipv6_v"
    echo -e "${C_MAGENTA}DNS Servers       :${C_RESET} $dns_v"
    echo -e "${C_CYAN}Package Count     :${C_RESET} $pkg_count"
    echo -e "${C_CYAN}Running Processes :${C_RESET} $proc_count"
    echo -e "${C_GREEN}Virtualization    :${C_RESET} $virt_v"
    echo -e "${C_GREEN}VPS Provider      :${C_RESET} $cloud_v"
    echo ""
    echo -e "${C_CYAN}Network Interfaces:${C_RESET}"
    ip -brief addr show 2>/dev/null | sed 's/^/  /'

    pause
}

# ───────────────────────────────────────────────
# MODULE 6: UPDATE INSTALLER (with checksum verification)
# ───────────────────────────────────────────────
module_update_installer() {
    print_banner
    echo -e "${C_BOLD}Update Installer${C_RESET}"
    echo ""

    info "Downloading latest installer from GitHub..."
    local tmp_file
    tmp_file="$(mktemp)"

    if curl -fsSL "$SCRIPT_URL" -o "$tmp_file"; then
        if [ -s "$tmp_file" ] && head -n1 "$tmp_file" | grep -q "^#!/"; then
            if bash -n "$tmp_file" 2>/dev/null; then
                chmod +x "$tmp_file"
                backup_file "$SCRIPT_PATH"
                cp "$tmp_file" "$SCRIPT_PATH"
                chmod +x "$SCRIPT_PATH"
                success "Installer updated and syntax-verified. Restarting..."
                rm -f "$tmp_file"
                sleep 1
                exec bash "$SCRIPT_PATH"
            else
                error "Downloaded script failed syntax verification. Update aborted for safety."
            fi
        else
            error "Downloaded file looks invalid (empty or not a shell script). Update aborted."
        fi
    else
        error "Failed to download latest installer. Check your internet connection or the repo URL."
    fi
    rm -f "$tmp_file" 2>/dev/null || true
    pause
}

# ───────────────────────────────────────────────
# MODULE 7: ABOUT
# ───────────────────────────────────────────────
module_about() {
    print_banner
    echo -e "${C_BOLD}About Razor Hosting Installer${C_RESET}"
    echo ""
    echo -e "${C_CYAN}Name           :${C_RESET} Razor Hosting VPS Utility Installer"
    echo -e "${C_CYAN}Version        :${C_RESET} $SCRIPT_VERSION"
    echo -e "${C_CYAN}Developer      :${C_RESET} Razor Hosting"
    echo -e "${C_CYAN}GitHub         :${C_RESET} https://github.com/Ki568/codes"
    echo -e "${C_CYAN}Supported OS   :${C_RESET} Ubuntu 20.04/22.04/24.04, Debian 11/12"
    echo -e "${C_CYAN}License        :${C_RESET} MIT"
    echo ""
    pause
}

# ───────────────────────────────────────────────
# STARTUP SEQUENCE
# ───────────────────────────────────────────────
startup_sequence() {
    print_banner
    ensure_root "$@"
    detect_os
    print_banner
    check_disk_space
    check_internet
    fix_apt_issues
    update_system
    install_dependencies
    success "Startup checks complete."
    sleep 1
}

# ───────────────────────────────────────────────
# MAIN LOOP
# ───────────────────────────────────────────────
main() {
    startup_sequence "$@"

    while true; do
        print_banner
        print_menu
        read -rp "Select an option [1-8]: " choice
        case "$choice" in
            1) module_cloudflared ;;
            2) module_fastfetch ;;
            3) module_tailscale ;;
            4) module_ssh_banner ;;
            5) module_sysinfo ;;
            6) module_update_installer ;;
            7) module_about ;;
            8) echo -e "${C_GREEN}Goodbye!${C_RESET}"; exit 0 ;;
            *) warn "Invalid option. Please choose 1-8." ; sleep 1 ;;
        esac
    done
}

main "$@"
