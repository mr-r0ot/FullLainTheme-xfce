#!/usr/bin/env bash
#
# Set_IconTheme_ideal.sh
# Install Papirus-Dark and configure it safely on Debian-based systems.
#
# Design goals:
#   - Prefer the distribution package manager.
#   - Never overwrite unrelated GTK/XFCE settings.
#   - Preserve existing ownership and directory permissions.
#   - Use atomic configuration-file updates.
#   - Back up every existing file before changing it.
#   - Apply XFCE settings live when an accessible session exists.
#   - Remain idempotent across repeated runs.
#
# Usage:
#   sudo bash Set_IconTheme_ideal.sh
#
# Optional installation method:
#   INSTALL_METHOD=apt      sudo bash Set_IconTheme_ideal.sh   # default/safest
#   INSTALL_METHOD=upstream sudo bash Set_IconTheme_ideal.sh   # official Papirus installer
#
# Optional upstream tag/branch (used only with INSTALL_METHOD=upstream):
#   PAPIRUS_TAG=20250501 INSTALL_METHOD=upstream sudo -E bash Set_IconTheme_ideal.sh
#

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

readonly ICON_THEME="Papirus-Dark"
readonly ICON_DIR="/usr/share/icons/${ICON_THEME}"
readonly BACKUP_ROOT="/var/backups/set-icontheme"
readonly INSTALL_METHOD="${INSTALL_METHOD:-apt}"
readonly PAPIRUS_TAG="${PAPIRUS_TAG:-master}"
readonly UPSTREAM_INSTALLER_URL="https://raw.githubusercontent.com/PapirusDevelopmentTeam/papirus-icon-theme/master/install.sh"
readonly XFCE_SYSTEM_FILE="/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"

BACKUP_DIR=""
APT_UPDATED=0

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_CYAN=$'\033[36m'
    readonly C_BOLD=$'\033[1m'
else
    readonly C_RESET=""
    readonly C_RED=""
    readonly C_GREEN=""
    readonly C_YELLOW=""
    readonly C_BLUE=""
    readonly C_CYAN=""
    readonly C_BOLD=""
fi

log()     { printf '%b[INFO]%b %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
success() { printf '%b[ OK ]%b %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn()    { printf '%b[WARN]%b %s\n'  "$C_YELLOW" "$C_RESET" "$*"; }
error()   { printf '%b[ERROR]%b %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
step()    { printf '\n%b==>%b %b%s%b\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
die()     { error "$*"; exit 1; }

on_error() {
    local exit_code=$?
    local failed_command=${BASH_COMMAND:-unknown}
    local failed_line=${BASH_LINENO[0]:-unknown}
    trap - ERR
    error "Operation failed at line ${failed_line}."
    error "Command: ${failed_command}"
    error "Exit code: ${exit_code}"
    if [[ -n "$BACKUP_DIR" ]]; then
        error "Backups created before the failure are in: ${BACKUP_DIR}"
    fi
    exit "$exit_code"
}
trap on_error ERR

# -----------------------------------------------------------------------------
# Preconditions
# -----------------------------------------------------------------------------
[[ ${EUID} -eq 0 ]] || die "Run as root: sudo bash Set_IconTheme_ideal.sh"
[[ -r /etc/os-release ]] || die "/etc/os-release was not found."

# shellcheck disable=SC1091
source /etc/os-release

os_tokens=" ${ID:-} ${ID_LIKE:-} "
if [[ "$os_tokens" != *" debian "* && "$os_tokens" != *" ubuntu "* ]]; then
    die "This script supports Debian-based systems. Detected: ${PRETTY_NAME:-unknown}"
fi

case "$INSTALL_METHOD" in
    apt|upstream) ;;
    *) die "INSTALL_METHOD must be 'apt' or 'upstream'." ;;
esac

command -v apt-get >/dev/null 2>&1 || die "apt-get is required on this Debian-based system."
command -v apt-cache >/dev/null 2>&1 || die "apt-cache is required on this Debian-based system."

step "Detected operating system"
success "${PRETTY_NAME:-Debian-based Linux}"

# -----------------------------------------------------------------------------
# Package helpers
# -----------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

apt_update_once() {
    if (( APT_UPDATED == 0 )); then
        log "Refreshing APT package metadata..."
        apt-get update
        APT_UPDATED=1
    fi
}

install_package_for_command() {
    local command_name=$1
    local package_name=$2

    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi

    apt_update_once
    log "Installing dependency: ${package_name}"
    apt-get install -y --no-install-recommends "$package_name"
    command -v "$command_name" >/dev/null 2>&1 || \
        die "Package ${package_name} was installed, but ${command_name} is still unavailable."
}

step "Checking dependencies"
install_package_for_command python3 python3-minimal
install_package_for_command install coreutils
install_package_for_command getent libc-bin

if [[ "$INSTALL_METHOD" == "upstream" ]]; then
    install_package_for_command curl curl
    install_package_for_command wget wget
    install_package_for_command tar tar
fi

install_package_for_command awk mawk
install_package_for_command sed sed
install_package_for_command grep grep
success "Required tools are available."

# -----------------------------------------------------------------------------
# Backup
# -----------------------------------------------------------------------------
step "Creating backup directory"
mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"
BACKUP_DIR="${BACKUP_ROOT}/$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
success "Backup directory: ${BACKUP_DIR}"

backup_file() {
    local file=$1
    local relative target

    [[ -f "$file" || -L "$file" ]] || return 0

    relative=${file#/}
    target="${BACKUP_DIR}/${relative}"
    mkdir -p "$(dirname "$target")"

    # Back up a path only once per run, preserving the original pre-run state.
    if [[ ! -e "$target" && ! -L "$target" ]]; then
        cp -a -- "$file" "$target"
        log "Backed up: ${file}"
    fi
}

# -----------------------------------------------------------------------------
# Atomic, non-destructive config editors
# -----------------------------------------------------------------------------
# Update one key in a GKeyFile-style [Settings] INI file while preserving
# unrelated keys, comments, blank lines and section ordering.
set_ini_setting() {
    local file=$1
    local key=$2
    local value=$3
    local mode=${4:-644}
    local owner_uid=${5:-}
    local owner_gid=${6:-}

    backup_file "$file"

    python3 - "$file" "$key" "$value" "$mode" "$owner_uid" "$owner_gid" <<'PY'
import os
import re
import stat
import sys
import tempfile

path, key, value, mode_s, uid_s, gid_s = sys.argv[1:]
mode = int(mode_s, 8)
uid = int(uid_s) if uid_s else None
gid = int(gid_s) if gid_s else None

# For per-user files, drop root privileges before touching user-controlled
# paths. This prevents symlink/race attacks from turning the editor into an
# arbitrary root file writer.
dropped = uid is not None and gid is not None and uid != 0
if dropped:
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)

# Preserve an existing file's mode; the supplied mode is only the creation
# default. This avoids silently changing a user's or administrator's policy.
try:
    mode = stat.S_IMODE(os.stat(path).st_mode)
except FileNotFoundError:
    pass

try:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []
except UnicodeDecodeError as exc:
    raise SystemExit(f"Refusing to modify non-UTF-8 INI file {path}: {exc}")

section_re = re.compile(r"^\s*\[([^]]+)\]\s*(?:[#;].*)?$")
key_re = re.compile(r"^(\s*)" + re.escape(key) + r"\s*=.*$")

settings_start = None
settings_end = len(lines)
for i, line in enumerate(lines):
    m = section_re.match(line.rstrip("\n"))
    if not m:
        continue
    if settings_start is None and m.group(1).strip().lower() == "settings":
        settings_start = i
        continue
    if settings_start is not None:
        settings_end = i
        break

new_line = f"{key}={value}\n"

if settings_start is None:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    if lines and lines[-1].strip():
        lines.append("\n")
    lines.extend(["[Settings]\n", new_line])
else:
    matches = []
    for i in range(settings_start + 1, settings_end):
        if key_re.match(lines[i].rstrip("\n")):
            matches.append(i)

    if matches:
        first = matches[0]
        indent = key_re.match(lines[first].rstrip("\n")).group(1)
        lines[first] = f"{indent}{key}={value}\n"
        # Duplicate definitions of the exact key in [Settings] are removed so
        # the resulting value is deterministic.
        for i in reversed(matches[1:]):
            del lines[i]
    else:
        insert_at = settings_end
        lines.insert(insert_at, new_line)

directory = os.path.dirname(path) or "."
os.makedirs(directory, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".set-icontheme.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.writelines(lines)
        f.flush()
        os.fsync(f.fileno())

    os.chmod(tmp, mode)
    if not dropped and uid is not None and gid is not None:
        os.chown(tmp, uid, gid)
    os.replace(tmp, path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
}

# Update a GTK2 rc key without replacing any unrelated rc content.
set_gtk2_setting() {
    local file=$1
    local value=$2
    local mode=${3:-644}
    local owner_uid=${4:-}
    local owner_gid=${5:-}

    backup_file "$file"

    python3 - "$file" "$value" "$mode" "$owner_uid" "$owner_gid" <<'PY'
import os
import re
import stat
import sys
import tempfile

path, value, mode_s, uid_s, gid_s = sys.argv[1:]
mode = int(mode_s, 8)
uid = int(uid_s) if uid_s else None
gid = int(gid_s) if gid_s else None

# For per-user files, drop root privileges before touching user-controlled
# paths. This prevents symlink/race attacks from turning the editor into an
# arbitrary root file writer.
dropped = uid is not None and gid is not None and uid != 0
if dropped:
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)

# Preserve an existing file's mode; the supplied mode is only the creation
# default. This avoids silently changing a user's or administrator's policy.
try:
    mode = stat.S_IMODE(os.stat(path).st_mode)
except FileNotFoundError:
    pass

try:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []
except UnicodeDecodeError as exc:
    raise SystemExit(f"Refusing to modify non-UTF-8 GTK2 rc file {path}: {exc}")

pattern = re.compile(r'^(\s*)gtk-icon-theme-name\s*=.*$')
matches = [i for i, line in enumerate(lines) if pattern.match(line.rstrip("\n"))]
replacement = f'gtk-icon-theme-name = "{value}"\n'

if matches:
    first = matches[0]
    indent = pattern.match(lines[first].rstrip("\n")).group(1)
    lines[first] = f'{indent}gtk-icon-theme-name = "{value}"\n'
    for i in reversed(matches[1:]):
        del lines[i]
else:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    if lines and lines[-1].strip():
        lines.append("\n")
    lines.append(replacement)

directory = os.path.dirname(path) or "."
os.makedirs(directory, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".set-icontheme.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.writelines(lines)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    if not dropped and uid is not None and gid is not None:
        os.chown(tmp, uid, gid)
    os.replace(tmp, path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
}

# Merge /Net/IconThemeName into an Xfce xsettings.xml file. If an existing XML
# file is malformed, fail safely and leave it untouched; its backup remains.
set_xfce_xml_setting() {
    local file=$1
    local mode=${2:-600}
    local owner_uid=${3:-}
    local owner_gid=${4:-}

    backup_file "$file"

    python3 - "$file" "$ICON_THEME" "$mode" "$owner_uid" "$owner_gid" <<'PY'
import os
import stat
import sys
import tempfile
import xml.etree.ElementTree as ET

path, theme, mode_s, uid_s, gid_s = sys.argv[1:]
mode = int(mode_s, 8)
uid = int(uid_s) if uid_s else None
gid = int(gid_s) if gid_s else None

dropped = uid is not None and gid is not None and uid != 0
if dropped:
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)

try:
    mode = stat.S_IMODE(os.stat(path).st_mode)
except FileNotFoundError:
    pass

if os.path.exists(path):
    try:
        parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
        tree = ET.parse(path, parser=parser)
        root = tree.getroot()
    except ET.ParseError as exc:
        raise SystemExit(f"Malformed XFCE XML; refusing to overwrite {path}: {exc}")

    if root.tag != "channel":
        raise SystemExit(f"Unexpected XFCE XML root in {path}: {root.tag!r}")
else:
    root = ET.Element("channel", {"name": "xsettings", "version": "1.0"})
    tree = ET.ElementTree(root)

net = next((p for p in root.findall("./property") if p.get("name") == "Net"), None)
if net is None:
    net = ET.Element("property", {"name": "Net", "type": "empty"})
    root.insert(0, net)
else:
    net.set("type", "empty")

icon = next((p for p in net.findall("./property") if p.get("name") == "IconThemeName"), None)
if icon is None:
    icon = ET.SubElement(net, "property", {"name": "IconThemeName"})
icon.set("type", "string")
icon.set("value", theme)

directory = os.path.dirname(path) or "."
os.makedirs(directory, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".set-icontheme.", dir=directory)
os.close(fd)
try:
    tree.write(tmp, encoding="UTF-8", xml_declaration=True)
    with open(tmp, "rb+") as f:
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    if not dropped and uid is not None and gid is not None:
        os.chown(tmp, uid, gid)
    os.replace(tmp, path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
}

# -----------------------------------------------------------------------------
# Papirus installation
# -----------------------------------------------------------------------------
install_papirus_apt() {
    apt_update_once

    if ! apt-cache show papirus-icon-theme >/dev/null 2>&1; then
        die "papirus-icon-theme is unavailable in the configured APT repositories. Use INSTALL_METHOD=upstream explicitly if you accept the official upstream installer."
    fi

    log "Installing/updating papirus-icon-theme through APT..."
    apt-get install -y papirus-icon-theme
}

install_papirus_upstream() {
    local tmpdir installer
    tmpdir=$(mktemp -d)
    installer="${tmpdir}/install.sh"

    # Cleanup is explicit so no RETURN trap can interact with ERR handling.
    if ! curl \
        --fail \
        --location \
        --proto '=https' \
        --tlsv1.2 \
        --retry 5 \
        --retry-all-errors \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 300 \
        --silent \
        --show-error \
        --output "$installer" \
        "$UPSTREAM_INSTALLER_URL"; then
        rm -rf "$tmpdir"
        die "Failed to download the official Papirus installer."
    fi

    [[ -s "$installer" ]] || { rm -rf "$tmpdir"; die "Downloaded Papirus installer is empty."; }

    # Basic provenance sanity checks. This is not a cryptographic signature;
    # upstream mode is intentionally opt-in for this reason.
    if ! grep -q 'PapirusDevelopmentTeam' "$installer" ||
       ! grep -q 'gh_repo="papirus-icon-theme"' "$installer"; then
        rm -rf "$tmpdir"
        die "Downloaded installer did not pass the expected repository sanity checks."
    fi

    chmod 700 "$installer"
    log "Running the official Papirus installer (TAG=${PAPIRUS_TAG})..."
    if ! DESTDIR="/usr/share/icons" \
         EXTRA_THEMES="Papirus-Dark" \
         TAG="$PAPIRUS_TAG" \
         bash "$installer"; then
        rm -rf "$tmpdir"
        die "The official Papirus installer failed."
    fi

    rm -rf "$tmpdir"
}

step "Installing ${ICON_THEME}"
case "$INSTALL_METHOD" in
    apt)      install_papirus_apt ;;
    upstream) install_papirus_upstream ;;
esac

[[ -d "$ICON_DIR" ]] || die "${ICON_DIR} does not exist after installation."
[[ -f "$ICON_DIR/index.theme" ]] || die "${ICON_DIR}/index.theme is missing after installation."
success "${ICON_THEME} is installed."

# -----------------------------------------------------------------------------
# Icon cache
# -----------------------------------------------------------------------------
step "Refreshing icon cache"
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    if gtk-update-icon-cache -f -t "$ICON_DIR" >/dev/null 2>&1; then
        success "Icon cache refreshed."
    else
        warn "gtk-update-icon-cache could not rebuild the Papirus-Dark cache; continuing because the theme files are installed."
    fi
else
    warn "gtk-update-icon-cache is not installed; skipping optional cache generation."
fi

# -----------------------------------------------------------------------------
# Global GTK defaults
# -----------------------------------------------------------------------------
step "Configuring system-wide GTK defaults"

mkdir -p /etc/gtk-3.0 /etc/gtk-4.0 /etc/gtk-2.0
set_ini_setting /etc/gtk-3.0/settings.ini gtk-icon-theme-name "$ICON_THEME" 644
set_ini_setting /etc/gtk-4.0/settings.ini gtk-icon-theme-name "$ICON_THEME" 644
set_gtk2_setting /etc/gtk-2.0/gtkrc "$ICON_THEME" 644
success "System-wide GTK defaults configured without replacing unrelated settings."

# -----------------------------------------------------------------------------
# XFCE system default
# -----------------------------------------------------------------------------
step "Configuring system-wide XFCE default"
mkdir -p "$(dirname "$XFCE_SYSTEM_FILE")"
set_xfce_xml_setting "$XFCE_SYSTEM_FILE" 644
success "XFCE default icon theme configured."

# -----------------------------------------------------------------------------
# User helpers
# -----------------------------------------------------------------------------
# Resolve symlinks and existing parent symlinks, then require the result to
# remain inside the account's home. The resolved path is used for root-side
# backup and directory creation; user-file editors subsequently drop privileges.
resolve_user_path() {
    local path=$1
    local home=$2

    python3 - "$path" "$home" <<'PY'
import os
import sys

path, home = sys.argv[1:]
root = os.path.realpath(home)
resolved = os.path.realpath(path)

try:
    inside = os.path.commonpath([root, resolved]) == root
except ValueError:
    inside = False

if not inside or resolved == root:
    print(f"Unsafe user path: {path} resolves outside {home}: {resolved}", file=sys.stderr)
    raise SystemExit(2)

print(resolved)
PY
}

ensure_user_directory() {
    local dir=$1
    local uid=$2
    local gid=$3
    local home=$4
    local resolved

    resolved=$(resolve_user_path "$dir" "$home")
    if [[ ! -d "$resolved" ]]; then
        install -d -m 700 -o "$uid" -g "$gid" "$resolved"
    fi
}

# Try to update an already-running Xfce session through xfconf. This avoids a
# running xfconfd later writing an old value back over the on-disk XML. If a
# usable session cannot be identified, the persistent XML edit below remains
# the fallback and will take effect on the next login.
apply_live_xfconf() {
    local user=$1
    local uid=$2
    local home=$3
    local proc pid proc_uid name env_file
    local dbus_addr="" display="" wayland_display="" xdg_runtime_dir=""

    command -v xfconf-query >/dev/null 2>&1 || return 1
    command -v runuser >/dev/null 2>&1 || return 1

    for proc in /proc/[0-9]*; do
        [[ -r "$proc/status" && -r "$proc/environ" ]] || continue
        pid=${proc##*/}
        proc_uid=$(awk '/^Uid:/ {print $2; exit}' "$proc/status" 2>/dev/null || true)
        [[ "$proc_uid" == "$uid" ]] || continue
        name=$(awk '/^Name:/ {print $2; exit}' "$proc/status" 2>/dev/null || true)
        [[ "$name" == "xfconfd" || "$name" == "xfce4-session" ]] || continue

        env_file="$proc/environ"
        dbus_addr=$(tr '\0' '\n' < "$env_file" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -n1 || true)
        display=$(tr '\0' '\n' < "$env_file" | sed -n 's/^DISPLAY=//p' | head -n1 || true)
        wayland_display=$(tr '\0' '\n' < "$env_file" | sed -n 's/^WAYLAND_DISPLAY=//p' | head -n1 || true)
        xdg_runtime_dir=$(tr '\0' '\n' < "$env_file" | sed -n 's/^XDG_RUNTIME_DIR=//p' | head -n1 || true)

        [[ -n "$dbus_addr" ]] || continue

        local -a env_args=(
            "HOME=$home"
            "USER=$user"
            "LOGNAME=$user"
            "DBUS_SESSION_BUS_ADDRESS=$dbus_addr"
        )
        [[ -n "$display" ]] && env_args+=("DISPLAY=$display")
        [[ -n "$wayland_display" ]] && env_args+=("WAYLAND_DISPLAY=$wayland_display")
        [[ -n "$xdg_runtime_dir" ]] && env_args+=("XDG_RUNTIME_DIR=$xdg_runtime_dir")

        if runuser -u "$user" -- env "${env_args[@]}" \
            xfconf-query -c xsettings -p /Net/IconThemeName -s "$ICON_THEME" \
            >/dev/null 2>&1; then
            return 0
        fi

        if runuser -u "$user" -- env "${env_args[@]}" \
            xfconf-query -c xsettings -p /Net/IconThemeName -n -t string -s "$ICON_THEME" \
            >/dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}

configure_user() {
    local user=$1
    local home=$2
    local uid gid
    local gtk3_dir gtk4_dir xfce_dir xfce_file
    local gtk3_file gtk4_file gtk2_file xfce_target

    [[ -d "$home" ]] || return 0
    [[ "$home" != "/" ]] || return 0

    uid=$(id -u "$user" 2>/dev/null) || return 0
    gid=$(id -g "$user" 2>/dev/null) || return 0

    log "Configuring user: ${user}"

    gtk3_dir="${home}/.config/gtk-3.0"
    gtk4_dir="${home}/.config/gtk-4.0"
    xfce_dir="${home}/.config/xfce4/xfconf/xfce-perchannel-xml"
    xfce_file="${xfce_dir}/xsettings.xml"

    ensure_user_directory "$gtk3_dir" "$uid" "$gid" "$home"
    ensure_user_directory "$gtk4_dir" "$uid" "$gid" "$home"
    ensure_user_directory "$xfce_dir" "$uid" "$gid" "$home"

    gtk3_file=$(resolve_user_path "${gtk3_dir}/settings.ini" "$home")
    gtk4_file=$(resolve_user_path "${gtk4_dir}/settings.ini" "$home")
    gtk2_file=$(resolve_user_path "${home}/.gtkrc-2.0" "$home")
    xfce_target=$(resolve_user_path "$xfce_file" "$home")

    # Preserve each user's existing settings. Editors drop to the user's own
    # UID/GID before opening or replacing the user-controlled target.
    set_ini_setting "$gtk3_file" gtk-icon-theme-name "$ICON_THEME" 600 "$uid" "$gid"
    set_ini_setting "$gtk4_file" gtk-icon-theme-name "$ICON_THEME" 600 "$uid" "$gid"
    set_gtk2_setting "$gtk2_file" "$ICON_THEME" 600 "$uid" "$gid"

    # Capture the persistent XFCE target before a live xfconf update can change it.
    backup_file "$xfce_target"

    if apply_live_xfconf "$user" "$uid" "$home"; then
        log "Applied XFCE setting live for ${user}."
        # xfconf persists the value. If the XML does not exist yet, do not race
        # xfconfd by creating it manually while the daemon is active.
    else
        set_xfce_xml_setting "$xfce_target" 600 "$uid" "$gid"
    fi

    success "Configured: ${user}"
}

# Determine the local human-user UID range from login.defs where available.
UID_MIN_VALUE=$(awk '$1 == "UID_MIN" {print $2; exit}' /etc/login.defs 2>/dev/null || true)
UID_MAX_VALUE=$(awk '$1 == "UID_MAX" {print $2; exit}' /etc/login.defs 2>/dev/null || true)
[[ "$UID_MIN_VALUE" =~ ^[0-9]+$ ]] || UID_MIN_VALUE=1000
[[ "$UID_MAX_VALUE" =~ ^[0-9]+$ ]] || UID_MAX_VALUE=60000

step "Configuring existing local users"
USER_COUNT=0

# Root is intentionally handled once, separately from the human-user loop.
if [[ -d /root ]]; then
    configure_user root /root
    USER_COUNT=$((USER_COUNT + 1))
fi

while IFS=: read -r user _ uid _ _ home shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    (( uid >= UID_MIN_VALUE && uid <= UID_MAX_VALUE )) || continue
    [[ -n "$home" && -d "$home" && "$home" != "/" ]] || continue

    case "$shell" in
        */nologin|*/false) continue ;;
    esac

    configure_user "$user" "$home"
    USER_COUNT=$((USER_COUNT + 1))
done < /etc/passwd

success "Configured ${USER_COUNT} local account(s)."

# -----------------------------------------------------------------------------
# /etc/skel defaults for future users
# -----------------------------------------------------------------------------
step "Configuring defaults for future users"
readonly SKEL="/etc/skel"

mkdir -p \
    "${SKEL}/.config/gtk-3.0" \
    "${SKEL}/.config/gtk-4.0" \
    "${SKEL}/.config/xfce4/xfconf/xfce-perchannel-xml"

set_ini_setting "${SKEL}/.config/gtk-3.0/settings.ini" gtk-icon-theme-name "$ICON_THEME" 644 0 0
set_ini_setting "${SKEL}/.config/gtk-4.0/settings.ini" gtk-icon-theme-name "$ICON_THEME" 644 0 0
set_gtk2_setting "${SKEL}/.gtkrc-2.0" "$ICON_THEME" 644 0 0
set_xfce_xml_setting "${SKEL}/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" 644 0 0

success "Future users will inherit ${ICON_THEME} without replacing other skeleton settings."

# -----------------------------------------------------------------------------
# Semantic verification
# -----------------------------------------------------------------------------
ini_has_value() {
    local file=$1 key=$2 expected=$3
    python3 - "$file" "$key" "$expected" <<'PY'
import configparser
import sys

path, key, expected = sys.argv[1:]
cfg = configparser.ConfigParser(interpolation=None, strict=False)
cfg.optionxform = str
try:
    with open(path, "r", encoding="utf-8") as f:
        cfg.read_file(f)
except Exception:
    raise SystemExit(1)

if not cfg.has_section("Settings"):
    raise SystemExit(1)

for k, v in cfg.items("Settings"):
    if k.strip().lower() == key.lower() and v.strip() == expected:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

gtk2_has_value() {
    local file=$1 expected=$2
    python3 - "$file" "$expected" <<'PY'
import re
import sys

path, expected = sys.argv[1:]
pattern = re.compile(r'^\s*gtk-icon-theme-name\s*=\s*["\']?([^"\']+?)["\']?\s*$')
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except Exception:
    raise SystemExit(1)

values = []
for line in lines:
    m = pattern.match(line)
    if m:
        values.append(m.group(1).strip())
raise SystemExit(0 if values and values[-1] == expected else 1)
PY
}

xfce_has_value() {
    local file=$1 expected=$2
    python3 - "$file" "$expected" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, expected = sys.argv[1:]
try:
    root = ET.parse(path).getroot()
except Exception:
    raise SystemExit(1)

for net in root.findall("./property"):
    if net.get("name") != "Net":
        continue
    for prop in net.findall("./property"):
        if prop.get("name") == "IconThemeName" and prop.get("value") == expected:
            raise SystemExit(0)
raise SystemExit(1)
PY
}

step "Performing final verification"
VERIFY_FAILED=0

[[ -f "$ICON_DIR/index.theme" ]] || { error "Missing ${ICON_DIR}/index.theme"; VERIFY_FAILED=1; }
ini_has_value /etc/gtk-3.0/settings.ini gtk-icon-theme-name "$ICON_THEME" || { error "GTK 3 system setting verification failed."; VERIFY_FAILED=1; }
ini_has_value /etc/gtk-4.0/settings.ini gtk-icon-theme-name "$ICON_THEME" || { error "GTK 4 system setting verification failed."; VERIFY_FAILED=1; }
gtk2_has_value /etc/gtk-2.0/gtkrc "$ICON_THEME" || { error "GTK 2 system setting verification failed."; VERIFY_FAILED=1; }
xfce_has_value "$XFCE_SYSTEM_FILE" "$ICON_THEME" || { error "XFCE system default verification failed."; VERIFY_FAILED=1; }

# Verify the skeleton defaults as well.
ini_has_value "${SKEL}/.config/gtk-3.0/settings.ini" gtk-icon-theme-name "$ICON_THEME" || { error "GTK 3 skeleton verification failed."; VERIFY_FAILED=1; }
ini_has_value "${SKEL}/.config/gtk-4.0/settings.ini" gtk-icon-theme-name "$ICON_THEME" || { error "GTK 4 skeleton verification failed."; VERIFY_FAILED=1; }
gtk2_has_value "${SKEL}/.gtkrc-2.0" "$ICON_THEME" || { error "GTK 2 skeleton verification failed."; VERIFY_FAILED=1; }
xfce_has_value "${SKEL}/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml" "$ICON_THEME" || { error "XFCE skeleton verification failed."; VERIFY_FAILED=1; }

if (( VERIFY_FAILED != 0 )); then
    die "One or more verification checks failed."
fi

success "All verification checks passed."

printf '\n%b==============================================%b\n' "$C_GREEN" "$C_RESET"
printf '%b Papirus-Dark configuration completed%b\n' "$C_BOLD" "$C_RESET"
printf '%b==============================================%b\n\n' "$C_GREEN" "$C_RESET"
printf 'Icon theme     : %s\n' "$ICON_THEME"
printf 'Location       : %s\n' "$ICON_DIR"
printf 'Install method : %s\n' "$INSTALL_METHOD"
printf 'Backup         : %s\n\n' "$BACKUP_DIR"
log "Existing Xfce sessions updated live where accessible; otherwise logout/login applies the persistent setting."
log "No reboot is normally required."
