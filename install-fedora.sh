#!/usr/bin/env bash
set -euo pipefail

echo "=== Installing Abhi Terminal Music Player (Fedora) ==="

# 1. Install system dependencies
sudo dnf install -y nano tmux cava mpv socat jq fzf python3 python3-pip curl unzip ffmpeg libnotify

# 2. Install Deno (required by yt-dlp for YouTube JS challenges)
if ! command -v deno >/dev/null 2>&1 && [[ ! -x "$HOME/.deno/bin/deno" ]]; then
  curl -fsSL https://deno.land/install.sh | sh -s -- -y
fi

# 3. Create directories and Python virtual environments
mkdir -p "$HOME/.local/bin" "$HOME/.local/share/music-player/playlists" "$HOME/.config/music-player"

python3 -m venv "$HOME/.local/share/music-player/yt-dlp-venv"
"$HOME/.local/share/music-player/yt-dlp-venv/bin/pip" install -U pip "yt-dlp[default]"

python3 -m venv "$HOME/.local/share/music-player/radio-venv"
"$HOME/.local/share/music-player/radio-venv/bin/pip" install -U pip ytmusicapi

# 4. Copy scripts from this repo and make them executable
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -f "$SCRIPT_DIR"/bin/* "$HOME/.local/bin/"
chmod +x "$HOME/.local/bin/"*
cp -f "$SCRIPT_DIR"/share/stop-on-error.lua "$HOME/.local/share/music-player/"

# 5. Create global symlinks
sudo ln -sfn "$HOME/.local/bin/music" /usr/local/bin/music
[[ -f "$HOME/.local/bin/ytv" ]] && sudo ln -sfn "$HOME/.local/bin/ytv" /usr/local/bin/ytv

echo "=== INSTALLATION COMPLETE! Run: music ==="
