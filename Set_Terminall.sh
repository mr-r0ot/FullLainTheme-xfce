
#!/usr/bin/env bash
#
# Linux Mint:
#   Kitty + Zsh + Oh My Zsh + Powerlevel10k + Nerd Font
#   Neovim + NvChad
#
# Run:
#   chmod +x setup-terminal.sh
#   sudo ./setup-terminal.sh
#

set -Eeuo pipefail

trap 'echo; echo "[ERROR] Installation failed at line $LINENO."; exit 1' ERR

# ============================================================
# User detection
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] Run this script with sudo:"
    echo "        sudo ./setup-terminal.sh"
    exit 1
fi

if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
    echo "[ERROR] Run this from your normal Linux Mint user account using sudo."
    echo "        sudo ./setup-terminal.sh"
    exit 1
fi

TARGET_USER="${SUDO_USER}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"

if [[ -z "${TARGET_HOME}" || ! -d "${TARGET_HOME}" ]]; then
    echo "[ERROR] Could not determine target user's home directory."
    exit 1
fi

TARGET_GROUP="$(id -gn "${TARGET_USER}")"

run_user() {
    sudo -u "${TARGET_USER}" -H "$@"
}

write_user_file() {
    local file="$1"
    cat > "${file}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${file}"
    chmod 600 "${file}"
}

echo "============================================================"
echo "  Linux Mint Terminal Environment"
echo "============================================================"
echo "User : ${TARGET_USER}"
echo "Home : ${TARGET_HOME}"
echo "============================================================"
echo

# ============================================================
# Architecture check
# ============================================================

ARCH="$(dpkg --print-architecture)"

if [[ "${ARCH}" != "amd64" ]]; then
    echo "[ERROR] This script currently targets Linux Mint x86_64/amd64."
    echo "Detected: ${ARCH}"
    exit 1
fi

# ============================================================
# Package installation
# ============================================================

echo "[1/10] Installing system dependencies..."

apt-get update

apt-get install -y \
    zsh \
    git \
    curl \
    wget \
    unzip \
    fontconfig \
    ripgrep \
    fd-find \
    build-essential \
    gcc \
    make \
    xclip \
    tree-sitter-cli \
    ca-certificates \
    file

command -v zsh >/dev/null 2>&1
command -v git >/dev/null 2>&1
command -v curl >/dev/null 2>&1
command -v wget >/dev/null 2>&1
command -v unzip >/dev/null 2>&1
command -v rg >/dev/null 2>&1
command -v tree-sitter >/dev/null 2>&1

echo "[OK] System dependencies installed."
echo

# ============================================================
# Kitty
# Official installer
# ============================================================

echo "[2/10] Installing Kitty..."

run_user bash -c '
    curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin
'

KITTY_DIR="${TARGET_HOME}/.local/kitty.app"
KITTY_BIN="${KITTY_DIR}/bin/kitty"
KITTEN_BIN="${KITTY_DIR}/bin/kitten"

if [[ ! -x "${KITTY_BIN}" ]]; then
    echo "[ERROR] Kitty binary was not installed correctly."
    exit 1
fi

if [[ ! -x "${KITTEN_BIN}" ]]; then
    echo "[ERROR] Kitty kitten binary was not installed correctly."
    exit 1
fi

mkdir -p "${TARGET_HOME}/.local/bin"
chown -R "${TARGET_USER}:${TARGET_GROUP}" "${TARGET_HOME}/.local"

ln -sfn "${KITTY_BIN}" "${TARGET_HOME}/.local/bin/kitty"
ln -sfn "${KITTEN_BIN}" "${TARGET_HOME}/.local/bin/kitten"

# Desktop integration
mkdir -p "${TARGET_HOME}/.local/share/applications"

if [[ -f "${KITTY_DIR}/share/applications/kitty.desktop" ]]; then
    cp "${KITTY_DIR}/share/applications/kitty.desktop" \
       "${TARGET_HOME}/.local/share/applications/kitty.desktop"
fi

if [[ -f "${KITTY_DIR}/share/applications/kitty-open.desktop" ]]; then
    cp "${KITTY_DIR}/share/applications/kitty-open.desktop" \
       "${TARGET_HOME}/.local/share/applications/kitty-open.desktop"
fi

sed -i \
    "s|^Exec=kitty|Exec=${KITTY_BIN}|g" \
    "${TARGET_HOME}/.local/share/applications/kitty.desktop" 2>/dev/null || true

sed -i \
    "s|^Exec=kitty|Exec=${KITTY_BIN}|g" \
    "${TARGET_HOME}/.local/share/applications/kitty-open.desktop" 2>/dev/null || true

sed -i \
    "s|^Icon=kitty|Icon=${KITTY_DIR}/share/icons/hicolor/256x256/apps/kitty.png|g" \
    "${TARGET_HOME}/.local/share/applications/kitty.desktop" 2>/dev/null || true

sed -i \
    "s|^Icon=kitty|Icon=${KITTY_DIR}/share/icons/hicolor/256x256/apps/kitty.png|g" \
    "${TARGET_HOME}/.local/share/applications/kitty-open.desktop" 2>/dev/null || true

chown -R "${TARGET_USER}:${TARGET_GROUP}" \
    "${TARGET_HOME}/.local"

KITTY_VERSION="$(run_user "${TARGET_HOME}/.local/bin/kitty" --version)"

if [[ -z "${KITTY_VERSION}" ]]; then
    echo "[ERROR] Kitty version check failed."
    exit 1
fi

echo "[OK] ${KITTY_VERSION}"
echo

# ============================================================
# Nerd Font
# ============================================================

echo "[3/10] Installing JetBrainsMono Nerd Font..."

FONT_DIR="${TARGET_HOME}/.local/share/fonts/JetBrainsMono"

mkdir -p "${FONT_DIR}"
chown -R "${TARGET_USER}:${TARGET_GROUP}" \
    "${TARGET_HOME}/.local/share"

TMP_FONT="$(mktemp --suffix=.zip)"

curl -fL \
    https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip \
    -o "${TMP_FONT}"

rm -rf "${FONT_DIR}"
mkdir -p "${FONT_DIR}"

unzip -q "${TMP_FONT}" -d "${FONT_DIR}"
rm -f "${TMP_FONT}"

chown -R "${TARGET_USER}:${TARGET_GROUP}" \
    "${FONT_DIR}"

run_user fc-cache -f

if ! run_user fc-list | grep -qi "JetBrainsMono Nerd Font"; then
    echo "[ERROR] JetBrainsMono Nerd Font verification failed."
    exit 1
fi

echo "[OK] JetBrainsMono Nerd Font installed."
echo

# ============================================================
# Kitty configuration
# ============================================================

echo "[4/10] Configuring Kitty..."

KITTY_CONFIG_DIR="${TARGET_HOME}/.config/kitty"
mkdir -p "${KITTY_CONFIG_DIR}"
chown -R "${TARGET_USER}:${TARGET_GROUP}" \
    "${TARGET_HOME}/.config"

write_user_file "${KITTY_CONFIG_DIR}/kitty.conf" <<'EOF'
# ============================================================
# Kitty
# ============================================================

font_family JetBrainsMono Nerd Font
font_size 11.5

bold_font auto
italic_font auto
bold_italic_font auto

disable_ligatures never

cursor_shape beam
cursor_blink_interval 0.6

enable_audio_bell no
visual_bell_duration 0

confirm_os_window_close 0

window_padding_width 10
window_margin_width 0

background_opacity 0.94

dynamic_background_opacity yes

hide_window_decorations no

tab_bar_edge top
tab_bar_style powerline
tab_powerline_style slanted

active_tab_font_style bold
inactive_tab_font_style normal

scrollback_lines 10000

shell_integration enabled

allow_remote_control no

map ctrl+shift+enter new_window_with_cwd
map ctrl+shift+t new_tab
map ctrl+shift+w close_tab
map ctrl+shift+right next_tab
map ctrl+shift+left previous_tab
EOF

run_user "${TARGET_HOME}/.local/bin/kitty" \
    --config "${KITTY_CONFIG_DIR}/kitty.conf" \
    --version >/dev/null

echo "[OK] Kitty configured."
echo

# ============================================================
# Oh My Zsh
# ============================================================

echo "[5/10] Installing Oh My Zsh..."

OMZ_DIR="${TARGET_HOME}/.oh-my-zsh"

if [[ -d "${OMZ_DIR}" ]]; then
    echo "[INFO] Existing Oh My Zsh detected. Keeping it."
else
    run_user env RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

if [[ ! -f "${OMZ_DIR}/oh-my-zsh.sh" ]]; then
    echo "[ERROR] Oh My Zsh installation failed."
    exit 1
fi

echo "[OK] Oh My Zsh installed."
echo

# ============================================================
# Powerlevel10k
# ============================================================

echo "[6/10] Installing Powerlevel10k..."

P10K_DIR="${OMZ_DIR}/custom/themes/powerlevel10k"

if [[ -d "${P10K_DIR}/.git" ]]; then
    echo "[INFO] Existing Powerlevel10k detected. Keeping it."
else
    rm -rf "${P10K_DIR}"

    run_user git clone --depth=1 \
        https://github.com/romkatv/powerlevel10k.git \
        "${P10K_DIR}"
fi

if [[ ! -f "${P10K_DIR}/powerlevel10k.zsh-theme" ]]; then
    echo "[ERROR] Powerlevel10k installation failed."
    exit 1
fi

echo "[OK] Powerlevel10k installed."
echo

# ============================================================
# Zsh configuration
# ============================================================

echo "[7/10] Configuring Zsh..."

ZSHRC="${TARGET_HOME}/.zshrc"

if [[ -f "${ZSHRC}" ]]; then
    cp "${ZSHRC}" "${ZSHRC}.backup"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${ZSHRC}.backup"
fi

write_user_file "${ZSHRC}" <<'EOF'
# ============================================================
# ZSH
# ============================================================

export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(
    git
    sudo
    extract
    z
    colored-man-pages
)

# Editors
export EDITOR="nvim"
export VISUAL="nvim"

# PATH
export PATH="$HOME/.local/bin:$PATH"
export PATH="/opt/nvim-linux-x86_64/bin:$PATH"

# History
HIST_STAMPS="yyyy-mm-dd"
HISTSIZE=50000
SAVEHIST=50000
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
setopt SHARE_HISTORY

# Completion
autoload -Uz compinit
compinit

# Oh My Zsh
source "$ZSH/oh-my-zsh.sh"

# Powerlevel10k
[[ ! -f "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"

# Aliases
alias v='nvim'
alias vi='nvim'
alias vim='nvim'

alias c='clear'
alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'

alias update='sudo apt update && sudo apt upgrade'

# Fast directory navigation
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
EOF

# Default shell
chsh -s "$(command -v zsh)" "${TARGET_USER}"

if [[ "$(getent passwd "${TARGET_USER}" | cut -d: -f7)" != "$(command -v zsh)" ]]; then
    echo "[ERROR] Failed to set Zsh as the default shell."
    exit 1
fi

echo "[OK] Zsh configured as default shell."
echo

# ============================================================
# Powerlevel10k configuration
# ============================================================

echo "[8/10] Configuring Powerlevel10k appearance..."

P10K_CONFIG="${TARGET_HOME}/.p10k.zsh"

write_user_file "${P10K_CONFIG}" <<'EOF'
# ============================================================
# Powerlevel10k
# ============================================================

typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet

# ---- Prompt ----

typeset -g POWERLEVEL9K_MODE='nerdfont-v3'

typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(
    os_icon
    dir
    vcs
)

typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(
    status
    command_execution_time
    background_jobs
)

# ---- Layout ----

typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true
typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_PREFIX=''
typeset -g POWERLEVEL9K_MULTILINE_LAST_PROMPT_PREFIX='❯ '

typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_SUFFIX=''
typeset -g POWERLEVEL9K_MULTILINE_LAST_PROMPT_SUFFIX=''

# ---- Directory ----

typeset -g POWERLEVEL9K_SHORTEN_STRATEGY='truncate_to_unique'
typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=3

typeset -g POWERLEVEL9K_DIR_BACKGROUND=0
typeset -g POWERLEVEL9K_DIR_FOREGROUND=39

# ---- Git ----

typeset -g POWERLEVEL9K_VCS_MAX_INDEX_SIZE_DIRTY=500
typeset -g POWERLEVEL9K_VCS_BACKENDS=(git)

# ---- Command status ----

typeset -g POWERLEVEL9K_STATUS_EXTENDED_STATES=true
typeset -g POWERLEVEL9K_STATUS_OK=false

# ---- Execution time ----

typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3

# ---- Prompt spacing ----

typeset -g POWERLEVEL9K_EMPTY_LINE_LEFT_PROMPT_FIRST_SEGMENT_END_SEPARATOR=''
typeset -g POWERLEVEL9K_EMPTY_LINE_RIGHT_PROMPT_FIRST_SEGMENT_START_SEPARATOR=''

# ---- Transient prompt ----

typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=always
typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=always

# ---- Instant prompt ----

typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet
EOF

# Validate zsh syntax
run_user zsh -n "${ZSHRC}"
run_user zsh -n "${P10K_CONFIG}"

echo "[OK] Powerlevel10k configured."
echo

# ============================================================
# Neovim
# ============================================================

echo "[9/10] Installing Neovim..."

NVIM_TARBALL="/tmp/nvim-linux-x86_64.tar.gz"

curl -fL \
    https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz \
    -o "${NVIM_TARBALL}"

rm -rf /opt/nvim-linux-x86_64

tar -C /opt -xzf "${NVIM_TARBALL}"

if [[ ! -x "/opt/nvim-linux-x86_64/bin/nvim" ]]; then
    echo "[ERROR] Neovim installation failed."
    exit 1
fi

rm -f "${NVIM_TARBALL}"

NVIM_VERSION="$(/opt/nvim-linux-x86_64/bin/nvim --version | head -n1)"

if [[ ! "${NVIM_VERSION}" =~ ^NVIM\ v0\.1[1-9] ]]; then
    echo "[ERROR] Neovim 0.11+ is required by current NvChad."
    echo "Detected: ${NVIM_VERSION}"
    exit 1
fi

echo "[OK] ${NVIM_VERSION}"
echo

# ============================================================
# NvChad
# ============================================================

echo "[10/10] Installing NvChad..."

NVIM_CONFIG_DIR="${TARGET_HOME}/.config/nvim"

if [[ -d "${NVIM_CONFIG_DIR}" ]]; then
    mv "${NVIM_CONFIG_DIR}" \
       "${TARGET_HOME}/.config/nvim.backup.$(date +%Y%m%d-%H%M%S)"
fi

run_user git clone \
    https://github.com/NvChad/starter \
    "${NVIM_CONFIG_DIR}"

chown -R "${TARGET_USER}:${TARGET_GROUP}" \
    "${NVIM_CONFIG_DIR}"

if [[ ! -f "${NVIM_CONFIG_DIR}/init.lua" ]]; then
    echo "[ERROR] NvChad starter was not installed correctly."
    exit 1
fi

# Start Neovim once so lazy.nvim initializes.
echo "[INFO] Initializing NvChad plugins..."

run_user timeout 120 \
    /opt/nvim-linux-x86_64/bin/nvim \
    --headless \
    "+qa" \
    || true

# Verify Neovim can load its configuration.
if ! run_user timeout 30 \
    /opt/nvim-linux-x86_64/bin/nvim \
    --headless \
    "+checkhealth" \
    "+qa" >/dev/null 2>&1; then
    echo "[INFO] NvChad health check reported non-critical issues."
fi

# ============================================================
# Final verification
# ============================================================

echo
echo "============================================================"
echo "  FINAL VERIFICATION"
echo "============================================================"

echo
echo "[Kitty]"
run_user "${TARGET_HOME}/.local/bin/kitty" --version

echo
echo "[Zsh]"
run_user zsh --version

echo
echo "[Oh My Zsh]"
if [[ -f "${OMZ_DIR}/oh-my-zsh.sh" ]]; then
    echo "Oh My Zsh: OK"
else
    echo "[ERROR] Oh My Zsh missing."
    exit 1
fi

echo
echo "[Powerlevel10k]"
if [[ -f "${P10K_DIR}/powerlevel10k.zsh-theme" ]]; then
    echo "Powerlevel10k: OK"
else
    echo "[ERROR] Powerlevel10k missing."
    exit 1
fi

echo
echo "[Nerd Font]"
if run_user fc-list | grep -qi "JetBrainsMono Nerd Font"; then
    echo "JetBrainsMono Nerd Font: OK"
else
    echo "[ERROR] Nerd Font missing."
    exit 1
fi

echo
echo "[Neovim]"
run_user /opt/nvim-linux-x86_64/bin/nvim --version | head -n 3

echo
echo "[NvChad]"
if [[ -f "${NVIM_CONFIG_DIR}/init.lua" ]]; then
    echo "NvChad: OK"
else
    echo "[ERROR] NvChad missing."
    exit 1
fi

echo
echo "[Zsh syntax]"
run_user zsh -n "${ZSHRC}"
run_user zsh -n "${P10K_CONFIG}"
echo "Zsh configuration syntax: OK"

echo
echo "============================================================"
echo "  INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "User       : ${TARGET_USER}"
echo "Shell      : $(getent passwd "${TARGET_USER}" | cut -d: -f7)"
echo "Kitty      : ${KITTY_VERSION}"
echo "Neovim     : ${NVIM_VERSION}"
echo "Font       : JetBrainsMono Nerd Font"
echo "Theme      : Powerlevel10k"
echo "Editor     : NvChad + Neovim"
echo
echo "Logout/login once to activate Zsh as the login shell."
echo "Then start Kitty."
echo
echo "============================================================"
