#!/usr/bin/env bash
# Set_GeneralTheme_ideal.sh
# Debian-family | WhiteSur-Dark system-wide + XFCE users/defaults

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

readonly THEME_NAME="WhiteSur"
readonly THEME_VARIANT="WhiteSur-Dark"
readonly THEME_DEST="/usr/share/themes"
readonly REPO_URL="https://github.com/vinceliuice/WhiteSur-gtk-theme.git"
# Pin to a released upstream revision for reproducibility. Override explicitly
# (for example WHITESUR_REF=master) if a newer upstream snapshot is desired.
readonly WHITESUR_REF="${WHITESUR_REF:-2026-07-07}"
# WhiteSur's -l workaround writes into each user's ~/.config/gtk-4.0 and can
# force a fixed libadwaita appearance. Keep it opt-in because libadwaita does
# not officially support arbitrary custom themes.
readonly ENABLE_LIBADWAITA="${ENABLE_LIBADWAITA:-0}"

readonly BACKUP_ROOT="/var/backups/Set_GeneralTheme"
readonly RUN_STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_DIR=""
readonly WORKDIR="$(mktemp -d -t whitesur-theme.XXXXXX)"
readonly REPO_DIR="${WORKDIR}/WhiteSur-gtk-theme"
readonly XML_HELPER="${WORKDIR}/xfce_xml_set.py"

if [[ -t 1 ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
else
    readonly C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

log()  { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

cleanup() {
    rm -rf -- "$WORKDIR"
}
trap cleanup EXIT

on_error() {
    local code=$?
    local line=${BASH_LINENO[0]:-unknown}
    printf '%s[ERROR]%s Failed at line %s: %s (exit %s)\n' \
        "$C_RED" "$C_RESET" "$line" "${BASH_COMMAND:-unknown}" "$code" >&2
    exit "$code"
}
trap on_error ERR

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash Set_GeneralTheme_ideal.sh"

case "$ENABLE_LIBADWAITA" in
    0|1) ;;
    *) die "ENABLE_LIBADWAITA must be 0 or 1." ;;
esac
[[ "$WHITESUR_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || \
    die "WHITESUR_REF contains unsupported characters: $WHITESUR_REF"

step "Checking operating system"
[[ -r /etc/os-release ]] || die "/etc/os-release was not found."
# shellcheck disable=SC1091
. /etc/os-release
if [[ " ${ID:-} ${ID_LIKE:-} " != *" debian "* && "${ID:-}" != "ubuntu" ]]; then
    die "This script targets Debian-family systems. Detected: ${PRETTY_NAME:-unknown}"
fi
command -v apt-get >/dev/null 2>&1 || die "apt-get was not found."
ok "Detected: ${PRETTY_NAME:-unknown}"

step "Checking package-management commands"
for cmd in dpkg-query grep; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required base command is missing: $cmd"
done

step "Installing required packages when missing"
packages=(ca-certificates git sassc libglib2.0-dev libxml2-utils python3 util-linux)
# xfconf-query is needed only for live XFCE updates; installing xfconf is
# appropriate for this XFCE-targeted script.
packages+=(xfconf)
missing_packages=()
for pkg in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
        missing_packages+=("$pkg")
    fi
done
if (( ${#missing_packages[@]} > 0 )); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "${missing_packages[@]}"
else
    ok "Required packages are already installed."
fi
required_commands=(awk cp date dirname dpkg-query getent git grep id mkdir mktemp python3 rm runuser stat)
missing_commands=()
for cmd in "${required_commands[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd")
done
(( ${#missing_commands[@]} == 0 )) || die "Missing commands after dependency setup: ${missing_commands[*]}"

step "Preparing backup and temporary workspace"
mkdir -p -- "$BACKUP_ROOT"
chmod 700 -- "$BACKUP_ROOT"
BACKUP_DIR="$(mktemp -d "${BACKUP_ROOT}/${RUN_STAMP}.XXXXXX")"
chmod 700 -- "$BACKUP_DIR"
# Users need read/traverse access to the checked-out installer for the optional
# unprivileged libadwaita step. They never receive write access.
chmod 755 -- "$WORKDIR"

backup_path() {
    local src=$1
    local rel dst
    if [[ ! -e "$src" && ! -L "$src" ]]; then
        return 0
    fi
    rel=${src#/}
    dst="${BACKUP_DIR}/${rel}"
    mkdir -p -- "$(dirname -- "$dst")"
    if [[ ! -e "$dst" && ! -L "$dst" ]]; then
        cp -a -- "$src" "$dst"
        log "Backed up: $src"
    fi
}

cat > "$XML_HELPER" <<'PY'
#!/usr/bin/env python3
import os
import stat
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

if len(sys.argv) != 9:
    raise SystemExit("usage: helper PATH CHANNEL PARENT KEY VALUE FILE_MODE DIR_MODE CONTAINMENT_ROOT")

raw_path, channel, parent_name, key, value, file_mode_s, dir_mode_s, containment = sys.argv[1:]
path = Path(raw_path)
file_mode = int(file_mode_s, 8)
dir_mode = int(dir_mode_s, 8)

# For user-controlled paths, resolve symlinks and reject escapes outside HOME.
# For trusted system paths, containment is '-'.
if containment != "-":
    home = Path(containment).resolve()
    resolved = path.resolve(strict=False)
    try:
        common = os.path.commonpath((str(home), str(resolved)))
    except ValueError:
        raise SystemExit("path containment check failed")
    if common != str(home):
        raise SystemExit(f"refusing path outside home: {path} -> {resolved}")
    path = resolved

path.parent.mkdir(parents=True, exist_ok=True, mode=dir_mode)

old_stat = None
if path.exists():
    old_stat = path.stat()
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    try:
        tree = ET.parse(path, parser=parser)
    except ET.ParseError as exc:
        raise SystemExit(f"malformed XML, left unchanged: {path}: {exc}")
    root = tree.getroot()
    if root.tag != "channel":
        raise SystemExit(f"invalid XFCE channel root in {path}")
    existing_channel = root.get("name")
    if existing_channel not in (None, channel):
        raise SystemExit(f"unexpected channel {existing_channel!r} in {path}")
else:
    root = ET.Element("channel", {"name": channel, "version": "1.0"})
    tree = ET.ElementTree(root)

root.set("name", channel)
if root.get("version") is None:
    root.set("version", "1.0")

parent = None
for node in root.findall("property"):
    if node.get("name") == parent_name:
        parent = node
        break
if parent is None:
    parent = ET.SubElement(root, "property", {"name": parent_name, "type": "empty"})
else:
    parent.set("type", "empty")

prop = None
for node in parent.findall("property"):
    if node.get("name") == key:
        prop = node
        break
if prop is None:
    prop = ET.SubElement(parent, "property")
prop.set("name", key)
prop.set("type", "string")
prop.set("value", value)
# Scalar XFCE properties should not retain stale child properties.
for child in list(prop):
    prop.remove(child)

fd, tmpname = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
try:
    with os.fdopen(fd, "wb") as fh:
        tree.write(fh, encoding="UTF-8", xml_declaration=True)
        fh.flush()
        os.fsync(fh.fileno())
    if old_stat is not None:
        os.chmod(tmpname, stat.S_IMODE(old_stat.st_mode))
        try:
            os.chown(tmpname, old_stat.st_uid, old_stat.st_gid)
        except PermissionError:
            # Expected for the unprivileged per-user path; mkstemp already owns
            # the file as the correct user.
            pass
    else:
        os.chmod(tmpname, file_mode)
    os.replace(tmpname, path)
finally:
    try:
        os.unlink(tmpname)
    except FileNotFoundError:
        pass
PY
chmod 644 -- "$XML_HELPER"
python3 -m py_compile "$XML_HELPER"

step "Downloading pinned WhiteSur source"
git clone --depth 1 --branch "$WHITESUR_REF" --single-branch -- "$REPO_URL" "$REPO_DIR"
[[ -f "$REPO_DIR/install.sh" ]] || die "WhiteSur install.sh is missing from the checkout."
chmod -R a+rX,u+w -- "$REPO_DIR"
readonly RESOLVED_REF="$(git -C "$REPO_DIR" rev-parse HEAD)"
log "WhiteSur ref: ${WHITESUR_REF} (${RESOLVED_REF})"

step "Installing WhiteSur-Dark system-wide"
# Back up an existing target theme before upstream replaces it.
backup_path "${THEME_DEST}/${THEME_VARIANT}"
(
    cd "$REPO_DIR"
    bash ./install.sh \
        -d "$THEME_DEST" \
        -n "$THEME_NAME" \
        -c dark \
        -o normal \
        -a normal
)
[[ -f "${THEME_DEST}/${THEME_VARIANT}/gtk-3.0/gtk.css" ]] || \
    die "GTK 3 theme files were not installed at ${THEME_DEST}/${THEME_VARIANT}."
[[ -f "${THEME_DEST}/${THEME_VARIANT}/xfwm4/themerc" ]] || \
    die "XFWM4 theme files were not installed at ${THEME_DEST}/${THEME_VARIANT}."
ok "${THEME_VARIANT} installed system-wide."

set_system_xfce_xml() {
    local path=$1 channel=$2 parent=$3 key=$4
    backup_path "$path"
    python3 "$XML_HELPER" "$path" "$channel" "$parent" "$key" "$THEME_VARIANT" 0644 0755 -
}

step "Merging system-wide XFCE defaults"
readonly XDG_XFCE_DIR="/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
set_system_xfce_xml "$XDG_XFCE_DIR/xsettings.xml" xsettings Net ThemeName
set_system_xfce_xml "$XDG_XFCE_DIR/xfwm4.xml" xfwm4 general theme
ok "System XFCE defaults configured without replacing unrelated settings."

step "Merging /etc/skel defaults"
readonly SKEL_XFCE_DIR="/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml"
set_system_xfce_xml "$SKEL_XFCE_DIR/xsettings.xml" xsettings Net ThemeName
set_system_xfce_xml "$SKEL_XFCE_DIR/xfwm4.xml" xfwm4 general theme
ok "Future-user defaults configured without replacing unrelated settings."

read_uid_limits() {
    local uid_min=1000 uid_max=60000
    if [[ -r /etc/login.defs ]]; then
        local v
        v=$(awk '$1=="UID_MIN" {print $2; exit}' /etc/login.defs || true)
        [[ "$v" =~ ^[0-9]+$ ]] && uid_min=$v
        v=$(awk '$1=="UID_MAX" {print $2; exit}' /etc/login.defs || true)
        [[ "$v" =~ ^[0-9]+$ ]] && uid_max=$v
    fi
    printf '%s %s\n' "$uid_min" "$uid_max"
}
read -r UID_MIN_VALUE UID_MAX_VALUE < <(read_uid_limits)

user_xml_set() {
    local user=$1 home=$2 path=$3 channel=$4 parent=$5 key=$6
    runuser -u "$user" -- env HOME="$home" \
        python3 "$XML_HELPER" "$path" "$channel" "$parent" "$key" "$THEME_VARIANT" 0600 0700 "$home"
}

live_xfconf_set() {
    local user=$1 uid=$2 home=$3 channel=$4 property=$5 value=$6
    local runtime="/run/user/${uid}"
    [[ -S "$runtime/bus" ]] || return 1
    command -v xfconf-query >/dev/null 2>&1 || return 1

    local -a env_cmd=(env HOME="$home" XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus")
    if runuser -u "$user" -- "${env_cmd[@]}" \
        xfconf-query -c "$channel" -p "$property" -s "$value" >/dev/null 2>&1; then
        return 0
    fi
    runuser -u "$user" -- "${env_cmd[@]}" \
        xfconf-query -c "$channel" -p "$property" -n -t string -s "$value" >/dev/null 2>&1
}

step "Applying the theme to existing desktop users"
USER_COUNT=0
USER_FAILURES=0
LIBADWAITA_FAILURES=0
while IFS=: read -r username _ uid gid _ home shell; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    (( uid >= UID_MIN_VALUE && uid <= UID_MAX_VALUE )) || continue
    [[ -d "$home" ]] || continue
    case "$shell" in
        */nologin|*/false) continue ;;
    esac
    # Ensure passwd metadata is internally consistent before acting on it.
    id "$username" >/dev/null 2>&1 || continue
    [[ "$(id -u "$username")" == "$uid" ]] || continue

    USER_COUNT=$((USER_COUNT + 1))
    log "Configuring ${username} (${home})"

    user_xfce_dir="${home}/.config/xfce4/xfconf/xfce-perchannel-xml"
    user_xsettings="${user_xfce_dir}/xsettings.xml"
    user_xfwm="${user_xfce_dir}/xfwm4.xml"
    backup_path "$user_xsettings"
    backup_path "$user_xfwm"

    user_failed=0
    if ! user_xml_set "$username" "$home" "$user_xsettings" xsettings Net ThemeName; then
        warn "Could not safely update xsettings.xml for ${username}; existing file was left unchanged."
        user_failed=1
    fi
    if ! user_xml_set "$username" "$home" "$user_xfwm" xfwm4 general theme; then
        warn "Could not safely update xfwm4.xml for ${username}; existing file was left unchanged."
        user_failed=1
    fi
    if (( user_failed != 0 )); then
        USER_FAILURES=$((USER_FAILURES + 1))
    fi

    # Best-effort live refresh. Persistent XML above is the source of truth for
    # the next login even when D-Bus is unavailable now.
    live_xfconf_set "$username" "$uid" "$home" xsettings /Net/ThemeName "$THEME_VARIANT" || true
    live_xfconf_set "$username" "$uid" "$home" xfwm4 /general/theme "$THEME_VARIANT" || true

    if (( ENABLE_LIBADWAITA == 1 )); then
        gtk4_dir="${home}/.config/gtk-4.0"
        backup_path "$gtk4_dir"
        # Upstream explicitly requires -l to run as the user, not root.
        if ! runuser -u "$username" -- env HOME="$home" \
            bash "$REPO_DIR/install.sh" -n "$THEME_NAME" -c dark -l >/dev/null 2>&1; then
            warn "Optional GTK4/libadwaita workaround failed for ${username}."
            LIBADWAITA_FAILURES=$((LIBADWAITA_FAILURES + 1))
        fi
    fi
done < /etc/passwd

if (( USER_COUNT == 0 )); then
    warn "No normal desktop users were found. System and /etc/skel defaults are still configured."
else
    ok "Processed ${USER_COUNT} existing user account(s)."
fi

step "Final verification"
python3 - "$XDG_XFCE_DIR/xsettings.xml" "$XDG_XFCE_DIR/xfwm4.xml" \
          "$SKEL_XFCE_DIR/xsettings.xml" "$SKEL_XFCE_DIR/xfwm4.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

checks = [
    (sys.argv[1], "xsettings", "Net", "ThemeName", "WhiteSur-Dark"),
    (sys.argv[2], "xfwm4", "general", "theme", "WhiteSur-Dark"),
    (sys.argv[3], "xsettings", "Net", "ThemeName", "WhiteSur-Dark"),
    (sys.argv[4], "xfwm4", "general", "theme", "WhiteSur-Dark"),
]
for path, channel, parent, key, expected in checks:
    root = ET.parse(path).getroot()
    if root.tag != "channel" or root.get("name") != channel:
        raise SystemExit(f"verification failed: {path}")
    found = None
    for p in root.findall("property"):
        if p.get("name") == parent:
            for q in p.findall("property"):
                if q.get("name") == key:
                    found = q.get("value")
                    break
    if found != expected:
        raise SystemExit(f"verification failed: {path}: {found!r}")
PY

if (( USER_FAILURES > 0 )); then
    die "${USER_FAILURES} user configuration(s) could not be safely updated. Backups: ${BACKUP_DIR}"
fi

printf '\n==============================================\n'
printf ' WhiteSur-Dark installation completed\n'
printf '==============================================\n'
printf 'Theme          : %s\n' "$THEME_VARIANT"
printf 'Location       : %s/%s\n' "$THEME_DEST" "$THEME_VARIANT"
printf 'Upstream ref   : %s\n' "$WHITESUR_REF"
printf 'Commit         : %s\n' "$RESOLVED_REF"
printf 'Users          : %s\n' "$USER_COUNT"
printf 'Libadwaita     : %s\n' "$([[ "$ENABLE_LIBADWAITA" == 1 ]] && printf enabled || printf disabled)"
printf 'Backup         : %s\n' "$BACKUP_DIR"
if (( LIBADWAITA_FAILURES > 0 )); then
    printf 'Libadwaita errs: %s\n' "$LIBADWAITA_FAILURES"
fi
printf '==============================================\n'
