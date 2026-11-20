#!/usr/bin/env bash
set -euo pipefail

echo "=== Abhi Terminal Music Player — Linux Mint / Ubuntu Installer ==="

# 1. Update apt (ignore Live USB cdrom:// repo errors) and install dependencies
sudo apt-get update || true
sudo apt-get install -y \
  nano tmux mpv socat jq fzf \
  python3 python3-pip python3-venv \
  curl unzip ffmpeg libnotify-bin

sudo apt-get install -y cava || echo "Note: 'cava' not found in default apt repos; skipping."

# 2. Install Deno non-interactively (required by yt-dlp for YouTube JS challenges)
if ! command -v deno >/dev/null 2>&1 && [[ ! -x "$HOME/.deno/bin/deno" ]]; then
  curl -fsSL https://deno.land/install.sh | sh -s -- -y
fi

# 3. Create directories and isolated Python virtual environments
mkdir -p \
  "$HOME/.local/bin" \
  "$HOME/.local/share/music-player/playlists" \
  "$HOME/.local/share/music-player/youtube-exports" \
  "$HOME/.config/music-player" \
  "$HOME/.config/cava" \
  "$HOME/Music" \
  "$HOME/Videos"

python3 -m venv "$HOME/.local/share/music-player/yt-dlp-venv"
"$HOME/.local/share/music-player/yt-dlp-venv/bin/pip" install -U pip "yt-dlp[default]"
ln -sfn "$HOME/.local/share/music-player/yt-dlp-venv/bin/yt-dlp" "$HOME/.local/bin/yt-dlp"

python3 -m venv "$HOME/.local/share/music-player/radio-venv"
"$HOME/.local/share/music-player/radio-venv/bin/pip" install -U pip ytmusicapi

python3 -m venv "$HOME/.local/share/music-player/youtube-venv"
"$HOME/.local/share/music-player/youtube-venv/bin/pip" install -U pip \
  google-api-python-client google-auth-oauthlib google-auth-httplib2

# 4. Copy base scripts from repo (keeps repo bin/ and share/ untouched)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -f "$SCRIPT_DIR"/bin/* "$HOME/.local/bin/"
cp -f "$SCRIPT_DIR"/share/stop-on-error.lua "$HOME/.local/share/music-player/"

# 5. Install ytdl-headers.lua (fixes HTTP 403 on Mint/Ubuntu mpv 0.37)
cat <<'LUA_EOF' > "$HOME/.local/share/music-player/ytdl-headers.lua"
local utils = require 'mp.utils'
local msg = require 'mp.msg'

local function is_youtube(url)
    return url and (url:match("^https?://[%w%.%-]*youtube%.com/") or url:match("^https?://youtu%.be/"))
end

mp.add_hook("on_load", 10, function()
    local url = mp.get_property("stream-open-filename", "")
    if not is_youtube(url) then return end

    local home = os.getenv("HOME") or ""
    local ytdlp = home .. "/.local/share/music-player/yt-dlp-venv/bin/yt-dlp"
    local f = io.open(ytdlp, "r")
    if f then f:close() else ytdlp = "yt-dlp" end

    local res = mp.command_native({
        name = "subprocess",
        args = { ytdlp, "-J", "--no-playlist", "-f", "bestaudio/best", "--force-ipv4", url },
        capture_stdout = true,
        capture_stderr = true,
    })

    if res.status ~= 0 or not res.stdout or res.stdout == "" then
        msg.error("ytdl-headers: yt-dlp failed for " .. url)
        return
    end

    local data = utils.parse_json(res.stdout)
    if not data then return end

    local stream_url = data.url
    local headers = data.http_headers
    if not stream_url and data.requested_formats and data.requested_formats[1] then
        stream_url = data.requested_formats[1].url
        headers = data.requested_formats[1].http_headers or headers
    end
    if not stream_url then return end

    if data.title then
        mp.set_property("file-local-options/force-media-title", data.title)
    end

    if type(headers) == "table" then
        local fields = {}
        for k, v in pairs(headers) do
            if k:lower() == "user-agent" then
                mp.set_property("file-local-options/user-agent", tostring(v))
            else
                table.insert(fields, k .. ": " .. tostring(v))
            end
        end
        if #fields > 0 then
            mp.set_property_native("file-local-options/http-header-fields", fields)
        end
    end

    mp.set_property("stream-open-filename", stream_url)
end)
LUA_EOF

# 6. Install Mint-optimized 'music' launcher (--ytdl=no, ytdl-headers.lua, tmux mouse on)
cat <<'MUSIC_EOF' > "$HOME/.local/bin/music"
#!/usr/bin/env bash

url=""
selection=""

rm -f /tmp/abhi-music.sock

if [[ -n "$*" ]]; then
    selection=$(yt-dlp "ytsearch20:$*" \
        --flat-playlist \
        --print "%(title)s | https://youtube.com/watch?v=%(id)s" \
        2>/dev/null | fzf --layout=reverse) || exit 0

    url="${selection##* | }"
    [[ -z "$url" ]] && exit 0

    mpv --no-video --idle=yes --ytdl=no \
        --script="$HOME/.local/share/music-player/stop-on-error.lua" \
        --script="$HOME/.local/share/music-player/ytdl-headers.lua" \
        --log-file=/tmp/abhi-mpv-debug.log \
        --input-ipc-server=/tmp/abhi-music.sock \
        "$url" > /tmp/abhi-mpv.log 2>&1 &
else
    mpv --no-video --idle=yes --ytdl=no \
        --script="$HOME/.local/share/music-player/stop-on-error.lua" \
        --script="$HOME/.local/share/music-player/ytdl-headers.lua" \
        --log-file=/tmp/abhi-mpv-debug.log \
        --input-ipc-server=/tmp/abhi-music.sock \
        > /tmp/abhi-mpv.log 2>&1 &
fi

sleep 1

tmux new-session "$HOME/.local/bin/music-control" \; \
    set-option -g destroy-unattached on \; \
    set-option -g mouse on \; \
    split-window -v 'cava' \; \
    set-option -w main-pane-height 23% \; \
    select-layout main-horizontal \; \
    set-hook -w window-resized 'select-layout main-horizontal' \; \
    select-pane -t 0
MUSIC_EOF

# 7. Patch installed music-control with anti-blink (LAST_FRAME + tput civis/cnorm)
python3 - <<'PY_EOF'
from pathlib import Path

p = Path.home() / ".local/bin/music-control"
text = p.read_text()

if "LAST_FRAME" not in text:
    # Restore cursor safely in cleanup()
    text = text.replace(
        "cleanup() {\n",
        "cleanup() {\n    trap - EXIT INT TERM\n    tput cnorm 2>/dev/null\n",
        1,
    )

    # Show cursor only while typing in search/add/create prompts
    text = text.replace(
        "    IFS= read -r query\n",
        "    tput cnorm 2>/dev/null\n    IFS= read -r query\n    tput civis 2>/dev/null\n",
    )
    text = text.replace(
        "    IFS= read -r name\n",
        "    tput cnorm 2>/dev/null\n    IFS= read -r name\n    tput civis 2>/dev/null\n",
    )

    # Buffer idle/loading frame
    old_idle = """    if [[ -z "$title" ]]; then
    clear

    if [[ "$idle" == "true" ]]; then
        printf " ♪ Terminal Music Player\\n\\n"
        printf "        NO SONG PLAYING\\n\\n"
        printf " S Search    M Playlists    Q Quit\\n"
      else
        printf " ♪ Loading...\\n\\n"
        printf "        LOADING SONG...\\n\\n"
        printf " M Playlists    Q Quit\\n"
      fi

     return
    fi"""

    new_idle = """    if [[ -z "$title" ]]; then
        local out
        if [[ "$idle" == "true" ]]; then
            out=$(
                printf " ♪ Terminal Music Player\\n\\n"
                printf "        NO SONG PLAYING\\n\\n"
                printf " S Search    M Playlists    Q Quit\\n"
            )
        else
            out=$(
                printf " ♪ Loading...\\n\\n"
                printf "        LOADING SONG...\\n\\n"
                printf " M Playlists    Q Quit\\n"
            )
        fi
        if [[ "$out" != "$LAST_FRAME" ]]; then
            LAST_FRAME="$out"
            clear
            printf '%s\\n' "$out"
        fi
        return
    fi"""
    text = text.replace(old_idle, new_idle, 1)

    # Buffer active playing/paused frame
    old_draw_tail = """    clear

    printf " %s♪ %s%s\\n\\n" \\
        "$TITLE_COLOR" \\
        "$title" \\
        "$RESET"

    printf " %s%s%s    %s / %s    Volume: %s%%\\n" \\
        "$status_color" \\
        "$status" \\
        "$RESET" \\
        "$(format_time "$pos")" \\
        "$(format_time "$duration")" \\
        "$volume"

    printf " %s\\n\\n" "$bar"

    printf " ${KEY_STYLE} SPACE ${RESET}${MUTED_COLOR} Pause  "
    printf "${KEY_STYLE} ←/→ ${RESET}${MUTED_COLOR} Seek  "
    printf "${KEY_STYLE} ↑/↓ ${RESET}${MUTED_COLOR} Volume  "
    printf "${KEY_STYLE} D ${RESET}${MUTED_COLOR} Download  "
    printf "${KEY_STYLE} N/P ${RESET}${MUTED_COLOR} Track${RESET}\\n\\n"

    printf " ${KEY_STYLE} S ${RESET}${MUTED_COLOR} Search  "
    printf "${KEY_STYLE} R ${RESET}${MUTED_COLOR} Radio  "
    printf "${KEY_STYLE} A ${RESET}${MUTED_COLOR} Add  "
    printf "${KEY_STYLE} L ${RESET}${MUTED_COLOR} Queue  "
    printf "${KEY_STYLE} M ${RESET}${MUTED_COLOR} Playlists  "
    printf "${KEY_STYLE} Q ${RESET}${MUTED_COLOR} Quit${RESET}\\n"
}"""

    new_draw_tail = """    local out
    out=$(
        printf " %s♪ %s%s\\n\\n" \\
            "$TITLE_COLOR" \\
            "$title" \\
            "$RESET"

        printf " %s%s%s    %s / %s    Volume: %s%%\\n" \\
            "$status_color" \\
            "$status" \\
            "$RESET" \\
            "$(format_time "$pos")" \\
            "$(format_time "$duration")" \\
            "$volume"

        printf " %s\\n\\n" "$bar"

        printf " ${KEY_STYLE} SPACE ${RESET}${MUTED_COLOR} Pause  "
        printf "${KEY_STYLE} ←/→ ${RESET}${MUTED_COLOR} Seek  "
        printf "${KEY_STYLE} ↑/↓ ${RESET}${MUTED_COLOR} Volume  "
        printf "${KEY_STYLE} D ${RESET}${MUTED_COLOR} Download  "
        printf "${KEY_STYLE} N/P ${RESET}${MUTED_COLOR} Track${RESET}\\n\\n"

        printf " ${KEY_STYLE} S ${RESET}${MUTED_COLOR} Search  "
        printf "${KEY_STYLE} R ${RESET}${MUTED_COLOR} Radio  "
        printf "${KEY_STYLE} A ${RESET}${MUTED_COLOR} Add  "
        printf "${KEY_STYLE} L ${RESET}${MUTED_COLOR} Queue  "
        printf "${KEY_STYLE} M ${RESET}${MUTED_COLOR} Playlists  "
        printf "${KEY_STYLE} Q ${RESET}${MUTED_COLOR} Quit${RESET}\\n"
    )

    if [[ "$out" != "$LAST_FRAME" ]]; then
        LAST_FRAME="$out"
        clear
        printf '%s\\n' "$out"
    fi
}"""
    text = text.replace(old_draw_tail, new_draw_tail, 1)

    # Initialize anti-blink state before main loop and reset after keypresses
    text = text.replace(
        "\nwhile true; do\n",
        '\nLAST_FRAME=""\ntrap cleanup EXIT INT TERM\ntput civis 2>/dev/null\n\nwhile true; do\n',
        1,
    )
    text = text.replace(
        "        esac\n    fi\n\ndone",
        '        esac\n        LAST_FRAME=""\n        tput civis 2>/dev/null\n    fi\n\ndone',
        1,
    )

    p.write_text(text)
PY_EOF

chmod 755 "$HOME/.local/bin/"*

# 8. Configure cava with noncurses + green-to-red gradient for Xfce/Ubuntu terminals
cat <<'CAVA_EOF' > "$HOME/.config/cava/config"
[general]
framerate = 60
autosens = 1
sensitivity = 70
bars = 0
bar_width = 2
bar_spacing = 1

[input]
method = pulse
source = auto

[output]
method = noncurses

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
CAVA_EOF

# 9. Create global symlinks so everything works immediately in the first terminal session
[[ -x "$HOME/.deno/bin/deno" ]] && sudo ln -sfn "$HOME/.deno/bin/deno" /usr/local/bin/deno
sudo ln -sfn "$HOME/.local/bin/yt-dlp" /usr/local/bin/yt-dlp
sudo ln -sfn "$HOME/.local/bin/music" /usr/local/bin/music
sudo ln -sfn "$HOME/.local/bin/music-control" /usr/local/bin/music-control
sudo ln -sfn "$HOME/.local/bin/music-radio" /usr/local/bin/music-radio
sudo ln -sfn "$HOME/.local/bin/music-youtube-export.py" /usr/local/bin/music-youtube-export.py

echo "=== MINT INSTALLATION COMPLETE! Run: music ==="
