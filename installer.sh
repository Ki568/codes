#!/usr/bin/env bash
#
# Razor Hosting VPS Utility Installer
# Version: 3.0 — Cyberpunk Edition
# Repo:    https://github.com/Ki568/codes
#
# Install with:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Ki568/codes/main/installer.sh)
#
set -Eeuo pipefail

# ───────────────────────────────────────────────
# GLOBALS
# ───────────────────────────────────────────────
SCRIPT_VERSION="3.0"
BUILD_DATE="2026-07-26"
SCRIPT_URL="https://raw.githubusercontent.com/Ki568/codes/main/installer.sh"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")"
LOG_FILE="/var/log/razor-installer.log"
LOG_MAX_BYTES=$((5 * 1024 * 1024))
BACKUP_DIR="/var/backups/razor-installer"
CLOUDFLARED_TOKEN_FILE="/etc/cloudflared/token"
CLOUDFLARED_SERVICE_FILE="/etc/systemd/system/cloudflared.service"
MIN_FREE_MB=512

# ───────────────────────────────────────────────
# COLORS (cyberpunk palette)
# ───────────────────────────────────────────────
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
# 24-bit true color where supported, falls back gracefully on most modern terminals
C_BLUE="\033[38;2;0;191;255m"     # #00BFFF
C_CYAN="\033[38;2;0;255;255m"     # #00FFFF
C_PURPLE="\033[38;2;138;43;226m"  # #8A2BE2
C_WHITE="\033[97m"
C_GRAY="\033[38;2;200;200;200m"
C_GREEN="\033[38;2;57;255;20m"
C_YELLOW="\033[38;2;255;214;0m"
C_RED="\033[38;2;255;60;60m"

ICON_OK="✓"
ICON_ERR="✗"
ICON_WARN="⚠"
DOT_GREEN="🟢"
DOT_RED="🔴"
DOT_YELLOW="🟡"

SPIN_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

# ───────────────────────────────────────────────
# LOGGING
# ───────────────────────────────────────────────
rotate_log_if_needed() {
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
            mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d%H%M%S).old" 2>/dev/null || true
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

# Plain (non-boxed) status lines — used mid-flow, sparingly
info()    { echo -e "  ${C_CYAN}${ICON_OK}${C_RESET} $*";     log "INFO" "$*"; }
success() { echo -e "  ${C_GREEN}${ICON_OK}${C_RESET} $*";    log "SUCCESS" "$*"; }
warn()    { echo -e "  ${C_YELLOW}${ICON_WARN}${C_RESET} $*"; log "WARNING" "$*"; }
error()   { echo -e "  ${C_RED}${ICON_ERR}${C_RESET} $*";     log "ERROR" "$*"; }

# ───────────────────────────────────────────────
# ERROR TRAP
# ───────────────────────────────────────────────
on_error() {
    local line="$1"
    error "Unexpected error on line $line. See $LOG_FILE for details."
    echo -e "  ${C_YELLOW}The installer hit a snag and stopped this step. Safe to re-run.${C_RESET}"
}
trap 'on_error $LINENO' ERR

safe() {
    local rc=0
    set +e
    "$@"
    rc=$?
    set -e
    return $rc
}

# ───────────────────────────────────────────────
# BOX / CARD RENDERING HELPERS
# ───────────────────────────────────────────────
term_width() { tput cols 2>/dev/null || echo 60; }

hr() {
    local w char color
    w=$(( $(term_width) > 70 ? 70 : $(term_width) ))
    char="${1:-━}"
    color="${2:-$C_PURPLE}"
    printf "${color}"
    printf "%${w}s" | tr ' ' "$char"
    printf "${C_RESET}\n"
}

center_text() {
    local text="$1" width
    width=$(term_width)
    local pad=$(( (width - ${#text}) / 2 ))
    [ $pad -lt 0 ] && pad=0
    printf "%${pad}s%s\n" "" "$text"
}

box() {
    # box <color> <title-line1> [title-line2...]
    local color="$1"; shift
    local w=54
    echo -e "${color}╔$(printf '%.0s═' $(seq 1 $w))╗${C_RESET}"
    for line in "$@"; do
        local pad=$(( (w - ${#line}) / 2 ))
        [ $pad -lt 0 ] && pad=0
        printf "${color}║${C_RESET}%${pad}s${C_BOLD}%s${C_RESET}%$((w-pad-${#line}))s${color}║${C_RESET}\n" "" "$line" ""
    done
    echo -e "${color}╚$(printf '%.0s═' $(seq 1 $w))╝${C_RESET}"
}

success_box() {
    # success_box "message"
    box "$C_GREEN" "${ICON_OK} SUCCESS"
    echo -e "  ${C_WHITE}$1${C_RESET}"
    echo ""
    log "SUCCESS" "$1"
}

error_box() {
    box "$C_RED" "${ICON_ERR} ERROR"
    echo -e "  ${C_WHITE}$1${C_RESET}"
    echo -e "  ${C_DIM}See log: $LOG_FILE${C_RESET}"
    echo ""
    log "ERROR" "$1"
}

warning_box() {
    box "$C_YELLOW" "${ICON_WARN} WARNING"
    echo -e "  ${C_WHITE}$1${C_RESET}"
    echo ""
    log "WARNING" "$1"
}

card() {
    # card <number-glyph> <title> <subtitle>
    local num="$1" title="$2" sub="$3"
    local w=50
    # Reserve room for "NUM " prefix (glyph + space ≈ 2 display cols) on the title line
    local title_max=$((w - 4))
    local sub_max=$((w - 4))
    if [ "${#title}" -gt "$title_max" ]; then
        title="${title:0:$((title_max-1))}…"
    fi
    if [ "${#sub}" -gt "$sub_max" ]; then
        sub="${sub:0:$((sub_max-1))}…"
    fi
    echo -e "${C_BLUE}┌$(printf '%.0s─' $(seq 1 $w))┐${C_RESET}"
    printf "${C_BLUE}│${C_RESET} ${C_CYAN}%s${C_RESET} ${C_BOLD}%-*s${C_RESET} ${C_BLUE}│${C_RESET}\n" "$num" "$title_max" "$title"
    printf "${C_BLUE}│${C_RESET}   ${C_DIM}%-*s${C_RESET} ${C_BLUE}│${C_RESET}\n" "$sub_max" "$sub"
    echo -e "${C_BLUE}└$(printf '%.0s─' $(seq 1 $w))┘${C_RESET}"
}

# ───────────────────────────────────────────────
# SPINNER (unicode braille) + PROGRESS BAR
# ───────────────────────────────────────────────
spinner_run() {
    # spinner_run "message" -- command args...
    local msg="$1"; shift
    if [ "$1" = "--" ]; then shift; fi
    local logtmp
    logtmp="$(mktemp)"
    ( "$@" >"$logtmp" 2>&1 ) &
    local pid=$!
    local i=0
    echo -ne "  ${C_CYAN}${SPIN_FRAMES[0]}${C_RESET} ${msg}"
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) % ${#SPIN_FRAMES[@]} ))
        printf "\r  ${C_CYAN}%s${C_RESET} %s" "${SPIN_FRAMES[$i]}" "$msg"
        sleep 0.08
    done
    wait "$pid"
    local status=$?
    if [ $status -eq 0 ]; then
        printf "\r  ${C_GREEN}${ICON_OK}${C_RESET} %s\n" "$msg"
        log "SUCCESS" "$msg"
    else
        printf "\r  ${C_RED}${ICON_ERR}${C_RESET} %s\n" "$msg"
        log "ERROR" "$msg failed"
        cat "$logtmp" >> "$LOG_FILE" 2>/dev/null || true
    fi
    rm -f "$logtmp"
    return $status
}

progress_bar() {
    # progress_bar <current> <total> <label>
    local current="$1" total="$2" label="$3"
    local width=24
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))
    local bar_filled bar_empty
    bar_filled=$(printf "%${filled}s" | tr ' ' '█')
    bar_empty=$(printf "%${empty}s" | tr ' ' '░')
    printf "\r  ${C_CYAN}%s${C_GRAY}%s${C_RESET} %3d%%  %s" "$bar_filled" "$bar_empty" $(( current * 100 / total )) "$label"
    if [ "$current" -eq "$total" ]; then echo ""; fi
}

typewriter() {
    local text="$1" delay="${2:-0.015}"
    local i
    for (( i=0; i<${#text}; i++ )); do
        printf "%s" "${text:$i:1}"
        sleep "$delay"
    done
    echo ""
}

pause() {
    echo ""
    echo -e "  ${C_DIM}[Enter] Back   [Q] Quit${C_RESET}"
    read -rp "  > " _k || true
    if [[ "${_k:-}" =~ ^[Qq]$ ]]; then
        goodbye
        exit 0
    fi
}

# ───────────────────────────────────────────────
# CONFIG BACKUP HELPER
# ───────────────────────────────────────────────
backup_file() {
    local f="$1"
    if [ -f "$f" ]; then
        mkdir -p "$BACKUP_DIR"
        local ts base
        ts=$(date +%Y%m%d%H%M%S)
        base=$(basename "$f")
        cp -a "$f" "${BACKUP_DIR}/${base}.${ts}.bak"
        warn "Backed up existing $f"
    fi
}

# ───────────────────────────────────────────────
# ROOT CHECK
# ───────────────────────────────────────────────
ensure_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
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
OS_ID=""; OS_VERSION=""; OS_CODENAME=""

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_CODENAME="${VERSION_CODENAME:-unknown}"
    else
        error_box "Cannot detect operating system (/etc/os-release missing)."
        exit 1
    fi

    case "$OS_ID" in
        ubuntu)
            case "$OS_VERSION" in 20.04|22.04|24.04) ;; *) warn "Ubuntu $OS_VERSION not officially supported — continuing." ;; esac ;;
        debian)
            case "$OS_VERSION" in 11|12) ;; *) warn "Debian $OS_VERSION not officially supported — continuing." ;; esac ;;
        *)
            error_box "Unsupported operating system: $OS_ID. Supports Ubuntu 20.04+/Debian 11+."
            exit 1
            ;;
    esac
    log "INFO" "Detected OS: $OS_ID $OS_VERSION ($OS_CODENAME)"
}

# ───────────────────────────────────────────────
# LIVE STAT HELPERS (used in header, status bar, sysinfo)
# ───────────────────────────────────────────────
get_ram()      { free -h 2>/dev/null | awk '/Mem:/ {print $3"/"$2}'; }
get_cpu_pct()  { top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2+$4"%"}'; }
get_disk()     { df -h / 2>/dev/null | awk 'NR==2 {print $3"/"$2}'; }
get_uptime()   { uptime -p 2>/dev/null; }
get_pub_ip()   { safe curl -fsSL --max-time 3 https://api.ipify.org || echo "N/A"; }
get_priv_ip()  { hostname -I 2>/dev/null | awk '{print $1}'; }
get_kernel()   { uname -r; }
get_virt()     { systemd-detect-virt 2>/dev/null || echo "unknown"; }
get_hostname() { hostname; }

svc_dot() {
    # svc_dot <systemd-unit-name> -> prints colored dot
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        echo -e "$DOT_GREEN"
    else
        echo -e "$DOT_RED"
    fi
}

bin_dot() {
    # bin_dot <binary-name> -> installed check only
    if command -v "$1" >/dev/null 2>&1; then
        echo -e "$DOT_GREEN"
    else
        echo -e "$DOT_RED"
    fi
}

ssh_dot() {
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        echo -e "$DOT_GREEN"
    else
        echo -e "$DOT_RED"
    fi
}

internet_dot() {
    if safe curl -fsSL --max-time 2 https://github.com -o /dev/null; then
        echo -e "$DOT_GREEN"
    else
        echo -e "$DOT_RED"
    fi
}

# ───────────────────────────────────────────────
# DISK SPACE / INTERNET / APT CHECKS
# ───────────────────────────────────────────────
check_disk_space() {
    local free_mb
    free_mb=$(df -Pm / | awk 'NR==2 {print $4}')
    if [ "$free_mb" -lt "$MIN_FREE_MB" ]; then
        warning_box "Only ${free_mb}MB free on / (recommended: ${MIN_FREE_MB}MB+)."
        read -rp "  Continue anyway? (y/N): " cont
        [[ "$cont" =~ ^[Yy]$ ]] || exit 1
    fi
}

check_internet() {
    local hosts=("google.com" "github.com" "pkg.cloudflare.com" "tailscale.com")
    local failed=0
    for h in "${hosts[@]}"; do
        safe curl -fsSL --connect-timeout 5 "https://$h" -o /dev/null || failed=$((failed + 1))
    done
    if [ "$failed" -eq "${#hosts[@]}" ]; then
        error_box "No internet connectivity detected."
        exit 1
    fi
}

fix_apt_issues() {
    if command -v fuser >/dev/null 2>&1 && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        warn "APT lock detected — waiting..."
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
    fi
    safe dpkg --configure -a
    safe apt-get install -f -y
}

install_base_dependencies() {
    # Only curl/wget/git/unzip/tar/nano/etc — the lightweight essentials.
    # Node.js / Python / pip are NOT installed here anymore — moved to their
    # own on-demand modules so startup stays fast.
    local deps=(curl wget git unzip tar nano ca-certificates gnupg software-properties-common lsb-release apt-transport-https)
    local missing=()
    for d in "${deps[@]}"; do
        dpkg -s "$d" >/dev/null 2>&1 || missing+=("$d")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >>"$LOG_FILE" 2>&1
    fi
}

# ───────────────────────────────────────────────
# STARTUP SEQUENCE (animated checklist, per PRD)
# ───────────────────────────────────────────────
startup_sequence() {
    clear
    echo ""
    hr "━" "$C_PURPLE"
    center_text "RAZOR HOSTING"
    hr "━" "$C_PURPLE"
    echo ""
    echo -e "  ${C_CYAN}Loading Modules...${C_RESET}"
    echo ""

    local steps=(
        "Detecting Operating System:detect_os"
        "Checking Root Access:ensure_root"
        "Checking Disk Space:check_disk_space"
        "Checking Internet:check_internet"
        "Fixing Broken Packages:fix_apt_issues"
        "Refreshing Package Lists:apt_update_quiet"
        "Installing Core Dependencies:install_base_dependencies"
    )

    apt_update_quiet() { apt-get update -y >>"$LOG_FILE" 2>&1; }

    for step in "${steps[@]}"; do
        local label="${step%%:*}"
        local fn="${step##*:}"
        if "$fn" >>"$LOG_FILE" 2>&1; then
            echo -e "  ${C_GREEN}${ICON_OK}${C_RESET} ${label}"
        else
            echo -e "  ${C_YELLOW}${ICON_WARN}${C_RESET} ${label} ${C_DIM}(non-fatal, continuing)${C_RESET}"
        fi
        sleep 0.12
    done

    echo ""
    success_box "Environment ready."
    sleep 0.4
    show_ready_screen
}

show_ready_screen() {
    clear
    echo ""
    hr "═" "$C_CYAN"
    center_text "Razor Hosting VPS Utility"
    hr "═" "$C_CYAN"
    echo ""
    echo -e "  ${C_WHITE}Version${C_RESET} : $SCRIPT_VERSION"
    echo -e "  ${C_WHITE}OS${C_RESET}      : $OS_ID $OS_VERSION"
    echo -e "  ${C_WHITE}Kernel${C_RESET}  : $(get_kernel)"
    echo -e "  ${C_WHITE}RAM${C_RESET}     : $(get_ram)"
    echo -e "  ${C_WHITE}CPU${C_RESET}     : $(get_cpu_pct)"
    echo -e "  ${C_WHITE}Disk${C_RESET}    : $(get_disk)"
    echo -e "  ${C_WHITE}Network${C_RESET} : $([ "$(internet_dot)" = "$DOT_GREEN" ] && echo Online || echo Offline)"
    echo ""
    echo -e "  Status: ${DOT_GREEN} Ready"
    echo ""
    read -rp "  Press [Enter] to continue to the menu..." _ || true
}

# ───────────────────────────────────────────────
# HEADER + STATUS BAR + MENU (redrawn every loop)
# ───────────────────────────────────────────────
print_header() {
    clear
    echo -e "${C_PURPLE}╔══════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_PURPLE}║${C_RESET}                                                        ${C_PURPLE}║${C_RESET}"
    echo -e "${C_PURPLE}║${C_RESET}         ${C_BOLD}${C_CYAN}RAZOR HOSTING VPS${C_RESET}                            ${C_PURPLE}║${C_RESET}"
    echo -e "${C_PURPLE}║${C_RESET}         ${C_DIM}Utility Installer v${SCRIPT_VERSION}${C_RESET}                        ${C_PURPLE}║${C_RESET}"
    echo -e "${C_PURPLE}║${C_RESET}                                                        ${C_PURPLE}║${C_RESET}"
    echo -e "${C_PURPLE}╚══════════════════════════════════════════════════════╝${C_RESET}"

    echo -e "  ${C_DIM}Host:${C_RESET} $(get_hostname)  ${C_DIM}OS:${C_RESET} $OS_ID $OS_VERSION  ${C_DIM}Kernel:${C_RESET} $(get_kernel)  ${C_DIM}Virt:${C_RESET} $(get_virt)"
}

print_status_bar() {
    echo -e "  $(internet_dot) Online   ⚡ $(get_cpu_pct)   💾 $(get_ram)   📀 $(get_disk)   🕒 $(date '+%H:%M:%S')"
    hr "─" "$C_DIM"
}

print_menu_cards() {
    local items=(
        "①:Cloudflared:Install & Auto Repair Tunnel"
        "②:Fastfetch:System info on login"
        "③:Tailscale:Install Secure VPN"
        "④:SSH Banner:Custom login screen"
        "⑤:System Information:Full server overview"
        "⑥:Docker:Container engine"
        "⑦:Docker Compose:Multi-container orchestration"
        "⑧:PM2:Node.js process manager"
        "⑨:GitHub CLI:gh command line tool"
        "⑩:Update Installer:Pull latest version"
        "⑪:Logs:View / export / clear logs"
        "⑫:About:Version & project info"
        "⑬:Exit:Quit the installer"
    )
    local i=0
    for item in "${items[@]}"; do
        IFS=':' read -r num title sub <<< "$item"
        card "$num" "$title" "$sub"
        i=$((i+1))
        if (( i % 2 == 0 )); then echo ""; fi
    done
}

print_live_status_footer() {
    hr "─" "$C_DIM"
    echo -e "  ${C_DIM}Cloudflared:${C_RESET} $(svc_dot cloudflared)   ${C_DIM}Tailscale:${C_RESET} $(bin_dot tailscale)   ${C_DIM}Docker:${C_RESET} $(bin_dot docker)   ${C_DIM}Internet:${C_RESET} $(internet_dot)"
    echo -e "  ${C_DIM}[1-13] Select   [R] Refresh   [L] Logs   [H] Help   [Q] Quit${C_RESET}"
}

goodbye() {
    echo ""
    box "$C_PURPLE" "Razor Hosting" "See you next time"
}

show_help() {
    print_header
    box "$C_BLUE" "HELP"
    echo -e "  ${C_WHITE}Shortcut keys:${C_RESET}"
    echo -e "    ${C_CYAN}1-13${C_RESET}  Jump straight to a menu item"
    echo -e "    ${C_CYAN}R${C_RESET}     Refresh the live stats"
    echo -e "    ${C_CYAN}L${C_RESET}     Open the log viewer"
    echo -e "    ${C_CYAN}H${C_RESET}     Show this help"
    echo -e "    ${C_CYAN}Q${C_RESET}     Quit the installer"
    echo ""
    echo -e "  ${C_WHITE}Every module${C_RESET} (Cloudflared, Tailscale, Docker, etc.) opens its own"
    echo -e "  submenu with Install / Upgrade / Remove / Back — nothing runs"
    echo -e "  automatically just by opening it."
    pause
}

# ───────────────────────────────────────────────
# GENERIC "ACTION SUBMENU" — used by every module
# ───────────────────────────────────────────────
action_submenu() {
    # action_submenu <module title> <installed?0/1> <install_fn> <remove_fn> [<upgrade_fn>]
    local title="$1" installed="$2" install_fn="$3" remove_fn="$4" upgrade_fn="${5:-}"

    print_header
    box "$C_BLUE" "$title"
    if [ "$installed" -eq 1 ]; then
        echo -e "  Status: ${DOT_GREEN} Installed"
    else
        echo -e "  Status: ${DOT_RED} Not installed"
    fi
    echo ""
    local opt=1
    echo -e "  ${C_CYAN}1)${C_RESET} Install$([ "$installed" -eq 1 ] && echo ' (reinstall)')"
    if [ -n "$upgrade_fn" ] && [ "$installed" -eq 1 ]; then
        echo -e "  ${C_CYAN}2)${C_RESET} Upgrade"
        echo -e "  ${C_CYAN}3)${C_RESET} Remove"
        echo -e "  ${C_CYAN}4)${C_RESET} Back"
    else
        echo -e "  ${C_CYAN}2)${C_RESET} Remove"
        echo -e "  ${C_CYAN}3)${C_RESET} Back"
    fi
    echo ""
    read -rp "  > " sub_choice

    if [ -n "$upgrade_fn" ] && [ "$installed" -eq 1 ]; then
        case "$sub_choice" in
            1) "$install_fn" ;;
            2) "$upgrade_fn" ;;
            3) confirm_and_run "Remove $title?" "$remove_fn" ;;
            4) return ;;
            *) warn "Invalid option." ;;
        esac
    else
        case "$sub_choice" in
            1) "$install_fn" ;;
            2) confirm_and_run "Remove $title?" "$remove_fn" ;;
            3) return ;;
            *) warn "Invalid option." ;;
        esac
    fi
    pause
}

confirm_and_run() {
    local prompt="$1" fn="$2"
    read -rp "  $prompt Type 'yes' to confirm: " c
    if [ "$c" = "yes" ]; then
        "$fn"
    else
        warn "Cancelled."
    fi
}

# ───────────────────────────────────────────────
# MODULE 1: CLOUDFLARED
# ───────────────────────────────────────────────
cloudflared_add_repo() {
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    apt-get update -y
}

validate_cf_token() {
    local token="$1"
    [ -z "$token" ] && { error "No token provided."; return 1; }
    [ "${#token}" -lt 50 ] && { error "That doesn't look like a valid Cloudflare Tunnel token (too short)."; return 1; }
    [[ "$token" =~ ^[A-Za-z0-9+/=_-]+$ ]] || { error "Token has unexpected characters — check what you copied."; return 1; }
    return 0
}

cf_install() {
    fix_apt_issues
    spinner_run "Adding Cloudflare repository" -- cloudflared_add_repo
    if ! spinner_run "Installing cloudflared" -- apt-get install -y cloudflared; then
        error_box "cloudflared installation failed."
        return 1
    fi

    echo ""
    read -rp "  Paste your Cloudflare Tunnel Token: " CF_TOKEN
    if ! validate_cf_token "$CF_TOKEN"; then
        return 1
    fi

    mkdir -p /etc/cloudflared
    backup_file "$CLOUDFLARED_TOKEN_FILE"
    echo "$CF_TOKEN" | tee "$CLOUDFLARED_TOKEN_FILE" >/dev/null
    chmod 600 "$CLOUDFLARED_TOKEN_FILE"

    local cf_bin
    cf_bin="$(command -v cloudflared)"
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

    systemctl daemon-reload
    systemctl enable cloudflared >>"$LOG_FILE" 2>&1 || true
    spinner_run "Starting cloudflared service" -- systemctl restart cloudflared
    sleep 2

    if systemctl is-active --quiet cloudflared; then
        success_box "Cloudflared installed and tunnel is running."
    else
        error_box "cloudflared service failed to start."
        warn "Recent logs:"
        journalctl -u cloudflared --no-pager -n 20 || true
        echo -e "  ${C_DIM}Manual test: cloudflared tunnel run --protocol http2 --token-file $CLOUDFLARED_TOKEN_FILE${C_RESET}"
    fi
}

cf_upgrade() {
    spinner_run "Upgrading cloudflared" -- apt-get install --only-upgrade -y cloudflared
    spinner_run "Restarting service" -- systemctl restart cloudflared
    success_box "Cloudflared upgrade check complete."
}

cf_remove() {
    spinner_run "Stopping service" -- systemctl stop cloudflared
    spinner_run "Disabling service" -- systemctl disable cloudflared
    rm -f "$CLOUDFLARED_SERVICE_FILE"
    spinner_run "Removing package" -- apt-get remove -y cloudflared
    systemctl daemon-reload
    success_box "Cloudflared removed. Token file left in place at $CLOUDFLARED_TOKEN_FILE — delete manually if not needed."
}

module_cloudflared() {
    local installed=0
    command -v cloudflared >/dev/null 2>&1 && installed=1
    action_submenu "① Cloudflared" "$installed" cf_install cf_remove cf_upgrade
}

# ───────────────────────────────────────────────
# MODULE 2: FASTFETCH (OS-aware)
# ───────────────────────────────────────────────
ff_install() {
    if [ "$OS_ID" = "ubuntu" ]; then
        spinner_run "Adding fastfetch PPA" -- add-apt-repository -y ppa:zhangsongcui3371/fastfetch || warn "PPA add failed, trying default repos"
    fi
    spinner_run "Refreshing package lists" -- apt-get update -y
    if spinner_run "Installing fastfetch" -- apt-get install -y fastfetch; then
        success_box "Fastfetch installed."
        echo ""
        fastfetch || true
    else
        error_box "Fastfetch installation failed."
    fi
}

ff_upgrade() {
    spinner_run "Refreshing package lists" -- apt-get update -y
    spinner_run "Upgrading fastfetch" -- apt-get install --only-upgrade -y fastfetch
    success_box "Fastfetch upgrade check complete."
}

ff_remove() {
    spinner_run "Removing fastfetch" -- apt-get remove -y fastfetch
    success_box "Fastfetch removed."
}

module_fastfetch() {
    local installed=0
    command -v fastfetch >/dev/null 2>&1 && installed=1
    action_submenu "② Fastfetch" "$installed" ff_install ff_remove ff_upgrade
}

# ───────────────────────────────────────────────
# MODULE 3: TAILSCALE
# ───────────────────────────────────────────────
ts_install() {
    spinner_run "Running Tailscale install script" -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
    systemctl enable --now tailscaled >>"$LOG_FILE" 2>&1 || true
    echo ""
    info "Starting Tailscale — follow the auth URL if one appears:"
    tailscale up || true
    echo ""
    echo -e "  ${C_CYAN}IPv4:${C_RESET} $(tailscale ip -4 2>/dev/null || echo N/A)"
    tailscale status 2>/dev/null | head -n 5 || true
    success_box "Tailscale setup complete."
}

ts_upgrade() {
    spinner_run "Updating Tailscale" -- bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
    success_box "Tailscale updated."
}

ts_remove() {
    safe tailscale down
    spinner_run "Removing tailscale package" -- apt-get remove -y tailscale
    success_box "Tailscale removed."
}

module_tailscale() {
    local installed=0
    command -v tailscale >/dev/null 2>&1 && installed=1
    action_submenu "③ Tailscale" "$installed" ts_install ts_remove ts_upgrade
}

# ───────────────────────────────────────────────
# MODULE 4: SSH LOGIN BANNER
# ───────────────────────────────────────────────
banner_install() {
    mkdir -p /etc/update-motd.d
    for f in /etc/update-motd.d/*; do
        [ -f "$f" ] && [ "$(basename "$f")" != "00-razor-banner" ] && chmod -x "$f" 2>/dev/null || true
    done
    backup_file /etc/update-motd.d/00-razor-banner

    cat > /etc/update-motd.d/00-razor-banner <<'MOTD_EOF'
#!/usr/bin/env bash
C_BLUE="\033[38;2;0;191;255m"; C_CYAN="\033[38;2;0;255;255m"; C_PURPLE="\033[38;2;138;43;226m"
C_GREEN="\033[38;2;57;255;20m"; C_YELLOW="\033[38;2;255;214;0m"; C_RED="\033[38;2;255;60;60m"
C_WHITE="\033[97m"; C_DIM="\033[2m"; C_RESET="\033[0m"

W=$(tput cols 2>/dev/null || echo 60)
sep() { printf "${C_PURPLE}"; printf "%${W}s" | tr ' ' '─'; printf "${C_RESET}\n"; }
center() { local t="$1"; local p=$(( (W - ${#t}) / 2 )); [ $p -lt 0 ] && p=0; printf "%${p}s%s\n" "" "$t"; }

echo ""
echo -e "${C_CYAN}"
center "R A Z O R   H O S T I N G"
echo -e "${C_RESET}"
sep

HOSTNAME_V=$(hostname)
PUB_IP=$(curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || echo "N/A")
PRIV_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
OS_NAME=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
KERNEL=$(uname -r)
CPU_USAGE=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2 + $4"%"}')
RAM_USAGE=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
DISK_USAGE=$(df -h / | awk 'NR==2 {print $3 "/" $2}')
UPTIME_V=$(uptime -p)
CUR_TIME=$(date '+%Y-%m-%d %H:%M:%S')
USERS_V=$(who | wc -l)
VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")

dot() { command -v "$1" >/dev/null 2>&1 && echo "🟢" || echo "🔴"; }
svcdot() { systemctl is-active --quiet "$1" 2>/dev/null && echo "🟢" || echo "🔴"; }

KUPDATE="No"
apt list --upgradable 2>/dev/null | grep -qi "linux-image" && KUPDATE="Yes — reboot recommended"

printf "  ${C_WHITE}%-16s${C_RESET} %s\n" "Hostname"    "$HOSTNAME_V"
printf "  ${C_WHITE}%-16s${C_RESET} %s\n" "OS"          "$OS_NAME"
printf "  ${C_WHITE}%-16s${C_RESET} %s\n" "Kernel"      "$KERNEL"
printf "  ${C_YELLOW}%-16s${C_RESET} %s\n" "CPU"         "$CPU_USAGE"
printf "  ${C_YELLOW}%-16s${C_RESET} %s\n" "RAM"         "$RAM_USAGE"
printf "  ${C_YELLOW}%-16s${C_RESET} %s\n" "Disk"        "$DISK_USAGE"
printf "  ${C_GREEN}%-16s${C_RESET} %s\n" "Uptime"      "$UPTIME_V"
printf "  ${C_GREEN}%-16s${C_RESET} %s\n" "Public IP"   "$PUB_IP"
printf "  ${C_GREEN}%-16s${C_RESET} %s\n" "Private IP"  "$PRIV_IP"
printf "  ${C_CYAN}%-16s${C_RESET} %s\n" "Virtualization" "$VIRT_TYPE"
printf "  ${C_CYAN}%-16s${C_RESET} %s %s\n" "Docker"      "$(dot docker)" "$(command -v docker >/dev/null 2>&1 && echo Installed || echo 'Not installed')"
printf "  ${C_CYAN}%-16s${C_RESET} %s %s\n" "Cloudflared"  "$(svcdot cloudflared)" "$(systemctl is-active --quiet cloudflared 2>/dev/null && echo Running || echo Stopped)"
printf "  ${C_CYAN}%-16s${C_RESET} %s %s\n" "Tailscale"    "$(dot tailscale)" "$(command -v tailscale >/dev/null 2>&1 && echo Installed || echo 'Not installed')"
printf "  ${C_WHITE}%-16s${C_RESET} %s\n" "Current Time" "$CUR_TIME"
printf "  ${C_WHITE}%-16s${C_RESET} %s\n" "Users Online" "$USERS_V"
printf "  ${C_RED}%-16s${C_RESET} %s\n" "Kernel Update" "$KUPDATE"

sep
if command -v fastfetch >/dev/null 2>&1; then
    fastfetch
fi
MOTD_EOF

    chmod +x /etc/update-motd.d/00-razor-banner
    : > /etc/motd
    success_box "Premium SSH login banner installed."
}

banner_remove() {
    rm -f /etc/update-motd.d/00-razor-banner
    success_box "SSH login banner removed."
}

module_ssh_banner() {
    local installed=0
    [ -f /etc/update-motd.d/00-razor-banner ] && installed=1
    action_submenu "④ SSH Banner" "$installed" banner_install banner_remove
}

# ───────────────────────────────────────────────
# MODULE 5: SYSTEM INFORMATION (two-column)
# ───────────────────────────────────────────────
module_sysinfo() {
    print_header
    box "$C_BLUE" "⑤ System Information"
    echo ""

    local cpu_model ram_v disk_v swap_v load_v arch_v virt_v
    local ipv4_v ipv6_v gw_v dns_v provider_v
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')
    ram_v=$(free -h | awk '/Mem:/ {print $3"/"$2}')
    disk_v=$(df -h / | awk 'NR==2 {print $3"/"$2}')
    swap_v=$(free -h | awk '/Swap:/ {print $3"/"$2}')
    load_v=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^ *//')
    arch_v=$(uname -m)
    virt_v=$(get_virt)
    ipv4_v=$(get_pub_ip)
    ipv6_v=$(safe curl -fsSL --max-time 3 https://api6.ipify.org || echo "N/A")
    gw_v=$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')
    dns_v=$(grep -m2 nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd ', ' - || true)
    provider_v=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Unknown")

    echo -e "  ${C_CYAN}${C_BOLD}System${C_RESET}                        ${C_CYAN}${C_BOLD}Network${C_RESET}"
    printf "  %-28s %-28s\n" "CPU: $cpu_model" "Public IPv4: $ipv4_v"
    printf "  %-28s %-28s\n" "RAM: $ram_v"     "IPv6: $ipv6_v"
    printf "  %-28s %-28s\n" "Disk: $disk_v"   "Gateway: $gw_v"
    printf "  %-28s %-28s\n" "Swap: $swap_v"   "DNS: $dns_v"
    printf "  %-28s %-28s\n" "Load: $load_v"   "Hostname: $(get_hostname)"
    printf "  %-28s %-28s\n" "Arch: $arch_v"   "Provider: $provider_v"
    printf "  %-28s\n" "Virt: $virt_v"
    echo ""
    echo -e "  ${C_CYAN}${C_BOLD}Services${C_RESET}"
    printf "  %-16s %s\n" "Docker"      "$(bin_dot docker)"
    printf "  %-16s %s\n" "Cloudflared" "$(svc_dot cloudflared)"
    printf "  %-16s %s\n" "Tailscale"   "$(bin_dot tailscale)"
    printf "  %-16s %s\n" "SSH"         "$(ssh_dot)"
    printf "  %-16s %s\n" "Systemd"     "$(svc_dot systemd-logind)"
    pause
}

# ───────────────────────────────────────────────
# MODULE 6: DOCKER
# ───────────────────────────────────────────────
docker_install() {
    spinner_run "Adding Docker GPG key" -- bash -c '
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/'"$OS_ID"'/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    '
    spinner_run "Adding Docker repository" -- bash -c '
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/'"$OS_ID"' '"$OS_CODENAME"' stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null
    '
    spinner_run "Refreshing package lists" -- apt-get update -y
    if spinner_run "Installing Docker" -- apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        systemctl enable --now docker >>"$LOG_FILE" 2>&1 || true
        success_box "Docker installed and running."
    else
        error_box "Docker installation failed."
    fi
}

docker_upgrade() {
    spinner_run "Refreshing package lists" -- apt-get update -y
    spinner_run "Upgrading Docker" -- apt-get install --only-upgrade -y docker-ce docker-ce-cli containerd.io
    success_box "Docker upgrade check complete."
}

docker_remove() {
    spinner_run "Stopping Docker" -- systemctl stop docker
    spinner_run "Removing Docker packages" -- apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    success_box "Docker removed. Images/volumes in /var/lib/docker left untouched — remove manually if desired."
}

module_docker() {
    local installed=0
    command -v docker >/dev/null 2>&1 && installed=1
    action_submenu "⑥ Docker" "$installed" docker_install docker_remove docker_upgrade
}

# ───────────────────────────────────────────────
# MODULE 7: DOCKER COMPOSE (standalone plugin check)
# ───────────────────────────────────────────────
compose_install() {
    if ! command -v docker >/dev/null 2>&1; then
        error_box "Docker isn't installed yet — install Docker first (menu ⑥)."
        return 1
    fi
    spinner_run "Installing Docker Compose plugin" -- apt-get install -y docker-compose-plugin
    success_box "Docker Compose plugin installed (use: docker compose)."
}

compose_remove() {
    spinner_run "Removing Docker Compose plugin" -- apt-get remove -y docker-compose-plugin
    success_box "Docker Compose plugin removed."
}

module_compose() {
    local installed=0
    docker compose version >/dev/null 2>&1 && installed=1
    action_submenu "⑦ Docker Compose" "$installed" compose_install compose_remove
}

# ───────────────────────────────────────────────
# MODULE 8: PM2 (installs Node.js on-demand, only here)
# ───────────────────────────────────────────────
pm2_install() {
    if ! command -v node >/dev/null 2>&1; then
        info "Node.js not found — installing it now (required for PM2)..."
        if safe bash -c 'curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -'; then
            spinner_run "Installing Node.js" -- apt-get install -y nodejs
        else
            warn "NodeSource script failed, falling back to distro package."
            spinner_run "Installing Node.js (distro package)" -- apt-get install -y nodejs npm
        fi
    fi

    if ! command -v node >/dev/null 2>&1; then
        error_box "Node.js installation failed — cannot install PM2."
        return 1
    fi

    if spinner_run "Installing PM2 globally via npm" -- npm install -g pm2; then
        success_box "PM2 installed: $(pm2 --version 2>/dev/null)"
    else
        error_box "PM2 installation failed."
    fi
}

pm2_upgrade() {
    spinner_run "Upgrading PM2" -- npm update -g pm2
    success_box "PM2 upgrade check complete."
}

pm2_remove() {
    spinner_run "Removing PM2" -- npm uninstall -g pm2
    success_box "PM2 removed. Node.js left installed."
}

module_pm2() {
    local installed=0
    command -v pm2 >/dev/null 2>&1 && installed=1
    action_submenu "⑧ PM2" "$installed" pm2_install pm2_remove pm2_upgrade
}

# ───────────────────────────────────────────────
# MODULE 9: GITHUB CLI
# ───────────────────────────────────────────────
ghcli_install() {
    spinner_run "Adding GitHub CLI GPG key" -- bash -c '
        mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
        chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    '
    spinner_run "Adding GitHub CLI repository" -- bash -c '
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    '
    spinner_run "Refreshing package lists" -- apt-get update -y
    if spinner_run "Installing gh" -- apt-get install -y gh; then
        success_box "GitHub CLI installed: $(gh --version 2>/dev/null | head -n1)"
    else
        error_box "GitHub CLI installation failed."
    fi
}

ghcli_upgrade() {
    spinner_run "Refreshing package lists" -- apt-get update -y
    spinner_run "Upgrading gh" -- apt-get install --only-upgrade -y gh
    success_box "GitHub CLI upgrade check complete."
}

ghcli_remove() {
    spinner_run "Removing gh" -- apt-get remove -y gh
    success_box "GitHub CLI removed."
}

module_ghcli() {
    local installed=0
    command -v gh >/dev/null 2>&1 && installed=1
    action_submenu "⑨ GitHub CLI" "$installed" ghcli_install ghcli_remove ghcli_upgrade
}

# ───────────────────────────────────────────────
# MODULE 10: UPDATE INSTALLER
# ───────────────────────────────────────────────
module_update_installer() {
    print_header
    box "$C_BLUE" "⑩ Update Installer"
    echo ""
    local tmp_file
    tmp_file="$(mktemp)"

    if spinner_run "Downloading latest installer" -- curl -fsSL "$SCRIPT_URL" -o "$tmp_file"; then
        if [ -s "$tmp_file" ] && head -n1 "$tmp_file" | grep -q "^#!/" && bash -n "$tmp_file" 2>/dev/null; then
            backup_file "$SCRIPT_PATH"
            cp "$tmp_file" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            success_box "Installer updated and verified. Restarting..."
            rm -f "$tmp_file"
            sleep 1
            exec bash "$SCRIPT_PATH"
        else
            error_box "Downloaded script failed verification — update aborted for safety."
        fi
    else
        error_box "Failed to download the latest installer."
    fi
    rm -f "$tmp_file" 2>/dev/null || true
    pause
}

# ───────────────────────────────────────────────
# MODULE 11: LOG VIEWER
# ───────────────────────────────────────────────
module_logs() {
    print_header
    box "$C_BLUE" "⑪ Logs"
    echo ""
    echo -e "  ${C_CYAN}1)${C_RESET} View Installer Logs"
    echo -e "  ${C_CYAN}2)${C_RESET} Latest Errors"
    echo -e "  ${C_CYAN}3)${C_RESET} Export Logs"
    echo -e "  ${C_CYAN}4)${C_RESET} Clear Logs"
    echo -e "  ${C_CYAN}5)${C_RESET} Back"
    echo ""
    read -rp "  > " log_choice
    case "$log_choice" in
        1)
            [ -f "$LOG_FILE" ] && tail -n 60 "$LOG_FILE" || echo "  No logs yet."
            ;;
        2)
            [ -f "$LOG_FILE" ] && grep -E "\[ERROR\]" "$LOG_FILE" | tail -n 30 || echo "  No logs yet."
            ;;
        3)
            local dest="/root/razor-installer-export-$(date +%Y%m%d%H%M%S).log"
            cp "$LOG_FILE" "$dest" 2>/dev/null && success_box "Exported to $dest" || error_box "Nothing to export."
            ;;
        4)
            confirm_and_run "Clear all installer logs?" "clear_logs_fn"
            ;;
        5) return ;;
        *) warn "Invalid option." ;;
    esac
    pause
}
clear_logs_fn() { : > "$LOG_FILE"; success_box "Logs cleared."; }

# ───────────────────────────────────────────────
# MODULE 12: ABOUT
# ───────────────────────────────────────────────
module_about() {
    print_header
    box "$C_PURPLE" "⑫ About"
    echo ""
    printf "  ${C_WHITE}%-14s${C_RESET} %s\n" "Project"      "Razor Hosting VPS Utility Installer"
    printf "  ${C_WHITE}%-14s${C_RESET} %s\n" "Version"      "$SCRIPT_VERSION"
    printf "  ${C_WHITE}%-14s${C_RESET} %s\n" "Developer"    "Razor Hosting"
    printf "  ${C_WHITE}%-14s${C_RESET} %s\n" "GitHub"       "https://github.com/Ki568/codes"
    printf "  ${C_WHITE}%-14s${C_RESET} %s\n" "Supported OS" "Ubuntu 20.04/22.04/24.04, Debian 11/12"
    printf "  ${C_WHITE}%-14s${C_RESET} %s\n" "License"      "MIT"
    printf "  ${C_WHITE}%-14s${C_RESET} %s\n" "Build Date"   "$BUILD_DATE"
    pause
}

# ───────────────────────────────────────────────
# MAIN LOOP
# ───────────────────────────────────────────────
main() {
    ensure_root "$@"
    startup_sequence

    while true; do
        print_header
        print_status_bar
        echo ""
        print_menu_cards
        print_live_status_footer
        echo ""
        read -rp "  Select: " choice

        case "$choice" in
            1)  module_cloudflared ;;
            2)  module_fastfetch ;;
            3)  module_tailscale ;;
            4)  module_ssh_banner ;;
            5)  module_sysinfo ;;
            6)  module_docker ;;
            7)  module_compose ;;
            8)  module_pm2 ;;
            9)  module_ghcli ;;
            10) module_update_installer ;;
            11) module_logs ;;
            12) module_about ;;
            13|[Qq]) goodbye; exit 0 ;;
            [Rr]) continue ;;
            [Ll]) module_logs ;;
            [Hh]) show_help ;;
            *) warn "Invalid option."; sleep 0.6 ;;
        esac
    done
}

main "$@"
