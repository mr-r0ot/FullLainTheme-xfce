```bash
#!/usr/bin/env bash

set -e

# ============================================================
# Linux Mint
# Kitty + Zsh + Oh My Zsh + Powerlevel10k
# JetBrainsMono Nerd Font + Neovim + NvChad
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo "Run with: sudo ./setup.sh"
    exit 1
fi

USER_NAME="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"

run_user() {
    sudo -u "$USER_NAME" -H "$@"
}

echo "==> Installing dependencies"
apt update
apt install -y zsh git curl wget unzip fontconfig ripgrep tree-sitter-cli

# ============================================================
# KITTY
# Official installer
# ============================================================

echo
echo "==> Installing Kitty"

run_user bash -c \
    'curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin'

mkdir -p "$HOME_DIR/.local/bin"

ln -sf "$HOME_DIR/.local/kitty.app/bin/kitty" \
       "$HOME_DIR/.local/bin/kitty"

ln -sf "$HOME_DIR/.local/kitty.app/bin/kitten" \
       "$HOME_DIR/.local/bin/kitten"

KITTY_VERSION="$(
    run_user "$HOME_DIR/.local/bin/kitty" --version
)"

echo "Kitty: $KITTY_VERSION"

# ============================================================
# NERD FONT
# ============================================================

echo
echo "==> Installing JetBrainsMono Nerd Font"

FONT_DIR="$HOME_DIR/.local/share/fonts/JetBrainsMono"

mkdir -p "$FONT_DIR"

wget -q \
    https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip \
    -O /tmp/JetBrainsMono.zip

unzip -q -o /tmp/JetBrainsMono.zip -d "$FONT_DIR"

rm -f /tmp/JetBrainsMono.zip

chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.local"

run_user fc-cache -f

run_user fc-list | grep -qi "JetBrainsMono Nerd Font"

echo "JetBrainsMono Nerd Font: OK"

# ============================================================
# KITTY CONFIG
# ============================================================

echo
echo "==> Configuring Kitty"

mkdir -p "$HOME_DIR/.config/kitty"

cat > "$HOME_DIR/.config/kitty/kitty.conf" <<'EOF'
font_family JetBrainsMono Nerd Font
font_size 11.5

enable_audio_bell no
confirm_os_window_close 0

background_opacity 0.94

cursor_shape beam
cursor_blink_interval 0.5

window_padding_width 8

tab_bar_edge top
tab_bar_style powerline
tab_powerline_style slanted

shell_integration enabled

scrollback_lines 10000
EOF

chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.config/kitty"

# ============================================================
# ZSH
# ============================================================

echo
echo "==> Installing Zsh"

ZSH_VERSION="$(zsh --version)"
echo "Zsh: $ZSH_VERSION"

chsh -s "$(command -v zsh)" "$USER_NAME"

# ============================================================
# OH MY ZSH
# Official installer
# ============================================================

echo
echo "==> Installing Oh My Zsh"

if [ ! -d "$HOME_DIR/.oh-my-zsh" ]; then
    run_user env \
        RUNZSH=no \
        CHSH=no \
        sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

[ -f "$HOME_DIR/.oh-my-zsh/oh-my-zsh.sh" ]

echo "Oh My Zsh: OK"

# ============================================================
# POWERLEVEL10K
# Official installation for Oh My Zsh
# ============================================================

echo
echo "==> Installing Powerlevel10k"

P10K_DIR="$HOME_DIR/.oh-my-zsh/custom/themes/powerlevel10k"

if [ ! -d "$P10K_DIR" ]; then
    run_user git clone --depth=1 \
        https://github.com/romkatv/powerlevel10k.git \
        "$P10K_DIR"
fi

[ -f "$P10K_DIR/powerlevel10k.zsh-theme" ]

echo "Powerlevel10k: OK"

# ============================================================
# ZSH CONFIG
# ============================================================

echo
echo "==> Configuring Zsh"

cat > "$HOME_DIR/.zshrc" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(
    git
    sudo
    extract
    z
)

source "$ZSH/oh-my-zsh.sh"

[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

export EDITOR="nvim"
export VISUAL="nvim"
export PATH="$HOME/.local/bin:/opt/nvim-linux-x86_64/bin:$PATH"

alias v='nvim'
alias vim='nvim'
alias vi='nvim'

alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
alias c='clear'
EOF

chown "$USER_NAME:$USER_NAME" "$HOME_DIR/.zshrc"

# ============================================================
# POWERLEVEL10K DEFAULT BEAUTIFUL CONFIG
# ============================================================

cat > "$HOME_DIR/.p10k.zsh" <<'EOF'
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

typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true

typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=always
typeset -g POWERLEVEL9K_INSTANT_PROMPT=quiet

typeset -g POWERLEVEL9K_SHORTEN_STRATEGY='truncate_to_unique'
typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=3

typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3
EOF

chown "$USER_NAME:$USER_NAME" "$HOME_DIR/.p10k.zsh"

run_user zsh -n "$HOME_DIR/.zshrc"
run_user zsh -n "$HOME_DIR/.p10k.zsh"

# ============================================================
# NEOVIM
# Official Linux release
# ============================================================

echo
echo "==> Installing Neovim"

wget -q \
    https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz \
    -O /tmp/nvim.tar.gz

rm -rf /opt/nvim-linux-x86_64

tar -C /opt -xzf /tmp/nvim.tar.gz

rm -f /tmp/nvim.tar.gz

NVIM_VERSION="$(
    /opt/nvim-linux-x86_64/bin/nvim --version | head -n 1
)"

echo "Neovim: $NVIM_VERSION"

case "$NVIM_VERSION" in
    "NVIM v0.11."*|"NVIM v0.12."*)
        ;;
    *)
        echo "ERROR: NvChad requires a supported modern Neovim version."
        exit 1
        ;;
esac

# ============================================================
# NVCHAD
# Official starter
# ============================================================

echo
echo "==> Installing NvChad"

NVIM_CONFIG="$HOME_DIR/.config/nvim"

if [ -d "$NVIM_CONFIG" ]; then
    rm -rf "$NVIM_CONFIG"
fi

run_user git clone \
    https://github.com/NvChad/starter \
    "$NVIM_CONFIG"

[ -f "$NVIM_CONFIG/init.lua" ]

chown -R "$USER_NAME:$USER_NAME" "$NVIM_CONFIG"

echo "NvChad: OK"

# Initialize NvChad once
run_user /opt/nvim-linux-x86_64/bin/nvim \
    --headless \
    "+qa" || true

# ============================================================
# FINAL CHECK
# ============================================================

echo
echo "============================================================"
echo "FINAL CHECK"
echo "============================================================"

echo
echo "Kitty:"
run_user "$HOME_DIR/.local/bin/kitty" --version

echo
echo "Zsh:"
zsh --version

echo
echo "Neovim:"
run_user /opt/nvim-linux-x86_64/bin/nvim --version | head -n 3

echo
echo "Oh My Zsh:"
[ -f "$HOME_DIR/.oh-my-zsh/oh-my-zsh.sh" ] && echo "OK"

echo
echo "Powerlevel10k:"
[ -f "$P10K_DIR/powerlevel10k.zsh-theme" ] && echo "OK"

echo
echo "NvChad:"
[ -f "$NVIM_CONFIG/init.lua" ] && echo "OK"

echo
echo "Nerd Font:"
run_user fc-list | grep -i "JetBrainsMono Nerd Font" | head -n 1

echo
echo "============================================================"
echo "DONE"
echo "============================================================"
echo
echo "Logout/login once, then launch Kitty."
echo "Zsh will become the default shell."
echo
```
