#!/usr/bin/env bash
set -euo pipefail

echo "========================================================"
echo "  Abhi Terminal Music Player — Universal 1-Click Setup  "
echo "  Supports: Fedora, Linux Mint, Ubuntu, Debian          "
echo "========================================================"

# 1. Detect OS and Install System Dependencies
if command -v apt-get >/dev/null 2>&1; then
    echo "[1/5] Detected Debian/Ubuntu/Linux Mint (APT)..."
    sudo apt-get update -y
    sudo apt-get install -y nano tmux cava mpv socat jq fzf python3 python3-venv python3-pip curl unzip ffmpeg libnotify-bin
elif command -v dnf >/dev/null 2>&1; then
    echo "[1/5] Detected Fedora (DNF)..."
    sudo dnf install -y nano tmux cava mpv socat jq fzf python3 python3-pip curl unzip libnotify
    if ! command -v ffmpeg >/dev/null 2>&1; then
        sudo dnf install -y ffmpeg-free || sudo dnf install -y ffmpeg
    fi
else
    echo "Error: Unsupported package manager. Only APT (Mint/Ubuntu/Debian) and DNF (Fedora) are supported."
    exit 1
fi

# 2. Create Required Directories
echo "[2/5] Creating directories..."
mkdir -p "$HOME/.local/bin" \
         "$HOME/.config/cava" \
         "$HOME/.config/music-player" \
         "$HOME/.local/share/music-player/playlists" \
         "$HOME/.local/share/music-player/youtube-exports" \
         "$HOME/Music" \
         "$HOME/Videos"

# 3. Install Deno (Required by yt-dlp for YouTube JS Challenges)
echo "[3/5] Installing Deno runtime..."
if [[ ! -x "$HOME/.deno/bin/deno" ]] && ! command -v deno >/dev/null 2>&1; then
    curl -fsSL https://deno.land/install.sh -o /tmp/music-deno-install.sh
    sh /tmp/music-deno-install.sh -y
fi
export Deno_DIR="$HOME/.deno"
export PATH="$HOME/.local/bin:$HOME/.deno/bin:$PATH"

# 4. Build Isolated Python Virtual Environments (Cleanly & Visibly)
echo "[4/5] Building Python Virtual Environments..."

rm -rf "$HOME/.local/share/music-player/yt-dlp-venv" \
       "$HOME/.local/share/music-player/radio-venv" \
       "$HOME/.local/share/music-player/youtube-venv"

echo "  -> Setting up yt-dlp (nightly)..."
python3 -m venv "$HOME/.local/share/music-player/yt-dlp-venv"
"$HOME/.local/share/music-player/yt-dlp-venv/bin/python" -m pip install -U pip
"$HOME/.local/share/music-player/yt-dlp-venv/bin/python" -m pip install -U --pre 'yt-dlp[default]'
ln -sfn "$HOME/.local/share/music-player/yt-dlp-venv/bin/yt-dlp" "$HOME/.local/bin/yt-dlp"

echo "  -> Setting up Song Radio (ytmusicapi)..."
python3 -m venv "$HOME/.local/share/music-player/radio-venv"
"$HOME/.local/share/music-player/radio-venv/bin/python" -m pip install -U pip ytmusicapi

echo "  -> Setting up YouTube Exporter (Google OAuth)..."
python3 -m venv "$HOME/.local/share/music-player/youtube-venv"
"$HOME/.local/share/music-player/youtube-venv/bin/python" -m pip install -U pip google-api-python-client google-auth-oauthlib

# 5. Write All Scripts and Configs
echo "[5/5] Writing player scripts and configuration files..."

# 5.1 stop-on-error.lua
cat << 'EOF' > "$HOME/.local/share/music-player/stop-on-error.lua"
local current = nil
local retry_timer = nil
local retry_id = nil

local function cancel_retry()
    if retry_timer then
        retry_timer:kill()
        retry_timer = nil
    end
    retry_id = nil
end

mp.register_event("start-file", function(event)
    local next_attempt = 1
    if current and retry_id == event.playlist_entry_id then
        next_attempt = current.attempt + 1
    end

    cancel_retry()
    current = {
        id = event.playlist_entry_id,
        attempt = next_attempt,
        handled = false
    }
end)

local function handle_failure()
    local failed = current
    if not failed or failed.handled then return end
    failed.handled = true
    mp.commandv("playlist-play-index", "none")

    if failed.attempt >= 3 then
        mp.msg.error("Attempt 3/3 failed; stopped playlist playback")
        return
    end

    mp.msg.warn(
        ("Attempt %d/3 failed; retrying the same song in 1 second")
        :format(failed.attempt)
    )

    retry_timer = mp.add_timeout(1, function()
        retry_timer = nil
        if current ~= failed then return end

        for index, entry in ipairs(mp.get_property_native("playlist", {})) do
            if entry.id == failed.id then
                retry_id = failed.id
                mp.commandv("playlist-play-index", index - 1)
                return
            end
        end

        mp.msg.warn("Retry cancelled: song is no longer in the queue")
    end)
end

mp.add_hook("on_load_fail", 50, handle_failure)

mp.register_event("end-file", function(event)
    if event.reason == "error" and current
        and current.id == event.playlist_entry_id then
        handle_failure()
    end
end)

mp.add_hook("on_after_end_file", 50, function() end)
mp.register_event("shutdown", cancel_retry)
EOF

# 5.2 cava config
cat << 'EOF' > "$HOME/.config/cava/config"
[general]
framerate = 60
autosens = 1
overshoot = 10
sensitivity = 70
bars = 0
bar_width = 2
bar_spacing = 1

[input]
method = pulse
source = auto

[color]
gradient = 1
gradient_count = 8
gradient_color_1 = '#59cc33'
gradient_color_2 = '#80cc33'
gradient_color_3 = '#a6cc33'
gradient_color_4 = '#cccc33'
gradient_color_5 = '#cca633'
gradient_color_6 = '#cc8033'
gradient_color_7 = '#cc5933'
gradient_color_8 = '#cc3333'
EOF

# 5.3 music-control
cat << 'EOF' > "$HOME/.local/bin/music-control"
#!/bin/bash

SOCK="/tmp/abhi-music.sock"
PLAYLIST_DIR="$HOME/.local/share/music-player/playlists"
YTDLP_BIN="$HOME/.local/share/music-player/yt-dlp-venv/bin/yt-dlp"
[[ ! -x "$YTDLP_BIN" ]] && YTDLP_BIN="yt-dlp"
export PATH="$HOME/.local/bin:$HOME/.deno/bin:$PATH"

RESET=$'\033[0m'
TITLE_COLOR=$'\033[38;2;88;166;255m'
PLAY_COLOR=$'\033[38;2;63;185;80m'
PAUSE_COLOR=$'\033[38;2;227;179;65m'
PROGRESS_COLOR=$'\033[38;2;57;211;83m'
EMPTY_COLOR=$'\033[38;2;72;79;88m'
KEY_STYLE=$'\033[1;38;2;255;255;255;48;2;31;111;235m'
MUTED_COLOR=$'\033[38;2;125;133;144m'

declare -A QUEUE_TITLES

send() {
    printf '%s\n' "$1" | socat - "$SOCK" 2>/dev/null
}

get_property() {
    local prop="$1"
    send "{\"command\":[\"get_property\",\"$prop\"]}" |
        jq -r '.data // empty' 2>/dev/null
}

command() {
    printf '%s\n' "$1" | socat - "$SOCK" >/dev/null 2>&1
}

format_time() {
    local seconds="${1%.*}"
    [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0
    printf "%02d:%02d" $((seconds / 60)) $((seconds % 60))
}

search_song() {
    clear
    printf '\n Search for a song\n\n'
    printf ' Search: '
    IFS= read -r query
    [[ -z "$query" ]] && return

    clear
    printf ' Searching...\n'
    selection=$("$YTDLP_BIN" "ytsearch20:$query" \
        --flat-playlist \
        --print "%(title)s | https://youtube.com/watch?v=%(id)s" \
        2>/dev/null | fzf --layout=reverse)

    [[ -z "$selection" ]] && return
    url="${selection##* | }"
    command "{\"command\":[\"loadfile\",\"$url\",\"replace\"]}"
    sleep 1
}

add_to_queue() {
    clear
    printf '\n Add a song to queue\n\n'
    printf ' Search: '
    IFS= read -r query
    [[ -z "$query" ]] && return

    clear
    printf ' Searching...\n'
    selection=$("$YTDLP_BIN" "ytsearch20:$query" \
        --flat-playlist \
        --print "%(title)s | https://youtube.com/watch?v=%(id)s" \
        2>/dev/null | fzf --layout=reverse)

    [[ -z "$selection" ]] && return
    url="${selection##* | }"
    title="${selection% | https://youtube.com/watch?v=*}"
    [[ -z "$url" ]] && return

    QUEUE_TITLES["$url"]="$title"
    command "{\"command\":[\"loadfile\",\"$url\",\"append-play\"]}"
    sleep 0.2
}

show_queue() {
    local playlist count i url title current marker
    local selection number
    local -a rows=()

    playlist=$(send '{"command":["get_property","playlist"]}')
    count=$(printf '%s' "$playlist" | jq -r '(.data // []) | length' 2>/dev/null)

    if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count == 0 )); then
        clear
        printf '\n The current queue is empty.\n'
        printf '\n Press any key to return...'
        IFS= read -rsn1
        return
    fi

    for ((i=0; i<count; i++)); do
        url=$(printf '%s' "$playlist" | jq -r ".data[$i].filename // empty")
        title=""
        if [[ -n "$url" ]]; then
            title="${QUEUE_TITLES[$url]:-}"
        fi
        if [[ -z "$title" ]]; then
            title=$(printf '%s' "$playlist" | jq -r ".data[$i].title // empty")
        fi
        [[ -z "$title" ]] && title="${url:-Unknown song}"

        title="${title//$'\n'/ }"
        title="${title//$'\r'/ }"
        title="${title//$'\t'/ }"

        current=$(printf '%s' "$playlist" | jq -r ".data[$i].current // false")
        marker=" "
        [[ "$current" == "true" ]] && marker="▶"

        rows+=("$(printf '%d\t%s %s' "$((i + 1))" "$marker" "$title")")
    done

    selection=$(printf '%s\n' "${rows[@]}" |
        fzf --layout=reverse --no-sort \
            --prompt="Song: " \
            --header="Type a name or number | ENTER: play | ESC: back") || return

    [[ -z "$selection" ]] && return
    number="${selection%%$'\t'*}"
    [[ "$number" =~ ^[0-9]+$ ]] || return
    (( number >= 1 && number <= count )) || return

    command "{\"command\":[\"playlist-play-index\",$((number - 1))]}"
    command '{"command":["set_property","pause",false]}'
}

create_playlist() {
    clear
    printf '\n ===== CREATE PLAYLIST =====\n\n'
    printf ' Playlist name: '
    IFS= read -r name
    [[ -z "$name" ]] && return
    name="${name//\//-}"
    file="$PLAYLIST_DIR/$name.txt"

    if [[ -e "$file" ]]; then
        printf '\n Playlist "%s" already exists.\n' "$name"
    else
        touch "$file"
        printf '\n Playlist "%s" created successfully.\n' "$name"
    fi
    printf '\n Press any key to return...'
    IFS= read -rsn1
}

add_current_to_playlist() {
    clear
    printf '\n ===== ADD CURRENT SONG =====\n\n'
    title=$(get_property "media-title")
    url=$(get_property "path")

    if [[ -z "$title" || -z "$url" ]]; then
        printf ' No song is currently playing.\n'
        printf '\n Press any key to return...'
        IFS= read -rsn1
        return
    fi

    printf ' Current song:\n %s\n\n' "$title"
    playlists=("$PLAYLIST_DIR"/*.txt)

    if [[ ! -e "${playlists[0]}" ]]; then
        printf ' No playlists found.\n'
        printf ' Create one first using option 3.\n'
        printf '\n Press any key to return...'
        IFS= read -rsn1
        return
    fi

    printf ' Choose playlist:\n\n'
    selection=$(
        for file in "${playlists[@]}"; do
            basename "$file" .txt
        done | fzf --layout=reverse
    )
    [[ -z "$selection" ]] && return
    file="$PLAYLIST_DIR/$selection.txt"

    if grep -Fq " | $url" "$file" 2>/dev/null; then
        printf '\n Song already exists in "%s".\n' "$selection"
    else
        printf '%s | %s\n' "$title" "$url" >> "$file"
        printf '\n Added to "%s" successfully.\n' "$selection"
    fi
    printf '\n Press any key to return...'
    IFS= read -rsn1
}

add_queue_to_playlist() {
    local playlist count selection file
    local url title mpv_title current
    local added=0 duplicates=0 skipped=0
    local -a playlists

    clear
    printf '\n ===== ADD QUEUE TO PLAYLIST =====\n\n'
    playlist=$(send '{"command":["get_property","playlist"]}')
    count=$(printf '%s' "$playlist" | jq -r '.data | length // 0')

    if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count == 0 )); then
        printf ' The current queue is empty.\n'
        printf '\n Press any key to return...'
        IFS= read -rsn1
        return
    fi

    playlists=("$PLAYLIST_DIR"/*.txt)
    if [[ ! -e "${playlists[0]}" ]]; then
        printf ' No permanent playlists found.\n'
        printf ' Create a playlist first.\n'
        printf '\n Press any key to return...'
        IFS= read -rsn1
        return
    fi

    printf ' Choose the destination playlist:\n\n'
    selection=$(
        for file in "${playlists[@]}"; do
            basename "$file" .txt
        done | fzf --layout=reverse
    )
    [[ -z "$selection" ]] && return
    file="$PLAYLIST_DIR/$selection.txt"

    for ((i=0; i<count; i++)); do
        url=$(printf '%s' "$playlist" | jq -r ".data[$i].filename // empty")
        mpv_title=$(printf '%s' "$playlist" | jq -r ".data[$i].title // empty")
        current=$(printf '%s' "$playlist" | jq -r ".data[$i].current // false")

        if [[ -n "${QUEUE_TITLES["$url"]:-}" ]]; then
            title="${QUEUE_TITLES["$url"]}"
        elif [[ -n "$mpv_title" ]]; then
            title="$mpv_title"
        elif [[ "$current" == "true" ]]; then
            title=$(get_property "media-title")
        else
            title=""
        fi

        if [[ -z "$url" || -z "$title" ]]; then
            ((skipped++))
            continue
        fi

        if grep -Fq " | $url" "$file" 2>/dev/null; then
            ((duplicates++))
        else
            printf '%s | %s\n' "$title" "$url" >> "$file"
            ((added++))
        fi
    done

    printf '\n Added: %d song(s)\n' "$added"
    printf ' Already present: %d song(s)\n' "$duplicates"
    if (( skipped > 0 )); then
        printf ' Skipped: %d song(s)\n' "$skipped"
    fi
    printf '\n Press any key to return...'
    IFS= read -rsn1
}

play_playlist() {
    clear
    printf '\n ===== PLAY PLAYLIST =====\n\n'
    playlists=("$PLAYLIST_DIR"/*.txt)

    if [[ ! -e "${playlists[0]}" ]]; then
        printf ' No playlists found.\n'
        printf '\n Press any key to return...'
        IFS= read -rsn1
        return
    fi

    selection=$(
        for file in "${playlists[@]}"; do
            basename "$file" .txt
        done | fzf --layout=reverse
    )
    [[ -z "$selection" ]] && return
    file="$PLAYLIST_DIR/$selection.txt"

    if [[ ! -s "$file" ]]; then
        printf '\n Playlist "%s" is empty.\n' "$selection"
        printf '\n Press any key to return...'
        IFS= read -rsn1
        return
    fi

    first=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        title="${line% | *}"
        url="${line##* | }"
        [[ -z "$url" ]] && continue
        [[ "$url" != http* ]] && continue

        QUEUE_TITLES["$url"]="$title"
        if (( first )); then
            command "{\"command\":[\"loadfile\",\"$url\",\"replace\"]}"
            first=0
        else
            command "{\"command\":[\"loadfile\",\"$url\",\"append-play\"]}"
        fi
    done < "$file"
    sleep 1
}

view_playlist() {
    clear
    printf '\n ===== VIEW / MANAGE PLAYLIST =====\n\n'
    playlists=("$PLAYLIST_DIR"/*.txt)

    if [[ ! -e "${playlists[0]}" ]]; then
        printf ' No playlists found.\n'
        printf '\n Press any key to return...'
        IFS= read -rsn1
        return
    fi

    selection=$(
        for file in "${playlists[@]}"; do
            basename "$file" .txt
        done | fzf --layout=reverse
    )
    [[ -z "$selection" ]] && return
    file="$PLAYLIST_DIR/$selection.txt"

    while true; do
        clear
        printf '\n ===== %s =====\n\n' "$selection"
        if [[ ! -s "$file" ]]; then
            printf ' Playlist is empty.\n'
            printf '\n Press any key to return...'
            IFS= read -rsn1
            return
        fi

        song=$(
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                printf '%s\n' "${line% | *}"
            done < "$file" |
                fzf --layout=reverse --header="ENTER = select song to remove | ESC = back"
        )
        [[ -z "$song" ]] && return

        clear
        printf '\n ===== REMOVE SONG =====\n\n'
        printf ' %s\n\n' "$song"
        printf ' Remove this song from "%s"? [y/N]: ' "$selection"
        IFS= read -rsn1 confirm
        printf '\n'

        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            temp_file=$(mktemp)
            while IFS= read -r line; do
                title="${line% | *}"
                if [[ "$title" != "$song" ]]; then
                    printf '%s\n' "$line"
                fi
            done < "$file" > "$temp_file"
            mv "$temp_file" "$file"
            printf '\n Song removed successfully.\n'
            sleep 1
        fi
    done
}

delete_playlist() {
    clear
    printf '\n ===== DELETE PLAYLIST =====\n\n'
    playlists=("$PLAYLIST_DIR"/*.txt)

    if [[ ! -e "${playlists[0]}" ]]; then
        printf ' No playlists found.\n'
        printf '\n Press any key to return...'
        IFS= read -rsn1
        return
    fi

    selection=$(
        for file in "${playlists[@]}"; do
            basename "$file" .txt
        done | fzf --layout=reverse --header="ENTER = select playlist | ESC = back"
    )
    [[ -z "$selection" ]] && return
    file="$PLAYLIST_DIR/$selection.txt"

    clear
    printf '\n ===== DELETE PLAYLIST =====\n\n'
    printf ' Playlist: %s\n\n' "$selection"
    printf ' This will permanently delete this playlist.\n\n'
    printf ' Delete "%s"? [y/N]: ' "$selection"
    IFS= read -rsn1 confirm
    printf '\n'

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        rm -- "$file"
        printf '\n Playlist "%s" deleted successfully.\n' "$selection"
    else
        printf '\n Deletion cancelled.\n'
    fi
    printf '\n Press any key to return...'
    IFS= read -rsn1
}

download_current_song() {
    local title url download_dir

    title=$(get_property "media-title")
    url=$(get_property "path")

    if [[ -z "$url" || "$url" != http* ]]; then
        notify-send -u low "Music Player" "No downloadable song currently playing." 2>/dev/null
        return
    fi

    download_dir="$HOME/Music"
    mkdir -p "$download_dir"

    notify-send -u low "Music Player" "Downloading: ${title:-$url}" 2>/dev/null

    (
        "$YTDLP_BIN" -x --audio-format mp3 --audio-quality 0 \
            -o "$download_dir/%(title)s.%(ext)s" \
            "$url" >/dev/null 2>&1
        if (( $? == 0 )); then
            notify-send -u normal "Music Player" "Downloaded to ~/Music:\n${title:-$url}" 2>/dev/null
        else
            notify-send -u critical "Music Player" "Failed to download:\n${title:-$url}" 2>/dev/null
        fi
    ) &
}

playlist_menu() {
    while true; do
        clear
        printf ' ===== PLAYLISTS =====\n'
        printf ' 1) Play playlist       2) Add current song\n'
        printf ' 3) Create playlist     4) View / manage\n'
        printf ' 5) Delete playlist     6) Add entire queue\n'
        printf '\n B) Back\n'
        printf ' Select: '
        IFS= read -rsn1 choice

        case "$choice" in
            1) play_playlist ;;
            2) add_current_to_playlist ;;
            3) create_playlist ;;
            4) view_playlist ;;
            5) delete_playlist ;;
            6) add_queue_to_playlist ;;
            b|B) return ;;
        esac
    done
}

cleanup() {
    command '{"command":["quit"]}'
    rm -f "$SOCK"
    tmux kill-session 2>/dev/null
    exit
}

draw() {
    local title pos duration volume paused idle percent width filled empty bar
    title=$(get_property "media-title")
    pos=$(get_property "time-pos")
    duration=$(get_property "duration")
    volume=$(get_property "volume")
    paused=$(get_property "pause")
    idle=$(get_property "idle-active")

    if [[ -z "$title" ]]; then
        clear
        if [[ "$idle" == "true" ]]; then
            printf " ♪ Terminal Music Player\n\n"
            printf "        NO SONG PLAYING\n\n"
            printf " S Search    M Playlists    Q Quit\n"
        else
            printf " ♪ Loading...\n\n"
            printf "        LOADING SONG...\n\n"
            printf " M Playlists    Q Quit\n"
        fi
        return
    fi

    [[ -z "$pos" ]] && pos=0
    [[ -z "$duration" ]] && duration=0
    [[ -z "$volume" ]] && volume=0

    pos=${pos%.*}
    duration=${duration%.*}
    volume=${volume%.*}

    if [[ "$paused" == "true" ]]; then
        status="⏸ PAUSED"
        status_color="$PAUSE_COLOR"
    else
        status="▶ PLAYING"
        status_color="$PLAY_COLOR"
    fi

    width=30
    if (( duration > 0 )); then
        percent=$(( pos * 100 / duration ))
        filled=$(( percent * width / 100 ))
    else
        filled=0
    fi

    (( filled > width )) && filled=$width
    empty=$((width - filled))

    bar="${PROGRESS_COLOR}$(printf '%*s' "$filled" '' | tr ' ' '=')"
    bar+="${EMPTY_COLOR}$(printf '%*s' "$empty" '' | tr ' ' '-')"
    bar+="${RESET}" 

    clear
    printf " %s♪ %s%s\n\n" "$TITLE_COLOR" "$title" "$RESET"
    printf " %s%s%s    %s / %s    Volume: %s%%\n" \
        "$status_color" "$status" "$RESET" \
        "$(format_time "$pos")" "$(format_time "$duration")" "$volume"
    printf " %s\n\n" "$bar"

    printf " ${KEY_STYLE} SPACE ${RESET}${MUTED_COLOR} Pause  "
    printf "${KEY_STYLE} ←/→ ${RESET}${MUTED_COLOR} Seek  "
    printf "${KEY_STYLE} ↑/↓ ${RESET}${MUTED_COLOR} Volume  "
    printf "${KEY_STYLE} D ${RESET}${MUTED_COLOR} Download  "
    printf "${KEY_STYLE} N/P ${RESET}${MUTED_COLOR} Track${RESET}\n\n"

    printf " ${KEY_STYLE} S ${RESET}${MUTED_COLOR} Search  "
    printf "${KEY_STYLE} R ${RESET}${MUTED_COLOR} Radio  "
    printf "${KEY_STYLE} A ${RESET}${MUTED_COLOR} Add  "
    printf "${KEY_STYLE} L ${RESET}${MUTED_COLOR} Queue  "
    printf "${KEY_STYLE} M ${RESET}${MUTED_COLOR} Playlists  "
    printf "${KEY_STYLE} Q ${RESET}${MUTED_COLOR} Quit${RESET}\n"
}

while true; do
    draw
    if IFS= read -rsn1 -t 0.5 key; then
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 rest
            key+="$rest"
        fi
        case "$key" in
            " ") command '{"command":["cycle","pause"]}' ;;
            $'\x1b[D') command '{"command":["seek",-5,"relative"]}' ;;
            $'\x1b[C') command '{"command":["seek",5,"relative"]}' ;;
            $'\x1b[A') command '{"command":["add","volume",5]}' ;;
            $'\x1b[B') command '{"command":["add","volume",-5]}' ;;
            r|R)
                radio_result=$(
                    "$HOME/.local/share/music-player/radio-venv/bin/python" \
                        "$HOME/.local/bin/music-radio"
                )
                if [[ "$radio_result" == *$'\t'* ]]; then
                    radio_url="${radio_result%%$'\t'*}"
                    radio_title="${radio_result#*$'\t'}"
                    QUEUE_TITLES["$radio_url"]="$radio_title"
                fi
                ;;
            s|S) search_song ;;
            a|A) add_to_queue ;;
            n|N) command '{"command":["playlist-next","force"]}' ;;
            p|P) command '{"command":["playlist-prev","force"]}' ;;
            l|L) show_queue ;;
            m|M) playlist_menu ;;
            d|D) download_current_song ;;
            q|Q) cleanup ;;
        esac
    fi
done
EOF

# 5.4 music-radio
cat << 'EOF' > "$HOME/.local/bin/music-radio"
#!/usr/bin/env python3
"""Pick a YouTube Music radio suggestion for the current mpv song."""

import json
import re
import socket
import subprocess
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

SOCKET = Path("/tmp/abhi-music.sock")
VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")


def mpv(*command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(SOCKET))
        connection.sendall((json.dumps({"command": list(command)}) + "\n").encode())
        with connection.makefile("r", encoding="utf-8") as stream:
            response = json.loads(stream.readline())
    if response.get("error") != "success":
        raise RuntimeError(f"mpv: {response.get('error', 'no response')}")
    return response.get("data")


def video_id_from_url(url):
    parts = urlsplit(url)
    host = (parts.hostname or "").lower()
    if host == "youtu.be":
        candidate = parts.path.lstrip("/").split("/")[0]
    elif host in ("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"):
        if parts.path in ("/watch", "/live"):
            candidate = parse_qs(parts.query).get("v", [""])[0]
        elif parts.path.startswith("/shorts/") or parts.path.startswith("/live/"):
            candidate = parts.path.split("/")[2]
        else:
            candidate = ""
    else:
        candidate = ""
    return candidate if VIDEO_ID.fullmatch(candidate) else None


def clean(value):
    return " ".join(str(value or "").split())


def suggestions(seed):
    from ytmusicapi import YTMusic

    response = YTMusic().get_watch_playlist(videoId=seed, limit=25, radio=True)
    found = []
    seen = {seed}
    for track in response.get("tracks", []):
        vid = track.get("videoId")
        if not isinstance(vid, str) or not VIDEO_ID.fullmatch(vid) or vid in seen:
            continue
        seen.add(vid)
        artist = ", ".join(clean(a.get("name")) for a in track.get("artists") or [] if isinstance(a, dict))
        title = clean(track.get("title")) or "Untitled"
        label = f"{title} — {artist}" if artist else title
        found.append((label, f"https://www.youtube.com/watch?v={vid}"))
    return found


def choose_song(items):
    rows = "\n".join(f"{label}\t{url}" for label, url in items) + "\n"
    result = subprocess.run(
        ["fzf", "--layout=reverse", "--prompt=Song Radio > ", "--delimiter=\t", "--with-nth=1"],
        input=rows,
        text=True,
        stdout=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0 or "\t" not in result.stdout:
        return None
    return tuple(result.stdout.rstrip("\n").rsplit("\t", 1))


def main():
    current = mpv("get_property", "path")
    seed = video_id_from_url(current if isinstance(current, str) else "")
    if seed is None:
        raise RuntimeError("Play a YouTube song first, then press R.")

    print("\n Finding songs like the one playing...\n", file=sys.stderr, flush=True)
    items = suggestions(seed)
    if not items:
        raise RuntimeError("YouTube Music returned no playable suggestions for this song.")

    chosen = choose_song(items)
    if chosen is None:
        return
    label, selected = chosen

    print("\n P) Play now (keep queue)   A) Add to queue   B) Back: ",
          end="", file=sys.stderr, flush=True)
    answer = input().strip().lower()
    if answer == "p":
        mpv("loadfile", selected, "insert-next")
        mpv("playlist-next", "weak")
        print(" Playing selected song.", file=sys.stderr)
    elif answer == "a":
        mpv("loadfile", selected, "append-play")
        print(" Added to queue.", file=sys.stderr)
    else:
        return
    print(f"{selected}\t{label}", flush=True)
    print(" Press Enter to return to the player...", end="", file=sys.stderr, flush=True)
    input()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except (OSError, RuntimeError, ValueError, ImportError, subprocess.SubprocessError) as exc:
        print(f"\n Song Radio: {exc}", file=sys.stderr)
        try:
            print(" Press Enter to return...", end="", file=sys.stderr, flush=True)
            input()
        except (EOFError, KeyboardInterrupt):
            pass
        sys.exit(1)
EOF

# 5.5 music-youtube-export.py
cat << 'EOF' > "$HOME/.local/bin/music-youtube-export.py"
#!/usr/bin/env python3
"""Export title | YouTube URL playlists. Never modifies local playlist files."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import urlparse, parse_qs

HOME = Path.home()
CONFIG = HOME / '.config/music-player'
DATA = HOME / '.local/share/music-player'
SCOPES = ['https://www.googleapis.com/auth/youtube.force-ssl']


def save_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.export-')
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def video_id(raw):
    try:
        u = urlparse(raw.strip())
        if u.scheme not in ('http', 'https') or u.username or u.password:
            return None
        host = (u.hostname or '').lower()
        parts = u.path.strip('/').split('/')
        candidate = ''
        if host in ('youtu.be', 'www.youtu.be') and len(parts) == 1:
            candidate = parts[0]
        elif host in ('youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com'):
            if u.path == '/watch':
                candidate = parse_qs(u.query).get('v', [''])[0]
            elif len(parts) == 2 and parts[0] in ('shorts', 'embed', 'live'):
                candidate = parts[1]
        return candidate if re.fullmatch(r'[A-Za-z0-9_-]{11}', candidate) else None
    except ValueError:
        return None


def read_tracks(path):
    tracks, seen, invalid, duplicates = [], set(), [], 0
    for number, line in enumerate(path.read_text(encoding='utf-8-sig').splitlines(), 1):
        if not line.strip():
            continue
        title, sep, url = line.rpartition('|')
        vid = video_id(url.strip() if sep else line.strip())
        if not vid:
            invalid.append(number)
        elif vid in seen:
            duplicates += 1
        else:
            seen.add(vid)
            tracks.append((vid, title.strip() if sep else vid))
    return tracks, invalid, duplicates


def authorize():
    from google.auth.transport.requests import Request
    from google.auth.exceptions import RefreshError
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    secret = CONFIG / 'client_secret.json'
    token = CONFIG / 'youtube-token.json'
    if not secret.is_file():
        raise RuntimeError(f'Missing credentials: {secret}\nDownload your Desktop app OAuth JSON from Google Cloud and save it at {secret}')
    if 'installed' not in json.loads(secret.read_text()):
        raise RuntimeError('Download credentials for a Desktop app, not a Web app.')
    creds = None
    if token.exists():
        creds = Credentials.from_authorized_user_file(str(token), SCOPES)
    if creds and creds.expired and creds.refresh_token:
        try:
            creds.refresh(Request())
        except RefreshError:
            creds = None
    if not creds or not creds.valid:
        print('Sign in in your browser using your intended Google account and YouTube channel.')
        flow = InstalledAppFlow.from_client_secrets_file(str(secret), SCOPES)
        creds = flow.run_local_server(port=0, timeout_seconds=300, access_type='offline', prompt='consent')
    save_json(token, json.loads(creds.to_json()))
    return creds


def reason(error):
    try:
        data = json.loads(error.content)['error']
        return ', '.join(x.get('reason', 'unknown') for x in data.get('errors', [])) or data.get('message', 'API error')
    except (ValueError, KeyError, TypeError):
        return 'API request failed'


def select_existing(youtube, channel_id):
    playlists = []
    page = None
    while True:
        response = youtube.playlists().list(
            part='snippet,status,contentDetails', mine=True,
            maxResults=50, pageToken=page).execute()
        playlists.extend(item for item in response.get('items', [])
                         if item['snippet']['channelId'] == channel_id)
        page = response.get('nextPageToken')
        if not page:
            break
    playlists.sort(key=lambda item: (item['snippet']['title'].casefold(), item['id']))
    if not playlists:
        print('No owned YouTube playlists found. Choose option 3 to create one.')
        return None
    print('\nYour YouTube playlists:')
    for i, item in enumerate(playlists, 1):
        visibility = item.get('status', {}).get('privacyStatus', 'unknown')
        count = item.get('contentDetails', {}).get('itemCount', '?')
        print(f"{i:2}. {item['snippet']['title']} [{visibility}; {count} videos] ({item['id']})")
    while True:
        answer = input('Destination number (Enter returns): ').strip()
        if not answer:
            return None
        if answer.isdecimal() and 1 <= int(answer) <= len(playlists):
            return playlists[int(answer) - 1]['id']
        print('Enter a number from the list.')


def choose_destination(youtube, channel_id, state):
    while True:
        print('\nYouTube destination:')
        print('1. Update the previously linked playlist')
        print('2. Choose another existing YouTube playlist')
        print('3. Create a new PRIVATE YouTube playlist')
        print('B. Cancel')
        answer = input('Choose [1/2/3/B]: ').strip().lower()
        if answer in ('', 'b'):
            return None
        if answer == '1':
            if state.get('playlist_id') or state.get('creation_pending'):
                return dict(state)
            print('No previous destination. Choose 2 or 3.')
        elif answer in ('2', '3'):
            if state.get('creation_pending'):
                print('A previous creation was interrupted. Check YouTube for that playlist first.')
            if answer == '2':
                selected = select_existing(youtube, channel_id)
                if selected:
                    return {'playlist_id': selected}
            else:
                return {}
        else:
            print('Choose 1, 2, 3, or B.')


def main():
    from googleapiclient.discovery import build
    from googleapiclient.errors import HttpError
    files = sorted((DATA / 'playlists').glob('*.txt'))
    if not files:
        print('No saved playlists found in', DATA / 'playlists')
        return
    for i, path in enumerate(files, 1):
        print(f'{i:2}. {path.stem}')
    choice = input('\nPlaylist number (Enter cancels): ').strip()
    if not choice:
        return
    if not choice.isdecimal() or not 1 <= int(choice) <= len(files):
        print('Invalid playlist number. Run again to choose.')
        return
    path = files[int(choice) - 1]
    tracks, invalid, duplicates = read_tracks(path)
    print(f'\n{path.stem}: {len(tracks)} unique video links; {duplicates} duplicates skipped.')
    if invalid:
        print('Malformed/non-YouTube entries skipped at lines:', ', '.join(map(str, invalid)))
    if not tracks:
        print('Nothing to export. No YouTube playlist will be created.')
        return
    youtube = build('youtube', 'v3', credentials=authorize(), cache_discovery=False)
    channels = youtube.channels().list(part='snippet', mine=True).execute().get('items', [])
    if not channels:
        raise RuntimeError('This account needs a YouTube channel. Create one on YouTube, then try again.')
    channel = channels[0]
    print('YouTube channel:', channel['snippet']['title'])
    key = hashlib.sha256((str(path.resolve()) + '\n' + channel['id']).encode()).hexdigest()
    statefile = DATA / 'youtube-exports' / (key + '.json')
    state = json.loads(statefile.read_text()) if statefile.exists() else {}
    state = choose_destination(youtube, channel['id'], state)
    if state is None:
        print('Cancelled.')
        return
    playlist_id = state.get('playlist_id')
    if state.get('creation_pending') and not playlist_id:
        print('A previous playlist creation was interrupted. Check YouTube before creating another.')
        print('If you find it, paste its playlist URL to resume; otherwise type NEW.')
        answer = input('URL or NEW (Enter cancels): ').strip()
        if not answer:
            return
        if answer != 'NEW':
            u = urlparse(answer)
            playlist_id = parse_qs(u.query).get('list', [''])[0]
            if u.hostname not in ('youtube.com', 'www.youtube.com') or not re.fullmatch(r'[A-Za-z0-9_-]+', playlist_id):
                raise RuntimeError('Not a valid YouTube playlist URL.')
    if playlist_id:
        info = youtube.playlists().list(part='snippet,status', id=playlist_id).execute().get('items', [])
        if not info:
            raise RuntimeError(f'Previous playlist is missing or inaccessible. Saved record: {statefile}')
        if info[0]['snippet']['channelId'] != channel['id']:
            raise RuntimeError('Saved playlist belongs to another channel.')
        print('Add missing songs to:', info[0]['snippet']['title'])
        print('Visibility:', info[0].get('status', {}).get('privacyStatus', 'unknown'))
        print('https://www.youtube.com/playlist?list=' + playlist_id)
    else:
        title = input(f'YouTube playlist title [{path.stem}]: ').strip() or path.stem
        if len(title) > 150:
            raise RuntimeError('Choose a title of at most 150 characters.')
        print('Create a PRIVATE playlist:', title)
    print('After confirmation, this destination becomes the saved link for this local playlist.')
    if input('Export now? [y/N]: ').strip().lower() != 'y':
        print('Cancelled.')
        return
    if not playlist_id:
        save_json(statefile, {'creation_pending': True, 'source': str(path)})
        response = youtube.playlists().insert(part='snippet,status', body={
            'snippet': {'title': title, 'description': 'Exported from my terminal music player.'},
            'status': {'privacyStatus': 'private'}}).execute(num_retries=0)
        playlist_id = response['id']
    save_json(statefile, {'playlist_id': playlist_id, 'source': str(path)})
    print('\nPlaylist: https://www.youtube.com/playlist?list=' + playlist_id, flush=True)
    existing = set()
    page = None
    while True:
        response = youtube.playlistItems().list(part='contentDetails', playlistId=playlist_id,
                                               maxResults=50, pageToken=page).execute()
        existing.update(item['contentDetails']['videoId'] for item in response.get('items', []))
        page = response.get('nextPageToken')
        if not page:
            break
    added, skipped, failed = 0, 0, []
    for index, (vid, title) in enumerate(tracks, 1):
        if vid in existing:
            skipped += 1
            continue
        try:
            youtube.playlistItems().insert(part='snippet', body={'snippet': {
                'playlistId': playlist_id, 'resourceId': {'kind': 'youtube#video', 'videoId': vid}
            }}).execute(num_retries=0)
            existing.add(vid)
            added += 1
            print(f'[{index}/{len(tracks)}] Added: {title}', flush=True)
        except HttpError as error:
            why = reason(error)
            if 'videoNotFound' in why:
                failed.append(vid)
                print(f'Skipped unavailable video: {title} ({vid})')
                continue
            print(f'Export stopped: HTTP {error.resp.status}: {why}')
            print('Fix the error, then run again and choose the same local playlist to resume.')
            break
    print(f'\nAdded this run: {added}; already present: {skipped}; unavailable: {len(failed)}.')
    print(f'Local tracks still absent: {sum(vid not in existing for vid, _ in tracks)}')
    print('https://www.youtube.com/playlist?list=' + playlist_id)


if __name__ == '__main__':
    os.umask(0o077)
    DATA.mkdir(parents=True, exist_ok=True)
    with (DATA / 'youtube-export.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit('Another export is already running.')
        try:
            main()
        except (KeyboardInterrupt, EOFError):
            print('\nStopped. Run again to resume any saved export.')
        except Exception as error:
            if type(error).__name__ == 'HttpError':
                print('YouTube error:', reason(error))
            elif isinstance(error, (RuntimeError, OSError)):
                print('Error:', error)
            else:
                print(f'Export stopped ({type(error).__name__}). Check your connection and setup, then retry.')
            sys.exit(1)
EOF

# 5.6 Standalone launchers in ~/.local/bin AND /usr/local/bin so it works immediately without restarting terminal
cat << 'EOF' > "$HOME/.local/bin/music"
#!/bin/bash
export PATH="$HOME/.local/bin:$HOME/.deno/bin:$PATH"
YTDLP_BIN="$HOME/.local/share/music-player/yt-dlp-venv/bin/yt-dlp"
[[ ! -x "$YTDLP_BIN" ]] && YTDLP_BIN="yt-dlp"

rm -f /tmp/abhi-music.sock

if [[ -n "$*" ]]; then
    selection=$("$YTDLP_BIN" "ytsearch20:$*" \
        --flat-playlist \
        --print "%(title)s | https://youtube.com/watch?v=%(id)s" \
        2>/dev/null | fzf --layout=reverse) || exit 0

    url="${selection##* | }"
    [[ -z "$url" ]] && exit 0

    mpv --no-video --idle=yes \
        --script="$HOME/.local/share/music-player/stop-on-error.lua" \
        --script-opts=ytdl_hook-ytdl_path="$YTDLP_BIN" \
        --log-file=/tmp/abhi-mpv-debug.log \
        --ytdl-raw-options-append=verbose= \
        --input-ipc-server=/tmp/abhi-music.sock \
        "$url" > /tmp/abhi-mpv.log 2>&1 &
else
    mpv --no-video --idle=yes \
        --script="$HOME/.local/share/music-player/stop-on-error.lua" \
        --script-opts=ytdl_hook-ytdl_path="$YTDLP_BIN" \
        --log-file=/tmp/abhi-mpv-debug.log \
        --ytdl-raw-options-append=verbose= \
        --input-ipc-server=/tmp/abhi-music.sock \
        > /tmp/abhi-mpv.log 2>&1 &
fi

sleep 1

# Compatible with both tmux 3.2 (Linux Mint 21) and tmux 3.3+ (Fedora / Mint 22)
tmux new-session "$HOME/.local/bin/music-control" \; \
    set-option -g destroy-unattached on \; \
    split-window -v 'cava' \; \
    set-option -w main-pane-height 10 \; \
    select-layout main-horizontal \; \
    set-hook -w window-resized 'select-layout main-horizontal' \; \
    select-pane -t 0
EOF

cat << 'EOF' > "$HOME/.local/bin/music-export"
#!/bin/bash
exec "$HOME/.local/share/music-player/youtube-venv/bin/python" "$HOME/.local/bin/music-youtube-export.py" "$@"
EOF

cat << 'EOF' > "$HOME/.local/bin/ytv"
#!/bin/bash
export PATH="$HOME/.local/bin:$HOME/.deno/bin:$PATH"
YTDLP_BIN="$HOME/.local/share/music-player/yt-dlp-venv/bin/yt-dlp"
[[ ! -x "$YTDLP_BIN" ]] && YTDLP_BIN="yt-dlp"

mkdir -p "$HOME/Videos"
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    "$YTDLP_BIN" -P "$HOME/Videos" -f "bv*[height<=$1]+ba/b[height<=$1]" --merge-output-format mp4 "$2"
else
    "$YTDLP_BIN" -P "$HOME/Videos" -f "bv*+ba/b" --merge-output-format mp4 "$1"
fi
EOF

chmod 755 "$HOME/.local/bin/music-control" \
          "$HOME/.local/bin/music-radio" \
          "$HOME/.local/bin/music-youtube-export.py" \
          "$HOME/.local/bin/music" \
          "$HOME/.local/bin/music-export" \
          "$HOME/.local/bin/ytv"

# Remove any broken old /usr/bin copies from previous .deb if present and link into /usr/local/bin
sudo rm -f /usr/bin/music /usr/bin/music-control /usr/bin/music-radio /usr/bin/music-youtube-export /usr/bin/music-export /usr/bin/ytv 2>/dev/null || true
sudo ln -sfn "$HOME/.local/bin/music" /usr/local/bin/music
sudo ln -sfn "$HOME/.local/bin/music-control" /usr/local/bin/music-control
sudo ln -sfn "$HOME/.local/bin/music-radio" /usr/local/bin/music-radio
sudo ln -sfn "$HOME/.local/bin/music-export" /usr/local/bin/music-export
sudo ln -sfn "$HOME/.local/bin/ytv" /usr/local/bin/ytv

echo ""
echo "========================================================"
echo "  INSTALLATION COMPLETE!"
echo "  Run:  music"
echo "  Run:  ytv \"<youtube-url>\""
echo "  Run:  music-export (after placing client_secret.json"
echo "        in ~/.config/music-player/client_secret.json)"
echo "========================================================"
