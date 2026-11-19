#!/usr/bin/env bash
set -euo pipefail

echo "=== Abhi Terminal Music Player — Universal Installer ==="

# 1. Detect Linux distro family via /etc/os-release
if [[ ! -f /etc/os-release ]]; then
  echo "Error: Cannot detect OS (/etc/os-release missing)."
  exit 1
fi
# shellcheck source=/dev/null
source /etc/os-release
DISTRO_CHECK="${ID:-} ${ID_LIKE:-}"

# 2. Install distro-specific system dependencies
if [[ "$DISTRO_CHECK" == *"ubuntu"* || "$DISTRO_CHECK" == *"debian"* || "$DISTRO_CHECK" == *"linuxmint"* ]]; then
  echo "Detected Debian/Ubuntu/Mint family ($PRETTY_NAME)"
  sudo apt-get update
  sudo apt-get install -y \
    nano tmux mpv socat jq fzf \
    python3 python3-pip python3-venv \
    curl unzip ffmpeg libnotify-bin
  sudo apt-get install -y cava || echo "Note: 'cava' not in default apt repos; skipping."

elif [[ "$DISTRO_CHECK" == *"fedora"* || "$DISTRO_CHECK" == *"rhel"* ]]; then
  echo "Detected Fedora/RHEL family ($PRETTY_NAME)"
  sudo dnf install -y \
    nano tmux cava mpv socat jq fzf \
    python3 python3-pip curl unzip ffmpeg libnotify

elif [[ "$DISTRO_CHECK" == *"arch"* || "$DISTRO_CHECK" == *"cachyos"* ]]; then
  echo "Detected Arch family ($PRETTY_NAME)"
  sudo pacman -Sy --needed --noconfirm \
    nano tmux mpv socat jq fzf \
    python python-pip curl unzip ffmpeg libnotify
  sudo pacman -S --needed --noconfirm cava || echo "Note: Install 'cava' from AUR if needed."

else
  echo "Unsupported distro: $PRETTY_NAME"
  echo "Please install manually: tmux mpv socat jq fzf python3 curl unzip ffmpeg cava"
  exit 1
fi

# 3. Install Deno non-interactively (for yt-dlp JS challenges)
if ! command -v deno >/dev/null 2>&1 && [[ ! -x "$HOME/.deno/bin/deno" ]]; then
  curl -fsSL https://deno.land/install.sh | sh -s -- -y
fi

# 4. Create directories and isolated Python virtual environments
mkdir -p \
  "$HOME/.local/bin" \
  "$HOME/.local/share/music-player/playlists" \
  "$HOME/.config/music-player" \
  "$HOME/.config/cava"

python3 -m venv "$HOME/.local/share/music-player/yt-dlp-venv"
"$HOME/.local/share/music-player/yt-dlp-venv/bin/pip" install -U pip "yt-dlp[default]"

python3 -m venv "$HOME/.local/share/music-player/radio-venv"
"$HOME/.local/share/music-player/radio-venv/bin/pip" install -U pip ytmusicapi

python3 -m venv "$HOME/.local/share/music-player/youtube-venv"
"$HOME/.local/share/music-player/youtube-venv/bin/pip" install -U pip \
  google-api-python-client google-auth-oauthlib google-auth-httplib2

# 5. Deploy scripts from repo (works whether cloned or downloaded via curl)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -f "$SCRIPT_DIR"/bin/* "$HOME/.local/bin/"
chmod 755 "$HOME/.local/bin/"*
cp -f "$SCRIPT_DIR"/share/stop-on-error.lua "$HOME/.local/share/music-player/"

# 6. Write clean cava config if none exists (smooth on Xfce/Ubuntu/KDE terminals)
if [[ ! -f "$HOME/.config/cava/config" ]]; then
  cat <<'CAVA_EOF' > "$HOME/.config/cava/config"
[general]
framerate = 60
autosens = 1

[input]
method = pulse
source = auto

[output]
method = ncurses
CAVA_EOF
fi

# 7. Create global symlinks so 'music' works immediately in any terminal
[[ -x "$HOME/.deno/bin/deno" ]] && sudo ln -sfn "$HOME/.deno/bin/deno" /usr/local/bin/deno
sudo ln -sfn "$HOME/.local/bin/music" /usr/local/bin/music
sudo ln -sfn "$HOME/.local/bin/music-control" /usr/local/bin/music-control
sudo ln -sfn "$HOME/.local/bin/music-radio" /usr/local/bin/music-radio
sudo ln -sfn "$HOME/.local/bin/music-youtube-export.py" /usr/local/bin/music-youtube-export.py

echo "=== INSTALLATION COMPLETE! Run: music ==="
