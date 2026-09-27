#!/data/data/com.termux/files/usr/bin/bash
#
# JediSec Termux Bootstrap v3.0
# Android / Termux only. No apt. No dnf. No laptop assumptions.
#
# Designed for a phone after the desktops die:
#   - pkg names that actually exist on Termux
#   - AI category that will install (openai client, not ollama/chromadb)
#   - heavy toolchain (clang/rust/golang) is opt-in
#   - pkg upgrade warned because it can kill the session
#   - logs + JSON summary under ~/.jedisec
#
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

VERSION="3.0.0"
JEDISEC_HOME="${HOME}/.jedisec"
LOG_DIR="${JEDISEC_HOME}/logs"
STATE_DIR="${JEDISEC_HOME}/state"
CONFIG_FILE="${JEDISEC_HOME}/packages.conf"
LOG_FILE="${LOG_DIR}/termux_bootstrap_$(date +%Y%m%d_%H%M%S).log"
SUMMARY_FILE="${STATE_DIR}/last_run_summary.txt"
JSON_SUMMARY_FILE="${STATE_DIR}/last_run_summary.json"
LOG_RETENTION_DAYS=14
REPO_URL="https://github.com/jedisecX/jedisec-termux-bootstrap.git"

PROJECT_DIRS=(
    "$HOME/Projects/JediSec"
    "$HOME/Projects/Scripts"
    "$HOME/Projects/AI"
    "$HOME/Projects/OSINT"
    "$HOME/.config"
)

declare -i COUNT_INSTALLED=0
declare -i COUNT_SKIPPED=0
declare -i COUNT_FAILED=0
FAILED_ITEMS=()
DRY_RUN=false
JSON_OUTPUT=false

# Termux pkg names only.
declare -A SYS_CATEGORIES=(
    [core]="git curl wget nano vim tmux openssh rsync tree jq zip unzip tar xz-utils p7zip"
    [dev]="make pkg-config python python-pip nodejs"
    [data]="sqlite openssl libffi libxml2 libxslt libjpeg-turbo libpng freetype zlib"
    [media]="ffmpeg imagemagick poppler"
    [network]="dnsutils inetutils net-tools nmap whois"
    [osint]="tesseract exiftool"
    [android]="termux-api termux-tools"
    [heavy]="clang cmake ninja rust golang"
)

SYS_CATEGORY_ORDER=(core dev data media network osint android)
HEAVY_CATEGORY="heavy"

# Python that survives a phone.
# ai = API clients only. No ollama daemon. No chromadb native build.
declare -A PY_CATEGORIES=(
    [core]="requests httpx aiohttp python-dotenv pyyaml orjson click typer rich tqdm"
    [web]="beautifulsoup4 lxml feedparser flask"
    [data]="pillow pymupdf pdfplumber"
    [ai]="openai httpx"
    [security]="cryptography pycryptodome paramiko dnspython tldextract"
    [db]="sqlalchemy aiosqlite"
    [osint]="gallery-dl yt-dlp exifread"
)

PY_CATEGORY_ORDER=(core web data ai security db osint)

mkdir -p "$LOG_DIR" "$STATE_DIR"

load_config_override() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        log INFO "Loaded config override: ${CONFIG_FILE}"
    fi
}

header() {
    $JSON_OUTPUT && return 0
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${GREEN}${BOLD}  JediSec Termux Bootstrap ${VERSION}${NC}"
    echo -e "${CYAN}  Android only · phone-sane packages${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo -e "Log: ${LOG_FILE}"
    $DRY_RUN && echo -e "${YELLOW}DRY RUN — no changes${NC}"
    echo
}

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local color icon
    case "$level" in
        OK)    color="$GREEN";  icon="[✓]" ;;
        WARN)  color="$YELLOW"; icon="[!]" ;;
        ERROR) color="$RED";    icon="[✗]" ;;
        *)     color="$NC";     icon="[i]" ;;
    esac
    if ! $JSON_OUTPUT; then
        echo -e "${color}${icon} ${msg}${NC}"
    fi
    echo "${ts} [${level}] ${msg}" >> "$LOG_FILE"
}

section() {
    if ! $JSON_OUTPUT; then
        echo
        echo -e "${MAGENTA}${BOLD}--- $1 ---${NC}"
    fi
    log INFO "=== $1 ==="
}

die_if_not_termux() {
    if [ -z "${PREFIX:-}" ] || [[ "$PREFIX" != *"com.termux"* ]] || ! command -v pkg >/dev/null 2>&1; then
        echo -e "${RED}This script is Termux-only.${NC}" >&2
        echo "PREFIX must be a Termux prefix and pkg must exist." >&2
        echo "Laptop / WSL / Debian: use jedisec-bootstrap instead." >&2
        exit 1
    fi
}

rotate_logs() {
    local removed
    removed=$(find "$LOG_DIR" -name "termux_bootstrap_*.log" -mtime "+${LOG_RETENTION_DAYS}" -print -delete 2>/dev/null | wc -l)
    if [ "${removed:-0}" -gt 0 ]; then
        log INFO "Log rotation: removed ${removed} old log(s)"
    fi
}

sys_pkg_installed() {
    local p="$1"
    dpkg -s "$p" >/dev/null 2>&1
}

py_pkg_installed() {
    local pkg="$1"
    local import_name
    case "$pkg" in
        python-dotenv)  import_name="dotenv" ;;
        pyyaml)         import_name="yaml" ;;
        beautifulsoup4) import_name="bs4" ;;
        pillow)         import_name="PIL" ;;
        pymupdf)        import_name="fitz" ;;
        python-magic)   import_name="magic" ;;
        gallery-dl)     import_name="gallery_dl" ;;
        *)              import_name="${pkg//-/_}" ;;
    esac
    python -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('${import_name}') else 1)" 2>/dev/null \
        || pip show "$pkg" >/dev/null 2>&1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_sys_category() {
    local cat="$1"
    local pkgs=(${SYS_CATEGORIES[$cat]:-})
    local to_install=()

    if [ "${#pkgs[@]}" -eq 0 ]; then
        log WARN "No packages defined for sys category '${cat}'"
        return 0
    fi

    section "System packages: ${cat}"

    for p in "${pkgs[@]}"; do
        if sys_pkg_installed "$p"; then
            log INFO "  ${p} already installed, skipping"
            ((COUNT_SKIPPED++)) || true
        else
            to_install+=("$p")
        fi
    done

    if [ "${#to_install[@]}" -eq 0 ]; then
        log OK "All '${cat}' packages already present."
        return 0
    fi

    if $DRY_RUN; then
        log INFO "[DRY RUN] Would pkg install (${cat}): ${to_install[*]}"
        COUNT_INSTALLED=$((COUNT_INSTALLED + ${#to_install[@]}))
        return 0
    fi

    log INFO "Installing: ${to_install[*]}"
    if pkg install -y "${to_install[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log OK "'${cat}' packages installed."
        COUNT_INSTALLED=$((COUNT_INSTALLED + ${#to_install[@]}))
    else
        log WARN "Batch install for '${cat}' failed, retrying one by one..."
        local p
        for p in "${to_install[@]}"; do
            if pkg install -y "$p" 2>&1 | tee -a "$LOG_FILE"; then
                log OK "  ${p} installed"
                ((COUNT_INSTALLED++)) || true
            else
                log ERROR "  ${p} failed"
                FAILED_ITEMS+=("sys:${p}")
                ((COUNT_FAILED++)) || true
            fi
        done
    fi
}

install_py_category() {
    local cat="$1"
    local pkgs=(${PY_CATEGORIES[$cat]:-})
    local to_install=()

    if [ "${#pkgs[@]}" -eq 0 ]; then
        log WARN "No packages defined for py category '${cat}'"
        return 0
    fi

    section "Python packages: ${cat}"

    if ! command_exists python || ! command_exists pip; then
        log ERROR "python/pip missing. Install sys:dev first."
        FAILED_ITEMS+=("py:${cat}:no-python")
        ((COUNT_FAILED++)) || true
        return 1
    fi

    for p in "${pkgs[@]}"; do
        if py_pkg_installed "$p"; then
            log INFO "  ${p} already installed, skipping"
            ((COUNT_SKIPPED++)) || true
        else
            to_install+=("$p")
        fi
    done

    if [ "${#to_install[@]}" -eq 0 ]; then
        log OK "All '${cat}' Python packages already present."
        return 0
    fi

    if $DRY_RUN; then
        log INFO "[DRY RUN] Would pip install (${cat}): ${to_install[*]}"
        COUNT_INSTALLED=$((COUNT_INSTALLED + ${#to_install[@]}))
        return 0
    fi

    log INFO "Installing: ${to_install[*]}"
    if pip install --break-system-packages "${to_install[@]}" >>"$LOG_FILE" 2>&1 \
        || pip install "${to_install[@]}" >>"$LOG_FILE" 2>&1; then
        log OK "'${cat}' Python packages installed."
        COUNT_INSTALLED=$((COUNT_INSTALLED + ${#to_install[@]}))
    else
        log WARN "Batch pip for '${cat}' failed, retrying one by one..."
        local p
        for p in "${to_install[@]}"; do
            if pip install --break-system-packages "$p" >>"$LOG_FILE" 2>&1 \
                || pip install "$p" >>"$LOG_FILE" 2>&1; then
                log OK "  ${p} installed"
                ((COUNT_INSTALLED++)) || true
            else
                log ERROR "  ${p} failed"
                FAILED_ITEMS+=("py:${p}")
                ((COUNT_FAILED++)) || true
            fi
        done
    fi
}

pkg_update() {
    section "pkg update"
    if $DRY_RUN; then
        log INFO "[DRY RUN] Would run: pkg update -y"
        return 0
    fi
    log WARN "pkg upgrade can kill this session. This script only runs pkg update by default."
    log WARN "Run --upgrade if you really want pkg upgrade -y (then relaunch Termux and re-run)."
    pkg update -y 2>&1 | tee -a "$LOG_FILE" || log WARN "pkg update reported issues, continuing"
}

pkg_upgrade() {
    section "pkg upgrade"
    if $DRY_RUN; then
        log INFO "[DRY RUN] Would run: pkg upgrade -y"
        return 0
    fi
    log WARN "Upgrading bash/libc/termux-tools can murder this session. If the window dies, reopen Termux and re-run. Already-installed packages will be skipped."
    pkg upgrade -y 2>&1 | tee -a "$LOG_FILE" || log WARN "pkg upgrade reported issues, continuing"
}

install_selected_sys() {
    local want="$1"
    if [ "$want" = "all" ]; then
        local cat
        for cat in "${SYS_CATEGORY_ORDER[@]}"; do
            install_sys_category "$cat"
        done
        return
    fi
    if [ -z "${SYS_CATEGORIES[$want]+x}" ]; then
        log ERROR "Unknown sys category: ${want}"
        return 1
    fi
    install_sys_category "$want"
}

install_selected_py() {
    local want="$1"
    if [ "$want" = "all" ]; then
        local cat
        for cat in "${PY_CATEGORY_ORDER[@]}"; do
            install_py_category "$cat"
        done
        return
    fi
    if [ -z "${PY_CATEGORIES[$want]+x}" ]; then
        log ERROR "Unknown py category: ${want}"
        return 1
    fi
    install_py_category "$want"
}

setup_dirs() {
    section "Project directories"
    if $DRY_RUN; then
        log INFO "[DRY RUN] Would create: ${PROJECT_DIRS[*]}"
        return 0
    fi
    mkdir -p "${PROJECT_DIRS[@]}"
    log OK "Directories ready."
}

setup_storage() {
    section "Termux storage"
    if $DRY_RUN; then
        log INFO "[DRY RUN] Would run termux-setup-storage"
        return 0
    fi
    termux-setup-storage 2>>"$LOG_FILE" || log WARN "termux-setup-storage skipped/failed (non-fatal)"
}

setup_aliases() {
    section "Shell aliases"
    if grep -q "# JediSec Termux Settings" "$HOME/.bashrc" 2>/dev/null; then
        log INFO "Aliases already present, skipping."
        return 0
    fi
    if $DRY_RUN; then
        log INFO "[DRY RUN] Would append alias block to ~/.bashrc"
        return 0
    fi
    cat >> "$HOME/.bashrc" <<'EOF'

# JediSec Termux Settings
export EDITOR=nano
export PAGER=less
export PATH="$HOME/.local/bin:$PATH"
alias ll="ls -lah"
alias gs="git status"
alias py="python"
alias pipup="python -m pip install --upgrade pip"
alias jupdate="pkg update -y"
alias jboot="bash $HOME/jedisec-termux-bootstrap/jedisec-termux-bootstrap.sh"
EOF
    log OK "Aliases added to ~/.bashrc"
}

health_check() {
    section "Health check"
    local ok=0 bad=0
    local bins=(bash git curl wget python pip pkg jq)
    local b
    for b in "${bins[@]}"; do
        if command_exists "$b"; then
            log OK "cmd ${b}"
            ((ok++)) || true
        else
            log ERROR "missing ${b}"
            ((bad++)) || true
        fi
    done

    if python -c "import requests,httpx,rich" 2>/dev/null; then
        log OK "python imports: requests httpx rich"
        ((ok++)) || true
    else
        log WARN "python AI/core imports incomplete (ok if you have not installed py:core/ai yet)"
        ((bad++)) || true
    fi

    if python -c "import chromadb" 2>/dev/null; then
        log WARN "chromadb is installed. That package is hostile on Termux. You probably do not want it."
    fi
    if command_exists ollama; then
        log WARN "ollama binary present. Daemon on a phone is usually a bad time."
    fi

    log INFO "Health: ${ok} ok, ${bad} missing/warn"
}

write_summary() {
    local failed_joined="${FAILED_ITEMS[*]:-}"
    cat > "$SUMMARY_FILE" <<EOF
JediSec Termux Bootstrap ${VERSION}
time=$(date -Iseconds)
installed=${COUNT_INSTALLED}
skipped=${COUNT_SKIPPED}
failed=${COUNT_FAILED}
failed_items=${failed_joined}
dry_run=${DRY_RUN}
log=${LOG_FILE}
EOF
    cat > "$JSON_SUMMARY_FILE" <<EOF
{"version":"${VERSION}","installed":${COUNT_INSTALLED},"skipped":${COUNT_SKIPPED},"failed":${COUNT_FAILED},"failed_items":[$(printf '"%s",' "${FAILED_ITEMS[@]:-}" | sed 's/,$//')],"dry_run":${DRY_RUN},"log":"${LOG_FILE}"}
EOF
    if ! $JSON_OUTPUT; then
        echo
        echo -e "${BOLD}Summary${NC}  installed=${COUNT_INSTALLED}  skipped=${COUNT_SKIPPED}  failed=${COUNT_FAILED}"
        [ "${COUNT_FAILED}" -gt 0 ] && echo -e "${RED}Failed: ${failed_joined}${NC}"
        echo "Wrote ${SUMMARY_FILE}"
    else
        cat "$JSON_SUMMARY_FILE"
    fi
}

self_update() {
    section "Self-update"
    local script_path script_dir
    script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    script_dir=$(dirname "$script_path")
    if ! command_exists git; then
        log ERROR "git not installed"
        return 1
    fi
    if [ ! -d "${script_dir}/.git" ]; then
        log WARN "Script is not inside a git clone. Clone ${REPO_URL}"
        return 1
    fi
    if $DRY_RUN; then
        log INFO "[DRY RUN] Would git pull in ${script_dir}"
        return 0
    fi
    if git -C "$script_dir" pull --ff-only; then
        log OK "Updated."
    else
        log ERROR "git pull failed"
        return 1
    fi
}

phone_profile() {
    pkg_update
    install_selected_sys core
    install_selected_sys dev
    install_selected_sys android
    install_selected_py core
    install_selected_py ai
    setup_dirs
    setup_storage
    setup_aliases
    health_check
}

full_profile() {
    pkg_update
    install_selected_sys all
    install_selected_py all
    setup_dirs
    setup_storage
    setup_aliases
    health_check
}

usage() {
    cat <<EOF
JediSec Termux Bootstrap ${VERSION}
Android / Termux only.

Usage:
  bash jedisec-termux-bootstrap.sh [options]

Options:
  --phone              Recommended after a wipe: core + dev + android + py core/ai + dirs
  --full               All phone-safe sys + py categories (NOT rust/clang)
  --upgrade            Also run pkg upgrade -y (can kill the session)
  --sys=CATEGORY|all   core dev data media network osint android
  --py=CATEGORY|all    core web data ai security db osint
  --heavy              Install clang cmake ninja rust golang (opt-in, RAM hungry)
  --dirs               Project dirs + aliases + storage
  --health             Health check only
  --update-self        git pull this repo
  --dry-run            Preview
  --json               JSON summary to stdout
  --help

AI note:
  py:ai installs openai + httpx only.
  ollama and chromadb are intentionally absent. They break Termux.

Examples:
  bash jedisec-termux-bootstrap.sh --phone
  bash jedisec-termux-bootstrap.sh --sys=core --py=ai
  bash jedisec-termux-bootstrap.sh --full --dry-run
EOF
}

interactive_menu() {
    header
    echo "1) Phone profile (recommended)"
    echo "2) Full phone-safe"
    echo "3) Health check"
    echo "4) Heavy toolchain (clang/rust/go)"
    echo "5) Quit"
    echo
    local choice
    read -r -p "Select: " choice
    case "$choice" in
        1) phone_profile ;;
        2) full_profile ;;
        3) health_check ;;
        4) install_sys_category "$HEAVY_CATEGORY" ;;
        *) log INFO "Bye." ; return 0 ;;
    esac
}

die_if_not_termux
rotate_logs
load_config_override

DO_UPGRADE=false
DO_PHONE=false
DO_FULL=false
DO_DIRS=false
DO_HEALTH=false
DO_SELF=false
DO_HEAVY=false
SYS_WANT=""
PY_WANT=""
HAVE_FLAG=false

while [ $# -gt 0 ]; do
    case "$1" in
        --phone)        DO_PHONE=true; HAVE_FLAG=true ;;
        --full)         DO_FULL=true; HAVE_FLAG=true ;;
        --upgrade)      DO_UPGRADE=true; HAVE_FLAG=true ;;
        --sys=*)        SYS_WANT="${1#--sys=}"; HAVE_FLAG=true ;;
        --py=*)         PY_WANT="${1#--py=}"; HAVE_FLAG=true ;;
        --heavy)        DO_HEAVY=true; HAVE_FLAG=true ;;
        --dirs)         DO_DIRS=true; HAVE_FLAG=true ;;
        --health|--health-check) DO_HEALTH=true; HAVE_FLAG=true ;;
        --update-self)  DO_SELF=true; HAVE_FLAG=true ;;
        --dry-run)      DRY_RUN=true ;;
        --json)         JSON_OUTPUT=true ;;
        --help|-h)      usage; exit 0 ;;
        *)              echo "Unknown flag: $1"; usage; exit 1 ;;
    esac
    shift
done

header

if ! $HAVE_FLAG; then
    if [ -t 0 ] && ! $JSON_OUTPUT; then
        interactive_menu
        write_summary
        exit 0
    fi
    usage
    exit 1
fi

$DO_SELF && self_update
$DO_UPGRADE && pkg_upgrade
$DO_PHONE && phone_profile
$DO_FULL && full_profile
[ -n "$SYS_WANT" ] && install_selected_sys "$SYS_WANT"
[ -n "$PY_WANT" ] && install_selected_py "$PY_WANT"
$DO_HEAVY && install_sys_category "$HEAVY_CATEGORY"
$DO_DIRS && setup_dirs && setup_storage && setup_aliases
$DO_HEALTH && health_check

write_summary
exit 0
