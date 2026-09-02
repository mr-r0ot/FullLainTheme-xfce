
#!/usr/bin/env bash

set -e

# ============================================================
# Linux Mint
# Kitty + Zsh + Oh My Zsh + Powerlevel10k
# JetBrainsMono Nerd Font + Neovim + NvChad
# Run: sudo ./setup.sh
# ============================================================

[ "$EUID" -eq 0 ] || {
    echo "Run: sudo ./setup.sh"
    exit 1
}

USER_NAME="${SUDO_USER:-$USER}"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"

run_user() {
    sudo -u "$USER_NAME" -H "$@"
}

echo "==> Disabling CD/DVD repositories"
find /etc/apt -type f \( -name "*.list" -o -name "*.sources" \) -exec \
    sed -i '/^[[:space:]]*deb[[:space:]]\+cdrom:/s/^/#/' {} \;

echo "==> Installing dependencies"
apt-get update
apt-get install -y zsh git curl wget unzip fontconfig ripgrep tree-sitter-cli

# ------------------------------------------------------------
# Versions
# ------------------------------------------------------------

echo
echo "==> Checking dependencies"

git --version
curl --version | head -n 1
wget --version | head -n 1
zsh --version
rg --version | head -n 1
tree-sitter --version

# ------------------------------------------------------------
# Kitty
# Official installer
# ------------------------------------------------------------

echo
echo "==> Installing Kitty"

run_user bash -c \
'curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin'

mkdir -p "$HOME_DIR/.local/bin"

ln -sf "$HOME_DIR/.local/kitty.app/bin/kitty" \
       "$HOME_DIR/.local/bin/kitty"

ln -sf "$HOME_DIR/.local/kitty.app/bin/kitten" \
       "$HOME_DIR/.local/bin/kitten"

run_user "$HOME_DIR/.local/bin/kitty" --version

# ------------------------------------------------------------
# Nerd Font
# ------------------------------------------------------------

echo
echo "==> Installing JetBrainsMono Nerd Font"

mkdir -p "$HOME_DIR/.local/share/fonts/JetBrainsMono"

wget -q \
https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip \
-O /tmp/JetBrainsMono.zip

unzip -q -o /tmp/JetBrainsMono.zip \
-d "$HOME_DIR/.local/share/fonts/JetBrainsMono"

rm /tmp/JetBrainsMono.zip

chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.local"

run_user fc-cache -f

run_user fc-list | grep -qi "JetBrainsMono Nerd Font"

echo "JetBrainsMono Nerd Font: OK"

# ------------------------------------------------------------
# Kitty config
# ------------------------------------------------------------

mkdir -p "$HOME_DIR/.config/kitty"

cat > "$HOME_DIR/.config/kitty/kitty.conf" <<'EOF'
font_family JetBrainsMono Nerd Font
font_size 11.5

background_opacity 0.94

cursor_shape beam
cursor_blink_interval 0.5

enable_audio_bell no
confirm_os_window_close 0

window_padding_width 8

tab_bar_edge top
tab_bar_style powerline
tab_powerline_style slanted

shell_integration enabled
scrollback_lines 10000
EOF

chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.config/kitty"

# ------------------------------------------------------------
# Oh My Zsh
# Official installer
# ------------------------------------------------------------

echo
echo "==> Installing Oh My Zsh"

run_user env RUNZSH=no CHSH=no \
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

[ -f "$HOME_DIR/.oh-my-zsh/oh-my-zsh.sh" ]

# ------------------------------------------------------------
# Powerlevel10k
# Official Oh My Zsh installation
# ------------------------------------------------------------

echo
echo "==> Installing Powerlevel10k"

run_user git clone --depth=1 \
https://github.com/romkatv/powerlevel10k.git \
"$HOME_DIR/.oh-my-zsh/custom/themes/powerlevel10k"

[ -f "$HOME_DIR/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme" ]

# ------------------------------------------------------------
# Zsh config
# ------------------------------------------------------------

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

export EDITOR="nvim"
export VISUAL="nvim"

export PATH="$HOME/.local/bin:/opt/nvim-linux-x86_64/bin:$PATH"
EOF

chown "$USER_NAME:$USER_NAME" "$HOME_DIR/.zshrc"

chsh -s "$(command -v zsh)" "$USER_NAME"

run_user zsh -n "$HOME_DIR/.zshrc"

# ------------------------------------------------------------
# Neovim
# Official Linux x86_64 archive
# ------------------------------------------------------------

echo
echo "==> Installing Neovim"

wget -q \
https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz \
-O /tmp/nvim.tar.gz

rm -rf /opt/nvim-linux-x86_64

tar -C /opt -xzf /tmp/nvim.tar.gz

rm /tmp/nvim.tar.gz

/opt/nvim-linux-x86_64/bin/nvim --version

# ------------------------------------------------------------
# NvChad
# Official starter
# ------------------------------------------------------------

echo
echo "==> Installing NvChad"

rm -rf "$HOME_DIR/.config/nvim"

run_user git clone \
https://github.com/NvChad/starter \
"$HOME_DIR/.config/nvim"

[ -f "$HOME_DIR/.config/nvim/init.lua" ]

chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.config/nvim"

# ------------------------------------------------------------
# Final version checks
# ------------------------------------------------------------

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
echo "Git:"
git --version

echo
echo "Ripgrep:"
rg --version | head -n 1

echo
echo "Tree-sitter:"
tree-sitter --version

echo
echo "Oh My Zsh:"
[ -f "$HOME_DIR/.oh-my-zsh/oh-my-zsh.sh" ] && echo "OK"

echo
echo "Powerlevel10k:"
[ -f "$HOME_DIR/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme" ] && echo "OK"

echo
echo "NvChad:"
[ -f "$HOME_DIR/.config/nvim/init.lua" ] && echo "OK"

echo
echo "Nerd Font:"
run_user fc-list | grep -i "JetBrainsMono Nerd Font" | head -n 1

echo
echo "============================================================"
echo "DONE"
echo "============================================================"
echo
echo "Logout/login once, then open Kitty."
