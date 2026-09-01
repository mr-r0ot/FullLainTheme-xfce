#!/usr/bin/env bash
# ============================================================
# Set_SystemFont.sh
# Debian/Ubuntu family | Safe system-wide JetBrains Mono setup
#
# UI font       : JetBrains Mono 10
# Terminal font : JetBrains Mono 11
#
# Applies to:
#   - Fontconfig generic monospace preference
#   - GTK 2/3/4 defaults
#   - XFCE xsettings defaults and existing users
#   - XFCE Terminal (new xfconf format + legacy terminalrc)
#   - /etc/skel for future users
#
# Design goals:
#   - Idempotent
#   - Preserve unrelated user/system settings
#   - Atomic config-file replacement
#   - Exact backups before modification
#   - No recursive ownership/permission changes
#   - Safe handling of active XFCE sessions via xfconf-query
#
# Usage:
#   sudo bash Set_SystemFont_ideal.sh
#
# Optional version override:
#   sudo JBM_VERSION=2.304 bash Set_SystemFont_ideal.sh
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# -----------------------------
# Configuration
# -----------------------------
FONT_FAMILY="JetBrains Mono"
SYSTEM_FONT="${FONT_FAMILY} 10"
TERMINAL_FONT="${FONT_FAMILY} 11"

JBM_VERSION="${JBM_VERSION:-2.304}"
if [[ ! "$JBM_VERSION" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    printf 'ERROR: Invalid JBM_VERSION: %s\n' "$JBM_VERSION" >&2
    exit 1
fi

JBM_URL="https://github.com/JetBrains/JetBrainsMono/releases/download/v${JBM_VERSION}/JetBrainsMono-${JBM_VERSION}.zip"

FONT_DIR="/usr/local/share/fonts/jetbrains-mono"
FONT_PARENT="$(dirname "$FONT_DIR")"
FONTCONFIG_FILE="/etc/fonts/conf.d/99-jetbrains-mono-system.conf"

GTK2_SYSTEM_FILE="/etc/gtk-2.0/gtkrc"
GTK3_SYSTEM_FILE="/etc/xdg/gtk-3.0/settings.ini"
GTK4_SYSTEM_FILE="/etc/xdg/gtk-4.0/settings.ini"

XFCE_XCONF_SYSTEM_DIR="/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
XFCE_XSETTINGS_SYSTEM_FILE="${XFCE_XCONF_SYSTEM_DIR}/xsettings.xml"
XFCE_TERMINAL_XCONF_SYSTEM_FILE="${XFCE_XCONF_SYSTEM_DIR}/xfce4-terminal.xml"
XFCE_TERMINAL_LEGACY_SYSTEM_FILE="/etc/xdg/xfce4/terminal/terminalrc"

SKEL_DIR="/etc/skel"

TMP_DIR="$(mktemp -d -t set-system-font.XXXXXXXX)"
BACKUP_DIR="/var/backups/Set_SystemFont_$(date +%Y%m%d_%H%M%S)"
CREATED_MANIFEST="${BACKUP_DIR}/created_paths.txt"

# Runtime path used only during the atomic font-directory swap.
FONT_STAGE_DIR="${FONT_PARENT}/.jetbrains-mono.new.$$"
FONT_OLD_DIR="${FONT_PARENT}/.jetbrains-mono.old.$$"

APT_UPDATED=0

# Keep a per-run set so a file is never backed up twice.
declare -A BACKED_UP=()
declare -A RECORDED_CREATED=()
declare -A SEEN_HOMES=()

# -----------------------------
# Diagnostics / cleanup
# -----------------------------
log() {
    printf '%s\n' "$*"
}

error_exit() {
    local message="$1"
    printf '\n============================================================\n' >&2
    printf 'ERROR\n' >&2
    printf '============================================================\n' >&2
    printf '%s\n' "$message" >&2
    printf 'No reboot has been performed.\n' >&2
    exit 1
}

cleanup() {
    rm -rf -- "$TMP_DIR" 2>/dev/null || true
    rm -rf -- "$FONT_STAGE_DIR" 2>/dev/null || true

    # FONT_OLD_DIR should only exist transiently during the swap.
    # Never delete it blindly if the new directory is missing.
    if [[ -d "$FONT_OLD_DIR" && -d "$FONT_DIR" ]]; then
        rm -rf -- "$FONT_OLD_DIR" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'error_exit "Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

# -----------------------------
# Preconditions
# -----------------------------
if [[ "${EUID}" -ne 0 ]]; then
    error_exit "Run this script as root: sudo bash Set_SystemFont_ideal.sh"
fi

if [[ ! -r /etc/os-release ]]; then
    error_exit "/etc/os-release was not found."
fi

# shellcheck disable=SC1091
source /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
    *debian*|*ubuntu*) ;;
    *) error_exit "This script is intended for Debian/Ubuntu-family systems." ;;
esac

# -----------------------------
# Package helpers
# -----------------------------
apt_update_once() {
    if (( APT_UPDATED == 0 )); then
        apt-get update
        APT_UPDATED=1
    fi
}

install_package_if_command_missing() {
    local command_name="$1"
    local package_name="$2"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        log "  -> Installing ${package_name}..."
        apt_update_once
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$package_name"
    fi
}

ensure_ca_certificates() {
    if [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
        log "  -> Installing ca-certificates..."
        apt_update_once
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates
    fi
}

# -----------------------------
# Backup helpers
# -----------------------------
record_created_path() {
    local path="$1"

    if [[ -z "${RECORDED_CREATED[$path]+x}" ]]; then
        printf '%s\n' "$path" >> "$CREATED_MANIFEST"
        RECORDED_CREATED["$path"]=1
    fi
}

backup_path() {
    local path="$1"
    local rel dest

    [[ -e "$path" || -L "$path" ]] || return 0

    if [[ -n "${BACKED_UP[$path]+x}" ]]; then
        return 0
    fi

    rel="${path#/}"
    dest="${BACKUP_DIR}/original/${rel}"
    mkdir -p -- "$(dirname "$dest")"
    cp -a -- "$path" "$dest"
    BACKED_UP["$path"]=1
}

prepare_file_change() {
    local path="$1"

    if [[ -e "$path" || -L "$path" ]]; then
        backup_path "$path"
    else
        record_created_path "$path"
    fi
}

# -----------------------------
# Safe config editors
# -----------------------------
# Edits one key in one INI section while preserving unrelated lines.
# The file is atomically replaced in-place.
update_ini_value() {
    local run_user="$1"
    local path="$2"
    local section="$3"
    local key="$4"
    local value="$5"
    local -a cmd=(python3 - "$path" "$section" "$key" "$value")

    if [[ "$run_user" != "root" ]]; then
        cmd=(runuser -u "$run_user" -- "${cmd[@]}")
    fi

    "${cmd[@]}" <<'PY'
import os
import re
import sys
import tempfile

path, target_section, key, value = sys.argv[1:5]

if os.path.lexists(path) and os.path.islink(path):
    raise SystemExit(f"Refusing to replace symlink: {path}")
if os.path.exists(path) and not os.path.isfile(path):
    raise SystemExit(f"Not a regular file: {path}")

try:
    with open(path, "r", encoding="utf-8", errors="strict") as f:
        text = f.read()
except FileNotFoundError:
    text = ""

lines = text.splitlines(keepends=True)
section_re = re.compile(r"^\s*\[([^\]]+)\]\s*(?:[;#].*)?(?:\r?\n)?$")
key_re = re.compile(r"^\s*" + re.escape(key) + r"\s*=", re.IGNORECASE)

out = []
in_target = False
section_seen = False
key_written = False

for line in lines:
    m = section_re.match(line)
    if m:
        if in_target and not key_written:
            out.append(f"{key}={value}\n")
            key_written = True
        in_target = (m.group(1).strip().lower() == target_section.lower())
        section_seen = section_seen or in_target
        out.append(line)
        continue

    if in_target and key_re.match(line):
        if not key_written:
            out.append(f"{key}={value}\n")
            key_written = True
        # Remove duplicate instances of the same key in this section.
        continue

    out.append(line)

if section_seen:
    if in_target and not key_written:
        out.append(f"{key}={value}\n")
else:
    if out and not out[-1].endswith(("\n", "\r")):
        out[-1] += "\n"
    if out and out[-1].strip():
        out.append("\n")
    out.append(f"[{target_section}]\n")
    out.append(f"{key}={value}\n")

new_text = "".join(out)
parent = os.path.dirname(path) or "."
os.makedirs(parent, exist_ok=True)

old_stat = os.stat(path, follow_symlinks=False) if os.path.exists(path) else None
fd, tmp = tempfile.mkstemp(prefix=".fontcfg.", dir=parent, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.write(new_text)
        f.flush()
        os.fsync(f.fileno())
    if old_stat is not None:
        os.chmod(tmp, old_stat.st_mode & 0o7777)
        if os.geteuid() == 0:
            os.chown(tmp, old_stat.st_uid, old_stat.st_gid)
    else:
        os.chmod(tmp, 0o644)
    os.replace(tmp, path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
}

# Edits gtk-font-name in a GTK2 gtkrc file without touching unrelated settings.
update_gtk2_font() {
    local run_user="$1"
    local path="$2"
    local font="$3"
    local -a cmd=(python3 - "$path" "$font")

    if [[ "$run_user" != "root" ]]; then
        cmd=(runuser -u "$run_user" -- "${cmd[@]}")
    fi

    "${cmd[@]}" <<'PY'
import os
import re
import sys
import tempfile

path, font = sys.argv[1:3]

if os.path.lexists(path) and os.path.islink(path):
    raise SystemExit(f"Refusing to replace symlink: {path}")
if os.path.exists(path) and not os.path.isfile(path):
    raise SystemExit(f"Not a regular file: {path}")

try:
    with open(path, "r", encoding="utf-8", errors="strict") as f:
        lines = f.read().splitlines(keepends=True)
except FileNotFoundError:
    lines = []

pattern = re.compile(r"^\s*gtk-font-name\s*=", re.IGNORECASE)
out = []
written = False
for line in lines:
    if pattern.match(line):
        if not written:
            escaped = font.replace("\\", "\\\\").replace('"', '\\"')
            out.append(f'gtk-font-name = "{escaped}"\n')
            written = True
        continue
    out.append(line)

if not written:
    if out and not out[-1].endswith(("\n", "\r")):
        out[-1] += "\n"
    if out and out[-1].strip():
        out.append("\n")
    escaped = font.replace("\\", "\\\\").replace('"', '\\"')
    out.append(f'gtk-font-name = "{escaped}"\n')

new_text = "".join(out)
parent = os.path.dirname(path) or "."
os.makedirs(parent, exist_ok=True)
old_stat = os.stat(path, follow_symlinks=False) if os.path.exists(path) else None
fd, tmp = tempfile.mkstemp(prefix=".fontcfg.", dir=parent, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.write(new_text)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, (old_stat.st_mode & 0o7777) if old_stat else 0o644)
    if old_stat is not None and os.geteuid() == 0:
        os.chown(tmp, old_stat.st_uid, old_stat.st_gid)
    os.replace(tmp, path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
}

# Safely updates an xfconf XML file by property path.
# Examples:
#   channel=xsettings       path=/Gtk/FontName        type=string
#   channel=xfce4-terminal  path=/font-use-system     type=bool
update_xfconf_xml() {
    local run_user="$1"
    local path="$2"
    local channel="$3"
    local property_path="$4"
    local property_type="$5"
    local property_value="$6"
    local -a cmd=(python3 - "$path" "$channel" "$property_path" "$property_type" "$property_value")

    if [[ "$run_user" != "root" ]]; then
        cmd=(runuser -u "$run_user" -- "${cmd[@]}")
    fi

    "${cmd[@]}" <<'PY'
import os
import sys
import tempfile
import xml.etree.ElementTree as ET

path, channel, prop_path, prop_type, prop_value = sys.argv[1:6]

if os.path.lexists(path) and os.path.islink(path):
    raise SystemExit(f"Refusing to replace symlink: {path}")
if os.path.exists(path) and not os.path.isfile(path):
    raise SystemExit(f"Not a regular file: {path}")

parts = [p for p in prop_path.split("/") if p]
if not parts:
    raise SystemExit("Empty xfconf property path")

if os.path.exists(path) and os.path.getsize(path) > 0:
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    tree = ET.parse(path, parser=parser)
    root = tree.getroot()
    if root.tag != "channel":
        raise SystemExit(f"Unexpected XFCE XML root in {path}: {root.tag}")
    existing_channel = root.get("name")
    if existing_channel and existing_channel != channel:
        raise SystemExit(
            f"Unexpected XFCE channel in {path}: {existing_channel!r}; expected {channel!r}"
        )
    root.set("name", channel)
    if not root.get("version"):
        root.set("version", "1.0")
else:
    root = ET.Element("channel", {"name": channel, "version": "1.0"})
    tree = ET.ElementTree(root)

parent = root
for name in parts[:-1]:
    child = None
    for candidate in parent.findall("property"):
        if candidate.get("name") == name:
            child = candidate
            break
    if child is None:
        child = ET.SubElement(parent, "property", {"name": name, "type": "empty"})
    elif child.get("type") not in (None, "empty"):
        raise SystemExit(
            f"Cannot create nested property below non-empty node {name!r} in {path}"
        )
    child.set("type", "empty")
    parent = child

leaf_name = parts[-1]
leaf = None
for candidate in parent.findall("property"):
    if candidate.get("name") == leaf_name:
        leaf = candidate
        break
if leaf is None:
    leaf = ET.SubElement(parent, "property", {"name": leaf_name})

leaf.set("type", prop_type)
leaf.set("value", prop_value)

# Leaf properties should not contain nested properties. Refuse to destroy them silently.
if list(leaf):
    raise SystemExit(f"Target property unexpectedly has children: {prop_path} in {path}")

try:
    ET.indent(tree, space="    ")
except AttributeError:
    pass

parent_dir = os.path.dirname(path) or "."
os.makedirs(parent_dir, exist_ok=True)
old_stat = os.stat(path, follow_symlinks=False) if os.path.exists(path) else None
fd, tmp = tempfile.mkstemp(prefix=".xfconf.", dir=parent_dir)
os.close(fd)
try:
    tree.write(tmp, encoding="utf-8", xml_declaration=True)
    with open(tmp, "rb+") as f:
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, (old_stat.st_mode & 0o7777) if old_stat else 0o644)
    if old_stat is not None and os.geteuid() == 0:
        os.chown(tmp, old_stat.st_uid, old_stat.st_gid)
    os.replace(tmp, path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
}

# -----------------------------
# User execution helpers
# -----------------------------
ensure_user_dir() {
    local username="$1"
    local dir="$2"

    if [[ -e "$dir" && ! -d "$dir" ]]; then
        error_exit "Expected a directory but found another object: ${dir}"
    fi

    if [[ ! -d "$dir" ]]; then
        if [[ "$username" == "root" ]]; then
            mkdir -p -- "$dir"
        else
            runuser -u "$username" -- mkdir -p -- "$dir"
        fi
    fi
}

chmod_user_file() {
    local username="$1"
    local path="$2"

    if [[ "$username" == "root" ]]; then
        chmod 0644 -- "$path"
    else
        runuser -u "$username" -- chmod 0644 -- "$path"
    fi
}

xfconf_live_available() {
    local uid="$1"
    command -v xfconf-query >/dev/null 2>&1 && [[ -S "/run/user/${uid}/bus" ]]
}

xfconf_live_set() {
    local username="$1"
    local uid="$2"
    local channel="$3"
    local property="$4"
    local type="$5"
    local value="$6"
    local runtime_dir="/run/user/${uid}"
    local bus="${runtime_dir}/bus"
    local -a base

    command -v xfconf-query >/dev/null 2>&1 || return 1
    [[ -S "$bus" ]] || return 1

    if [[ "$username" == "root" ]]; then
        base=(env "XDG_RUNTIME_DIR=${runtime_dir}" "DBUS_SESSION_BUS_ADDRESS=unix:path=${bus}")
    else
        base=(runuser -u "$username" -- env "XDG_RUNTIME_DIR=${runtime_dir}" "DBUS_SESSION_BUS_ADDRESS=unix:path=${bus}")
    fi

    if "${base[@]}" xfconf-query -c "$channel" -p "$property" -s "$value" >/dev/null 2>&1; then
        return 0
    fi

    "${base[@]}" xfconf-query -c "$channel" -p "$property" -n -t "$type" -s "$value" >/dev/null 2>&1
}

# -----------------------------
# User configuration
# -----------------------------
configure_user() {
    local username="$1"
    local home="$2"
    local uid
    local xconf_dir xsettings_file terminal_xconf_file terminal_legacy_dir terminal_legacy_file
    local gtk3_dir gtk3_file gtk4_dir gtk4_file gtk2_file
    local live_xfconf=0

    [[ -d "$home" ]] || return 0
    [[ "$home" == /* ]] || return 0
    [[ "$home" != "/" ]] || return 0

    uid="$(id -u "$username" 2>/dev/null || true)"
    [[ "$uid" =~ ^[0-9]+$ ]] || return 0

    # Avoid processing the same home through multiple accounts.
    if [[ -n "${SEEN_HOMES[$home]+x}" ]]; then
        return 0
    fi
    SEEN_HOMES["$home"]=1

    xconf_dir="${home}/.config/xfce4/xfconf/xfce-perchannel-xml"
    xsettings_file="${xconf_dir}/xsettings.xml"
    terminal_xconf_file="${xconf_dir}/xfce4-terminal.xml"
    terminal_legacy_dir="${home}/.config/xfce4/terminal"
    terminal_legacy_file="${terminal_legacy_dir}/terminalrc"

    gtk2_file="${home}/.gtkrc-2.0"
    gtk3_dir="${home}/.config/gtk-3.0"
    gtk3_file="${gtk3_dir}/settings.ini"
    gtk4_dir="${home}/.config/gtk-4.0"
    gtk4_file="${gtk4_dir}/settings.ini"

    ensure_user_dir "$username" "${home}/.config"
    ensure_user_dir "$username" "${home}/.config/xfce4"
    ensure_user_dir "$username" "${home}/.config/xfce4/xfconf"
    ensure_user_dir "$username" "$xconf_dir"
    ensure_user_dir "$username" "$terminal_legacy_dir"
    ensure_user_dir "$username" "$gtk3_dir"
    ensure_user_dir "$username" "$gtk4_dir"

    prepare_file_change "$xsettings_file"
    prepare_file_change "$terminal_xconf_file"
    prepare_file_change "$terminal_legacy_file"
    prepare_file_change "$gtk2_file"
    prepare_file_change "$gtk3_file"
    prepare_file_change "$gtk4_file"

    # If xfconf is live, use its supported API so a running daemon cannot
    # overwrite our changes. Otherwise update the persistent XML directly.
    if xfconf_live_available "$uid"; then
        xfconf_live_set "$username" "$uid" xsettings /Gtk/FontName string "$SYSTEM_FONT" || \
            error_exit "Failed to update live XFCE xsettings for ${username}."
        xfconf_live_set "$username" "$uid" xsettings /Gtk/MonospaceFontName string "$SYSTEM_FONT" || \
            error_exit "Failed to update live XFCE monospace setting for ${username}."
        xfconf_live_set "$username" "$uid" xfce4-terminal /font-name string "$TERMINAL_FONT" || \
            error_exit "Failed to update live XFCE Terminal font for ${username}."
        xfconf_live_set "$username" "$uid" xfce4-terminal /font-use-system bool false || \
            error_exit "Failed to disable XFCE Terminal system-font mode for ${username}."
        live_xfconf=1
    else
        update_xfconf_xml "$username" "$xsettings_file" xsettings /Gtk/FontName string "$SYSTEM_FONT"
        update_xfconf_xml "$username" "$xsettings_file" xsettings /Gtk/MonospaceFontName string "$SYSTEM_FONT"
        chmod_user_file "$username" "$xsettings_file"

        update_xfconf_xml "$username" "$terminal_xconf_file" xfce4-terminal /font-name string "$TERMINAL_FONT"
        update_xfconf_xml "$username" "$terminal_xconf_file" xfce4-terminal /font-use-system bool false
        chmod_user_file "$username" "$terminal_xconf_file"
    fi

    # Legacy xfce4-terminal (< 1.1.0) compatibility.
    update_ini_value "$username" "$terminal_legacy_file" Configuration FontName "$TERMINAL_FONT"
    update_ini_value "$username" "$terminal_legacy_file" Configuration FontUseSystem FALSE
    chmod_user_file "$username" "$terminal_legacy_file"

    # GTK fallbacks. Only the actual supported UI font key is modified.
    update_gtk2_font "$username" "$gtk2_file" "$SYSTEM_FONT"
    update_ini_value "$username" "$gtk3_file" Settings gtk-font-name "$SYSTEM_FONT"
    update_ini_value "$username" "$gtk4_file" Settings gtk-font-name "$SYSTEM_FONT"
    chmod_user_file "$username" "$gtk2_file"
    chmod_user_file "$username" "$gtk3_file"
    chmod_user_file "$username" "$gtk4_file"

    if (( live_xfconf == 1 )); then
        log "  -> Configured user: ${username} (live xfconf)"
    else
        log "  -> Configured user: ${username}"
    fi
}

# -----------------------------
# Banner
# -----------------------------
printf '\n============================================================\n'
printf ' JetBrains Mono System Font Installer\n'
printf '============================================================\n\n'
printf 'UI font       : %s\n' "$SYSTEM_FONT"
printf 'Terminal font : %s\n' "$TERMINAL_FONT"
printf 'Version       : %s\n\n' "$JBM_VERSION"

# -----------------------------
# 1. Dependencies
# -----------------------------
log "[1/10] Checking dependencies..."
install_package_if_command_missing curl curl
install_package_if_command_missing fc-cache fontconfig
install_package_if_command_missing fc-match fontconfig
install_package_if_command_missing python3 python3
install_package_if_command_missing runuser util-linux
ensure_ca_certificates
log "  -> Dependencies OK"

# -----------------------------
# 2. Backup area
# -----------------------------
printf '\n'
log "[2/10] Preparing backup area..."
mkdir -p -- "$BACKUP_DIR"
: > "$CREATED_MANIFEST"
chmod 0700 -- "$BACKUP_DIR"
log "  -> Backup: ${BACKUP_DIR}"

# -----------------------------
# 3. Download
# -----------------------------
printf '\n'
log "[3/10] Downloading JetBrains Mono ${JBM_VERSION}..."
ZIP_FILE="${TMP_DIR}/JetBrainsMono.zip"

curl \
    --fail \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --retry 5 \
    --retry-delay 2 \
    --connect-timeout 15 \
    --max-time 180 \
    --silent \
    --show-error \
    --output "$ZIP_FILE" \
    "$JBM_URL"

[[ -s "$ZIP_FILE" ]] || error_exit "JetBrains Mono archive download failed."
log "  -> Download complete"

# -----------------------------
# 4. Validate + safe extract
# -----------------------------
printf '\n'
log "[4/10] Validating and extracting archive..."
EXTRACT_DIR="${TMP_DIR}/extracted"
mkdir -p -- "$EXTRACT_DIR"

python3 - "$ZIP_FILE" "$EXTRACT_DIR" <<'PY'
import os
import pathlib
import sys
import zipfile

archive, dest = sys.argv[1:3]
dest_path = pathlib.Path(dest).resolve()

with zipfile.ZipFile(archive) as zf:
    bad = zf.testzip()
    if bad is not None:
        raise SystemExit(f"CRC failure in ZIP member: {bad}")

    for info in zf.infolist():
        member = pathlib.PurePosixPath(info.filename)
        if member.is_absolute() or ".." in member.parts:
            raise SystemExit(f"Unsafe ZIP member path: {info.filename}")
        target = (dest_path / pathlib.Path(*member.parts)).resolve()
        try:
            target.relative_to(dest_path)
        except ValueError:
            raise SystemExit(f"ZIP member escapes destination: {info.filename}")

    zf.extractall(dest_path)
PY

log "  -> Archive integrity/path validation passed"

# -----------------------------
# 5. Install fonts atomically
# -----------------------------
printf '\n'
log "[5/10] Installing fonts system-wide..."
mkdir -p -- "$FONT_PARENT"
rm -rf -- "$FONT_STAGE_DIR" "$FONT_OLD_DIR"
mkdir -p -- "$FONT_STAGE_DIR"

STATIC_TTF_DIR="${EXTRACT_DIR}/fonts/ttf"
FONT_COUNT=0

copy_font_file() {
    local src="$1"
    local dest="${FONT_STAGE_DIR}/$(basename "$src")"

    if [[ -e "$dest" ]]; then
        error_exit "Duplicate font filename in archive: $(basename "$src")"
    fi

    install -m 0644 -- "$src" "$dest"
    FONT_COUNT=$((FONT_COUNT + 1))
}

if [[ -d "$STATIC_TTF_DIR" ]] && find "$STATIC_TTF_DIR" -maxdepth 1 -type f -iname '*.ttf' -print -quit | grep -q .; then
    while IFS= read -r -d '' font_file; do
        copy_font_file "$font_file"
    done < <(find "$STATIC_TTF_DIR" -maxdepth 1 -type f -iname '*.ttf' -print0 | sort -z)
else
    while IFS= read -r -d '' font_file; do
        copy_font_file "$font_file"
    done < <(
        find "$EXTRACT_DIR" -type f \
            \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) \
            -print0 | sort -z
    )
fi

(( FONT_COUNT > 0 )) || error_exit "No usable font files were found in the downloaded archive."

if [[ -e "$FONT_DIR" || -L "$FONT_DIR" ]]; then
    backup_path "$FONT_DIR"
else
    record_created_path "$FONT_DIR"
fi

if [[ -e "$FONT_DIR" || -L "$FONT_DIR" ]]; then
    mv -- "$FONT_DIR" "$FONT_OLD_DIR"
fi

if ! mv -- "$FONT_STAGE_DIR" "$FONT_DIR"; then
    if [[ -e "$FONT_OLD_DIR" || -L "$FONT_OLD_DIR" ]]; then
        mv -- "$FONT_OLD_DIR" "$FONT_DIR" || true
    fi
    error_exit "Failed to atomically install the new font directory."
fi

rm -rf -- "$FONT_OLD_DIR"
find "$FONT_DIR" -type d -exec chmod 0755 {} +
find "$FONT_DIR" -type f -exec chmod 0644 {} +

log "  -> Installed ${FONT_COUNT} static font files into ${FONT_DIR}"

# -----------------------------
# 6. Fontconfig
# -----------------------------
printf '\n'
log "[6/10] Configuring Fontconfig..."
prepare_file_change "$FONTCONFIG_FILE"
mkdir -p -- "$(dirname "$FONTCONFIG_FILE")"

cat > "${FONTCONFIG_FILE}.tmp.$$" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
    <!-- Prefer JetBrains Mono for the standard generic monospace family. -->
    <alias>
        <family>monospace</family>
        <prefer>
            <family>JetBrains Mono</family>
        </prefer>
    </alias>
</fontconfig>
EOF
chmod 0644 -- "${FONTCONFIG_FILE}.tmp.$$"
mv -f -- "${FONTCONFIG_FILE}.tmp.$$" "$FONTCONFIG_FILE"

fc-cache -f >/dev/null

if ! fc-match -f '%{family}\n' "$FONT_FAMILY" | head -n 1 | grep -Fqi "$FONT_FAMILY"; then
    error_exit "Fontconfig cannot find ${FONT_FAMILY} after installation."
fi
if ! fc-match -f '%{family}\n' monospace | head -n 1 | grep -Fqi "$FONT_FAMILY"; then
    error_exit "Fontconfig generic monospace does not resolve to ${FONT_FAMILY}."
fi

log "  -> Fontconfig resolves monospace to ${FONT_FAMILY}"

# -----------------------------
# 7. System GTK defaults
# -----------------------------
printf '\n'
log "[7/10] Configuring GTK system defaults..."

prepare_file_change "$GTK2_SYSTEM_FILE"
prepare_file_change "$GTK3_SYSTEM_FILE"
prepare_file_change "$GTK4_SYSTEM_FILE"

mkdir -p -- "$(dirname "$GTK2_SYSTEM_FILE")" "$(dirname "$GTK3_SYSTEM_FILE")" "$(dirname "$GTK4_SYSTEM_FILE")"
update_gtk2_font root "$GTK2_SYSTEM_FILE" "$SYSTEM_FONT"
update_ini_value root "$GTK3_SYSTEM_FILE" Settings gtk-font-name "$SYSTEM_FONT"
update_ini_value root "$GTK4_SYSTEM_FILE" Settings gtk-font-name "$SYSTEM_FONT"
chmod 0644 -- "$GTK2_SYSTEM_FILE" "$GTK3_SYSTEM_FILE" "$GTK4_SYSTEM_FILE"

log "  -> GTK 2/3/4 defaults configured without replacing unrelated settings"

# -----------------------------
# 8. XFCE system defaults
# -----------------------------
printf '\n'
log "[8/10] Configuring XFCE system defaults..."
mkdir -p -- "$XFCE_XCONF_SYSTEM_DIR" "$(dirname "$XFCE_TERMINAL_LEGACY_SYSTEM_FILE")"

prepare_file_change "$XFCE_XSETTINGS_SYSTEM_FILE"
prepare_file_change "$XFCE_TERMINAL_XCONF_SYSTEM_FILE"
prepare_file_change "$XFCE_TERMINAL_LEGACY_SYSTEM_FILE"

update_xfconf_xml root "$XFCE_XSETTINGS_SYSTEM_FILE" xsettings /Gtk/FontName string "$SYSTEM_FONT"
update_xfconf_xml root "$XFCE_XSETTINGS_SYSTEM_FILE" xsettings /Gtk/MonospaceFontName string "$SYSTEM_FONT"

update_xfconf_xml root "$XFCE_TERMINAL_XCONF_SYSTEM_FILE" xfce4-terminal /font-name string "$TERMINAL_FONT"
update_xfconf_xml root "$XFCE_TERMINAL_XCONF_SYSTEM_FILE" xfce4-terminal /font-use-system bool false

update_ini_value root "$XFCE_TERMINAL_LEGACY_SYSTEM_FILE" Configuration FontName "$TERMINAL_FONT"
update_ini_value root "$XFCE_TERMINAL_LEGACY_SYSTEM_FILE" Configuration FontUseSystem FALSE

chmod 0644 -- \
    "$XFCE_XSETTINGS_SYSTEM_FILE" \
    "$XFCE_TERMINAL_XCONF_SYSTEM_FILE" \
    "$XFCE_TERMINAL_LEGACY_SYSTEM_FILE"

log "  -> XFCE defaults configured; Theme/Icon/DPI settings preserved"

# -----------------------------
# 9. /etc/skel
# -----------------------------
printf '\n'
log "[9/10] Configuring /etc/skel..."

SKEL_XCONF_DIR="${SKEL_DIR}/.config/xfce4/xfconf/xfce-perchannel-xml"
SKEL_XSETTINGS_FILE="${SKEL_XCONF_DIR}/xsettings.xml"
SKEL_TERMINAL_XCONF_FILE="${SKEL_XCONF_DIR}/xfce4-terminal.xml"
SKEL_TERMINAL_LEGACY_FILE="${SKEL_DIR}/.config/xfce4/terminal/terminalrc"
SKEL_GTK2_FILE="${SKEL_DIR}/.gtkrc-2.0"
SKEL_GTK3_FILE="${SKEL_DIR}/.config/gtk-3.0/settings.ini"
SKEL_GTK4_FILE="${SKEL_DIR}/.config/gtk-4.0/settings.ini"

mkdir -p -- \
    "$SKEL_XCONF_DIR" \
    "$(dirname "$SKEL_TERMINAL_LEGACY_FILE")" \
    "$(dirname "$SKEL_GTK3_FILE")" \
    "$(dirname "$SKEL_GTK4_FILE")"

for path in \
    "$SKEL_XSETTINGS_FILE" \
    "$SKEL_TERMINAL_XCONF_FILE" \
    "$SKEL_TERMINAL_LEGACY_FILE" \
    "$SKEL_GTK2_FILE" \
    "$SKEL_GTK3_FILE" \
    "$SKEL_GTK4_FILE"; do
    prepare_file_change "$path"
done

update_xfconf_xml root "$SKEL_XSETTINGS_FILE" xsettings /Gtk/FontName string "$SYSTEM_FONT"
update_xfconf_xml root "$SKEL_XSETTINGS_FILE" xsettings /Gtk/MonospaceFontName string "$SYSTEM_FONT"
update_xfconf_xml root "$SKEL_TERMINAL_XCONF_FILE" xfce4-terminal /font-name string "$TERMINAL_FONT"
update_xfconf_xml root "$SKEL_TERMINAL_XCONF_FILE" xfce4-terminal /font-use-system bool false
update_ini_value root "$SKEL_TERMINAL_LEGACY_FILE" Configuration FontName "$TERMINAL_FONT"
update_ini_value root "$SKEL_TERMINAL_LEGACY_FILE" Configuration FontUseSystem FALSE
update_gtk2_font root "$SKEL_GTK2_FILE" "$SYSTEM_FONT"
update_ini_value root "$SKEL_GTK3_FILE" Settings gtk-font-name "$SYSTEM_FONT"
update_ini_value root "$SKEL_GTK4_FILE" Settings gtk-font-name "$SYSTEM_FONT"

chmod 0644 -- \
    "$SKEL_XSETTINGS_FILE" \
    "$SKEL_TERMINAL_XCONF_FILE" \
    "$SKEL_TERMINAL_LEGACY_FILE" \
    "$SKEL_GTK2_FILE" \
    "$SKEL_GTK3_FILE" \
    "$SKEL_GTK4_FILE"

log "  -> New-user defaults configured"

# -----------------------------
# 10. Existing users + validation
# -----------------------------
printf '\n'
log "[10/10] Configuring existing users and validating..."

UID_MIN="$(awk '$1 == "UID_MIN" && $2 ~ /^[0-9]+$/ {print $2; exit}' /etc/login.defs 2>/dev/null || true)"
UID_MIN="${UID_MIN:-1000}"

while IFS=: read -r username _ uid _ _ home _; do
    [[ -n "${username:-}" && -n "${home:-}" ]] || continue
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    [[ "$username" != "root" ]] || continue
    (( uid >= UID_MIN )) || continue
    configure_user "$username" "$home"
done < /etc/passwd

# Configure root exactly once.
configure_user root /root

# XML well-formedness checks for the system and skel files we control.
python3 - \
    "$XFCE_XSETTINGS_SYSTEM_FILE" \
    "$XFCE_TERMINAL_XCONF_SYSTEM_FILE" \
    "$SKEL_XSETTINGS_FILE" \
    "$SKEL_TERMINAL_XCONF_FILE" <<'PY'
import sys
import xml.etree.ElementTree as ET
for path in sys.argv[1:]:
    ET.parse(path)
PY

# Ensure no accidental CRLF was introduced into this script when copied.
if [[ -r "${BASH_SOURCE[0]}" ]] && grep -q $'\r$' "${BASH_SOURCE[0]}"; then
    error_exit "This script contains CRLF line endings. Convert it to Unix LF before reuse."
fi

printf '\n============================================================\n'
printf ' Verification\n'
printf '============================================================\n\n'
printf 'JetBrains Mono match:\n  '
fc-match "$FONT_FAMILY"
printf '\nGeneric monospace match:\n  '
fc-match monospace
printf '\nInstalled static font files: %s\n' "$FONT_COUNT"
printf 'Font directory              : %s\n' "$FONT_DIR"
printf 'Fontconfig file             : %s\n' "$FONTCONFIG_FILE"
printf 'Backup directory            : %s\n' "$BACKUP_DIR"

printf '\n============================================================\n'
printf ' DONE\n'
printf '============================================================\n\n'
printf 'UI font       : %s\n' "$SYSTEM_FONT"
printf 'Terminal font : %s\n' "$TERMINAL_FONT"
printf 'Reboot        : not normally required\n'
printf 'XFCE sessions : log out/in if a running session did not refresh immediately\n'
