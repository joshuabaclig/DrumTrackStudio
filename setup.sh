#!/usr/bin/env bash
# One-time setup for macOS and Linux: builds the env/ Python environment with the
# pinned packages and fetches deno into bin/. Re-run it any time; it skips what's
# already done. Afterwards start the app with ./run.sh
#
# Needs: Python 3.10-3.12 (or uv, which fetches one for you) and ffmpeg.
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

OS=$(uname -s); ARCH=$(uname -m)
case "$OS" in
    Darwin)
        # PyTorch stopped publishing Intel-Mac builds after 2.2; the pinned 2.5 is arm64-only
        [ "$ARCH" = arm64 ] || fail 'macOS support needs an Apple Silicon (M1 or newer) Mac.'
        hint_ffmpeg='brew install ffmpeg'; hint_python='brew install uv'
        deno_triple=aarch64-apple-darwin ;;
    Linux)
        hint_ffmpeg='your package manager, e.g.  sudo apt install ffmpeg  /  sudo dnf install ffmpeg  /  sudo pacman -S ffmpeg'
        hint_python='your package manager (e.g.  sudo pacman -S uv) or https://docs.astral.sh/uv/'
        case "$ARCH" in
            x86_64)        deno_triple=x86_64-unknown-linux-gnu ;;
            aarch64|arm64) deno_triple=aarch64-unknown-linux-gnu ;;
            *) fail "Unsupported CPU architecture: $ARCH" ;;
        esac ;;
    *) fail "This script is for macOS and Linux. On Windows use the installer from the Releases page." ;;
esac

# ---------- ffmpeg (system package) ----------
if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
    fail "ffmpeg is not installed. Install it with $hint_ffmpeg, then re-run ./setup.sh"
fi
say 'Found ffmpeg.'

# ---------- Python environment (torch 2.5 supports Python 3.10-3.12) ----------
if [ ! -x env/bin/python ]; then
    if command -v uv >/dev/null; then
        say 'Creating Python 3.12 environment with uv...'
        uv venv --seed --python 3.12 env
    else
        py=''
        for c in python3.12 python3.11 python3.10 python3; do
            if command -v "$c" >/dev/null && "$c" -c 'import sys; sys.exit(not (3, 10) <= sys.version_info[:2] <= (3, 12))'; then
                py=$c; break
            fi
        done
        [ -n "$py" ] || fail "Python 3.10-3.12 is required (PyTorch doesn't support newer versions yet).
       Easiest fix: install uv with $hint_python - it downloads the right Python automatically - then re-run ./setup.sh"
        say "Creating Python environment with $py..."
        "$py" -m venv env
    fi
fi

say 'Installing pinned packages (PyTorch is large; this takes a few minutes the first time)...'
env/bin/python -m pip install --quiet --upgrade pip
env/bin/python -m pip install --index-url https://download.pytorch.org/whl/cpu \
    --extra-index-url https://pypi.org/simple -r requirements-app.lock.txt

# ---------- deno: yt-dlp's JS runtime for YouTube's anti-bot challenge ----------
# REQUIRED - without it downloads fail with HTTP 403.
if command -v deno >/dev/null; then
    say 'Found deno.'
elif [ -x bin/deno ]; then
    say 'Already have bin/deno.'
else
    say 'Downloading deno (~40 MB, one time)...'
    mkdir -p bin
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/deno.zip" "https://github.com/denoland/deno/releases/download/v2.9.8/deno-$deno_triple.zip"
    env/bin/python -m zipfile -e "$tmp/deno.zip" bin/
    chmod +x bin/deno
    rm -rf "$tmp"
fi

# ---------- smoke test ----------
env/bin/python -c 'import demucs.separate, librosa, yt_dlp, PySide6' \
    || fail 'Smoke test failed - a package did not import. See the output above.'

# ---------- Linux: app-menu entry + icon (per user, no sudo) ----------
# The desktop file's name must match the ID gui.py registers with the desktop
# (drumtrackstudio), which is how Wayland desktops find the window's icon.
if [ "$OS" = Linux ]; then
    data_home=${XDG_DATA_HOME:-$HOME/.local/share}
    mkdir -p "$data_home/applications"
    env/bin/python - "$data_home/icons/hicolor" <<'EOF'
import sys
from pathlib import Path
from PySide6.QtGui import QImageReader
r = QImageReader('app.ico')
for i in range(r.imageCount()):
    r.jumpToImage(i)
    img = r.read()
    d = Path(sys.argv[1]) / f"{img.width()}x{img.height()}" / 'apps'
    d.mkdir(parents=True, exist_ok=True)
    img.save(str(d / 'drumtrackstudio.png'))
EOF
    cat > "$data_home/applications/drumtrackstudio.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Drum Track Studio
GenericName=Backing Track Maker
Comment=Make drumless, karaoke and practice tracks from YouTube links
Exec="$PWD/run.sh"
Icon=drumtrackstudio
Terminal=false
Categories=AudioVideo;Audio;Music;
Keywords=drums;karaoke;stems;demucs;youtube;practice;
StartupWMClass=drumtrackstudio
EOF
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$data_home/applications" || true
    say 'Added Drum Track Studio to your app menu.'
fi

say ''
say 'Setup complete. Start Drum Track Studio with:  ./run.sh'
[ "$OS" = Linux ] && say '(or from your app menu)'
true
