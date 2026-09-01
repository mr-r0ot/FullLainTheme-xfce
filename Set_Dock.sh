#!/usr/bin/env bash
#
# Set_Dock.sh
# Debian / Ubuntu family - system-wide Plank dock setup
#
# Applies to:
#   - Existing interactive users
#   - Future users through GSettings defaults
#   - Global desktop autostart
#
# The script intentionally does NOT replace users' pinned launchers.

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

# ============================================================
# Configuration
# ============================================================

readonly DOCK_NAME="dock1"
readonly PLANK_SCHEMA="net.launchpad.plank.dock.settings"
readonly PLANK_PATH="/net/launchpad/plank/docks/${DOCK_NAME}/"
readonly PLANK_SCHEMA_SPEC="${PLANK_SCHEMA}:${PLANK_PATH}"

readonly THEME_NAME="SystemModern"
readonly THEME_DIR="/usr/share/plank/themes/${THEME_NAME}"
readonly THEME_FILE="${THEME_DIR}/dock.theme"

readonly GSCHEMA_DIR="/usr/share/glib-2.0/schemas"
readonly GSCHEMA_OVERRIDE="${GSCHEMA_DIR}/90-system-plank.gschema.override"

readonly AUTOSTART_FILE="/etc/xdg/autostart/system-plank.desktop"
readonly STARTER_FILE="/usr/local/bin/plank-system-start"
readonly BACKUP_ROOT="/var/backups/set-dock"

readonly ICON_SIZE=52
readonly ZOOM_PERCENT=140
readonly HIDE_MODE="window-dodge"
readonly HIDE_DELAY=180
readonly UNHIDE_DELAY=80

BACKUP_DIR=""
APT_UPDATED=0

# ============================================================
# Logging / error handling
# ============================================================

log()  { printf '\n[+] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

on_error() {
    local code=$?
    local line=${1:-unknown}
    local failed_command=${2:-unknown}
    printf '\n[ERROR] Set_Dock.sh failed at line %s (exit code %s).\n' \
        "$line" "$code" >&2
    printf '[ERROR] Command: %s\n' "$failed_command" >&2
    if [[ -n "${BACKUP_DIR:-}" ]]; then
        printf '[ERROR] Backup: %s\n' "$BACKUP_DIR" >&2
    fi
    exit "$code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# ============================================================
# Preconditions
# ============================================================

[[ "${EUID}" -eq 0 ]] || die \
    "Run as root: sudo bash Set_Dock.sh"

[[ -r /etc/os-release ]] || die "/etc/os-release was not found."
# shellcheck disable=SC1091
source /etc/os-release

if [[ " ${ID:-} ${ID_LIKE:-} " != *" debian "* &&
      " ${ID:-} ${ID_LIKE:-} " != *" ubuntu "* ]]; then
    die "This script is intended for Debian/Ubuntu-based systems. Detected: ${PRETTY_NAME:-unknown}"
fi

command -v apt-get >/dev/null 2>&1 || die "apt-get was not found."
command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query was not found."
command -v runuser >/dev/null 2>&1 || die "runuser was not found."

log "Detected system"
printf '    %s\n' "${PRETTY_NAME:-Debian/Ubuntu based system}"

# ============================================================
# Package installation
# ============================================================

apt_update_once() {
    if (( APT_UPDATED == 0 )); then
        apt-get update
        APT_UPDATED=1
    fi
}

package_installed() {
    dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | \
        grep -qx 'install ok installed'
}

ensure_packages() {
    local -a packages=(
        plank
        libglib2.0-bin
        dconf-cli
        dbus-daemon
        procps
    )
    local -a missing=()
    local pkg

    for pkg in "${packages[@]}"; do
        if ! package_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        ok "Required packages are already installed"
        return 0
    fi

    log "Installing required packages"
    apt_update_once

    # Ubuntu keeps Plank in Universe. Enable it only when Plank has no
    # install candidate and the host is Ubuntu-derived.
    if ! apt-cache policy plank 2>/dev/null | grep -q 'Candidate: [^()]'; then
        if [[ " ${ID:-} ${ID_LIKE:-} " == *" ubuntu "* ]]; then
            if ! command -v add-apt-repository >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
            fi
            log "Enabling Ubuntu Universe repository for Plank"
            add-apt-repository -y universe
            apt-get update
            APT_UPDATED=1
        fi
    fi

    apt-cache policy plank 2>/dev/null | grep -q 'Candidate: [^()]' || \
        die "The 'plank' package has no install candidate in the configured repositories."

    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    ok "Required packages installed"
}

ensure_packages

command -v plank >/dev/null 2>&1 || die "Plank was installed but /usr/bin/plank is unavailable."
command -v gsettings >/dev/null 2>&1 || die "gsettings is unavailable."
command -v glib-compile-schemas >/dev/null 2>&1 || die "glib-compile-schemas is unavailable."
command -v dconf >/dev/null 2>&1 || die "dconf is unavailable."
command -v dbus-run-session >/dev/null 2>&1 || die "dbus-run-session is unavailable."
command -v pgrep >/dev/null 2>&1 || die "pgrep is unavailable."

if ! gsettings list-relocatable-schemas | grep -qx "$PLANK_SCHEMA"; then
    die "The Plank GSettings schema '${PLANK_SCHEMA}' is not installed."
fi

# ============================================================
# Backup helpers
# ============================================================

log "Creating backup"
mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"
BACKUP_DIR="$(mktemp -d "${BACKUP_ROOT}/run-$(date '+%Y%m%d-%H%M%S')-XXXXXX")"
chmod 700 "$BACKUP_DIR"

backup_path() {
    local path=$1
    local relative
    local destination

    [[ -e "$path" || -L "$path" ]] || return 0

    relative="${path#/}"
    destination="${BACKUP_DIR}/${relative}"
    mkdir -p "$(dirname "$destination")"
    cp -a -- "$path" "$destination"
}

backup_path "$THEME_DIR"
backup_path "$GSCHEMA_OVERRIDE"
backup_path "$AUTOSTART_FILE"
backup_path "$STARTER_FILE"

ok "Backup created at ${BACKUP_DIR}"

# ============================================================
# System-wide Plank theme
# ============================================================

log "Installing modern Plank theme"
mkdir -p "$THEME_DIR"

THEME_TMP="$(mktemp "${THEME_DIR}/.dock.theme.XXXXXX")"
cat > "$THEME_TMP" <<'THEME'
[PlankTheme]
TopRoundness=18
BottomRoundness=18
LineWidth=1
OuterStrokeColor=255;;255;;255;;35
FillStartColor=28;;28;;32;;218
FillEndColor=15;;15;;19;;228
InnerStrokeColor=255;;255;;255;;18

[PlankDockTheme]
HorizPadding=2
TopPadding=1.2
BottomPadding=1.5
ItemPadding=2
IndicatorSize=5
IconShadowSize=1
UrgentBounceHeight=1.5
LaunchBounceHeight=0.55
FadeOpacity=1
ClickTime=180
UrgentBounceTime=550
LaunchBounceTime=450
ActiveTime=160
SlideTime=220
FadeTime=180
HideTime=220
GlowSize=24
GlowTime=10000
GlowPulseTime=1800
UrgentHueShift=150
ItemMoveTime=220
CascadeHide=true

[PlankDrawingDockTheme]
HorizPadding=2
ItemPadding=2
CascadeHide=true
THEME

chmod 644 "$THEME_TMP"
mv -f -- "$THEME_TMP" "$THEME_FILE"
chmod 755 "$THEME_DIR"

[[ -s "$THEME_FILE" ]] || die "Plank theme file was not created."
grep -q '^\[PlankTheme\]$' "$THEME_FILE" || die "Invalid Plank theme: missing [PlankTheme]."
grep -q '^\[PlankDockTheme\]$' "$THEME_FILE" || die "Invalid Plank theme: missing [PlankDockTheme]."

ok "Theme installed: ${THEME_NAME}"

# ============================================================
# GSettings defaults for all/future users
# ============================================================

log "Configuring system-wide Plank defaults"

cat > "$GSCHEMA_OVERRIDE" <<EOF_OVERRIDE
[${PLANK_SCHEMA}]
position='bottom'
alignment='center'
items-alignment='center'
hide-mode='${HIDE_MODE}'
hide-delay=${HIDE_DELAY}
unhide-delay=${UNHIDE_DELAY}
icon-size=${ICON_SIZE}
theme='${THEME_NAME}'
zoom-enabled=true
zoom-percent=${ZOOM_PERCENT}
tooltips-enabled=true
lock-items=false
pressure-reveal=false
pinned-only=false
auto-pinning=true
show-dock-item=false
current-workspace-only=false
offset=0
EOF_OVERRIDE

chmod 644 "$GSCHEMA_OVERRIDE"
glib-compile-schemas "$GSCHEMA_DIR"

# Validate the compiled schema/defaults without touching any user database.
gsettings range "$PLANK_SCHEMA_SPEC" hide-mode >/dev/null
gsettings range "$PLANK_SCHEMA_SPEC" position >/dev/null

ok "System-wide defaults configured"

# ============================================================
# Global autostart
# ============================================================

log "Configuring global Plank autostart"

cat > "$STARTER_FILE" <<'EOF_STARTER'
#!/bin/sh
# Start Plank once per graphical X11 session.

command -v plank >/dev/null 2>&1 || exit 0

# Plank 0.11 is an X11/libwnck dock. Do not start it in a pure Wayland
# session where window tracking is not reliable.
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    exit 0
fi

[ -n "${DISPLAY:-}" ] || exit 0

if command -v pgrep >/dev/null 2>&1 && \
   pgrep -u "$(id -u)" -x plank >/dev/null 2>&1; then
    exit 0
fi

exec plank
EOF_STARTER
chmod 755 "$STARTER_FILE"

mkdir -p "$(dirname "$AUTOSTART_FILE")"
cat > "$AUTOSTART_FILE" <<EOF_AUTOSTART
[Desktop Entry]
Type=Application
Version=1.0
Name=Plank Dock
Comment=Modern system Plank dock
Exec=${STARTER_FILE}
TryExec=${STARTER_FILE}
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-MATE-Autostart-enabled=true
EOF_AUTOSTART
chmod 644 "$AUTOSTART_FILE"

ok "Global autostart configured"

# ============================================================
# Per-user settings
# ============================================================

# Write only Plank preferences. Pinned launchers (dock-items) are deliberately
# left unchanged so current users keep their own application layout.

apply_user_settings_command() {
    cat <<EOF_SETTINGS
set -eu
spec='${PLANK_SCHEMA_SPEC}'

has_key() {
    gsettings list-keys "\$spec" | grep -Fxq "\$1"
}

set_key() {
    key=\$1
    value=\$2
    if has_key "\$key"; then
        gsettings set "\$spec" "\$key" "\$value"
    fi
}

set_key position "'bottom'"
set_key alignment "'center'"
set_key items-alignment "'center'"
set_key hide-mode "'${HIDE_MODE}'"
set_key hide-delay '${HIDE_DELAY}'
set_key unhide-delay '${UNHIDE_DELAY}'
set_key icon-size '${ICON_SIZE}'
set_key theme "'${THEME_NAME}'"
set_key zoom-enabled 'true'
set_key zoom-percent '${ZOOM_PERCENT}'
set_key tooltips-enabled 'true'
set_key lock-items 'false'
set_key pressure-reveal 'false'
set_key pinned-only 'false'
set_key auto-pinning 'true'
set_key show-dock-item 'false'
set_key current-workspace-only 'false'
set_key offset '0'

# Verify the critical appearance/behavior keys.
[ "\$(gsettings get "\$spec" theme)" = "'${THEME_NAME}'" ]
[ "\$(gsettings get "\$spec" position)" = "'bottom'" ]
[ "\$(gsettings get "\$spec" icon-size)" = '${ICON_SIZE}' ]
[ "\$(gsettings get "\$spec" zoom-enabled)" = 'true' ]
[ "\$(gsettings get "\$spec" zoom-percent)" = '${ZOOM_PERCENT}' ]
EOF_SETTINGS
}

backup_user_plank() {
    local user=$1
    local uid=$2
    local home=$3
    local runtime="/run/user/${uid}"
    local user_backup="${BACKUP_DIR}/users/${user}"

    mkdir -p "$user_backup"

    if [[ -S "${runtime}/bus" ]]; then
        if runuser -u "$user" -- \
            env HOME="$home" \
                XDG_RUNTIME_DIR="$runtime" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime}/bus" \
                dconf dump "$PLANK_PATH" > "${user_backup}/plank.dconf" 2>/dev/null; then
            :
        else
            : > "${user_backup}/plank.dconf"
        fi
    else
        if runuser -u "$user" -- \
            env HOME="$home" \
                dbus-run-session -- \
                dconf dump "$PLANK_PATH" > "${user_backup}/plank.dconf" 2>/dev/null; then
            :
        else
            : > "${user_backup}/plank.dconf"
        fi
    fi

    chmod 600 "${user_backup}/plank.dconf"
}

apply_user_plank() {
    local user=$1
    local uid=$2
    local home=$3
    local runtime="/run/user/${uid}"
    local settings_script

    [[ -d "$home" ]] || return 0
    [[ "$home" = /* ]] || return 0
    [[ "$home" != "/" ]] || return 0

    backup_user_plank "$user" "$uid" "$home"

    settings_script="$(apply_user_settings_command)"

    if [[ -S "${runtime}/bus" ]]; then
        printf '%s\n' "$settings_script" | \
            runuser -u "$user" -- \
                env HOME="$home" \
                    XDG_RUNTIME_DIR="$runtime" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime}/bus" \
                    sh
    else
        printf '%s\n' "$settings_script" | \
            runuser -u "$user" -- \
                env HOME="$home" \
                    dbus-run-session -- sh
    fi
}

# login.defs is the authoritative source for the normal-user UID range.
UID_MIN_VALUE="$(awk '$1 == "UID_MIN" {print $2; exit}' /etc/login.defs 2>/dev/null || true)"
UID_MAX_VALUE="$(awk '$1 == "UID_MAX" {print $2; exit}' /etc/login.defs 2>/dev/null || true)"
[[ "$UID_MIN_VALUE" =~ ^[0-9]+$ ]] || UID_MIN_VALUE=1000
[[ "$UID_MAX_VALUE" =~ ^[0-9]+$ ]] || UID_MAX_VALUE=60000

log "Applying Plank settings to existing users"
USER_COUNT=0

while IFS=: read -r username _ uid gid _ home shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    [[ "$gid" =~ ^[0-9]+$ ]] || continue

    if (( uid < UID_MIN_VALUE || uid > UID_MAX_VALUE )); then
        continue
    fi

    case "$shell" in
        */nologin|*/false)
            continue
            ;;
    esac

    [[ -d "$home" ]] || continue

    apply_user_plank "$username" "$uid" "$home"
    USER_COUNT=$((USER_COUNT + 1))
    printf '    -> %s\n' "$username"
done < /etc/passwd

# Root is covered by the global default. If root already has explicit Plank
# values, normalize those too so "all users" is literal without changing
# unrelated root settings.
if [[ -d /root ]]; then
    apply_user_plank root 0 /root
    printf '    -> root\n'
fi

ok "Configured ${USER_COUNT} normal user account(s) plus root"

# ============================================================
# Final verification
# ============================================================

log "Final verification"

[[ -x /usr/bin/plank ]] || die "/usr/bin/plank is not executable."
[[ -f "$THEME_FILE" ]] || die "Theme file is missing."
[[ -f "$GSCHEMA_OVERRIDE" ]] || die "GSettings override is missing."
[[ -x "$STARTER_FILE" ]] || die "Autostart helper is not executable."
[[ -f "$AUTOSTART_FILE" ]] || die "Global autostart file is missing."

grep -q "^theme='${THEME_NAME}'$" "$GSCHEMA_OVERRIDE" || \
    die "Theme default verification failed."
grep -q "^zoom-enabled=true$" "$GSCHEMA_OVERRIDE" || \
    die "Zoom default verification failed."
grep -q "^zoom-percent=${ZOOM_PERCENT}$" "$GSCHEMA_OVERRIDE" || \
    die "Zoom percentage verification failed."
grep -q "^hide-mode='${HIDE_MODE}'$" "$GSCHEMA_OVERRIDE" || \
    die "Hide mode verification failed."

PLANK_VERSION="$(plank --version 2>/dev/null | head -n1 || true)"

printf '\n'
printf '%s\n' '============================================================'
printf '%s\n' ' Plank system dock configured successfully'
printf '%s\n' '============================================================'
printf ' Dock          : Plank %s\n' "${PLANK_VERSION:-installed}"
printf ' Position      : Bottom / centered\n'
printf ' Icon size     : %s px\n' "$ICON_SIZE"
printf ' Hover zoom    : %s%%\n' "$ZOOM_PERCENT"
printf ' Hide mode     : %s\n' "$HIDE_MODE"
printf ' Theme         : %s\n' "$THEME_NAME"
printf ' Autostart     : %s\n' "$AUTOSTART_FILE"
printf ' Backup        : %s\n' "$BACKUP_DIR"
printf '%s\n' '============================================================'
printf '\n'
printf '%s\n' 'Existing X11 sessions may need Plank to be restarted or the user to log out/in.'
printf '%s\n' 'Pinned application launchers were preserved.'
printf '%s\n' 'Pure Wayland sessions are intentionally skipped because Plank 0.11 is X11/libwnck based.'
