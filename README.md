# Drum Track Studio

A small desktop app for **Windows, macOS and Linux** that takes a YouTube link and gives you back a WAV file:
the plain audio, a vocals-removed karaoke/instrumental track, or a drums-removed
track to play along with on your kit. No terminal windows, no manual ffmpeg commands.

## What it does

Paste a YouTube URL, pick one of three modes, click Download:

- **Audio Only** — just the WAV, no separation.
- **Vocal Karaoke** — vocals removed, instrumental backing track.
- **Drumless** — drums removed, so you can play the part yourself.

Everything is downloaded and processed at 44.1kHz. Karaoke/Drumless results are
saved to your `Documents\DrumTrackStudio\Downloads` folder named
`<Song Title> - Karaoke.wav` / `<Song Title> - Drumless.wav` so they're easy to
drag onto a USB stick without collisions.

Stem separation uses [Demucs](https://github.com/facebookresearch/demucs) (Meta's
open-source source-separation model), running locally on CPU — no cloud service,
no API key, and no Python installation needed (the installer bundles everything).

## Install

### Windows

Download the latest `DrumTrackStudio-Setup-<version>.exe` from the
[Releases](../../releases) page and run it. It installs like any normal Windows app
(Start Menu shortcut, entry in Add/Remove Programs, clean uninstall).

### Why does Windows show a warning?

When you run the installer, Windows SmartScreen will likely show
**"Windows protected your PC — Unknown Publisher"**. This is expected and is not a
sign of a virus. It appears because this is a small open-source tool and we don't
pay for a code-signing certificate; Windows shows this generic warning for *any*
unsigned program it hasn't seen many downloads of yet.

To proceed: click **More info**, then **Run anyway**.

If you want to verify your download wasn't tampered with, every release includes a
`checksums.txt` — compare it against your file with:

```powershell
Get-FileHash .\DrumTrackStudio-Setup-<version>.exe -Algorithm SHA256
```

The app is fully open source — you can read every line of what it does in this repo,
or build it yourself from source (below).

*Future option: as an MIT-licensed open-source project, this repo likely qualifies
for [SignPath Foundation](https://signpath.io)'s free code signing for OSS, which
would remove the warning properly.*

### macOS and Linux

On macOS and Linux the app runs from source: there's no installer, so there's no
"unidentified developer" / Gatekeeper prompt either. You need:

- **macOS:** an Apple Silicon Mac (M1 or newer; PyTorch no longer ships Intel-Mac
  builds) and [Homebrew](https://brew.sh). Install the prerequisites with
  `brew install git ffmpeg uv`.
- **Linux:** a 64-bit distro from roughly 2022 or later (glibc 2.34+, e.g. Ubuntu
  22.04+, Fedora 35+, Arch). Install `git`, `ffmpeg` and
  [uv](https://docs.astral.sh/uv/) with your package manager, e.g.
  `sudo pacman -S git ffmpeg uv` or `sudo apt install git ffmpeg` plus uv from its site.

uv is optional if you already have Python 3.10-3.12 (PyTorch doesn't support newer
Pythons yet); with uv, setup fetches Python 3.12 into the project folder for you and
leaves your system Python alone.

```bash
git clone https://github.com/joshuabaclig/DrumTrackStudio.git
cd DrumTrackStudio
./setup.sh     # one time: ~1-2 GB of packages (PyTorch), plus deno into bin/
./run.sh       # opens the app
```

Re-run `./setup.sh` after a `git pull` to pick up dependency changes.

On Linux, setup also adds **Drum Track Studio to your app menu** (just for your
user, no sudo). If you move the project folder, re-run `./setup.sh` so the menu
entry points at the new location. To remove the entry:

```bash
rm ~/.local/share/applications/drumtrackstudio.desktop ~/.local/share/icons/hicolor/*/apps/drumtrackstudio.png
```

**Terminal mode:** pass a URL to skip the window. Options you don't give come from
the app's saved settings:

```bash
./run.sh "https://www.youtube.com/watch?v=..." --mode drumless
./run.sh "https://www.youtube.com/watch?v=..." --mode custom --remove vocals bass
./run.sh --help
```

## Where files go

| What | Windows | macOS | Linux |
| --- | --- | --- | --- |
| Final tracks | `Documents\DrumTrackStudio\Downloads\` | `~/Documents/DrumTrackStudio/Downloads/` | `~/Documents/DrumTrackStudio/Downloads/` |
| Raw separation stems | `Documents\DrumTrackStudio\Stems\` | `~/Documents/DrumTrackStudio/Stems/` | `~/Documents/DrumTrackStudio/Stems/` |
| Settings | `%APPDATA%\DrumTrackStudio\` | `~/Library/Application Support/DrumTrackStudio/` | `~/.config/DrumTrackStudio/` |
| Logs | `%LOCALAPPDATA%\DrumTrackStudio\logs\` | `~/Library/Logs/DrumTrackStudio/` | `~/.local/state/DrumTrackStudio/logs/` |

Both output folders can be changed in the Settings tab, and the "Open logs" button
opens the logs folder on every OS. (On Linux, "Documents" follows your XDG user-dirs
setting.)

## Building from source (developers)

There are currently two front ends sharing the same audio engine (Demucs, librosa,
yt-dlp, ffmpeg):

- `drumtrackstudio/` - the cross-platform **Python + Qt** app. On macOS/Linux,
  `./setup.sh` is the whole dev setup. On Windows it also runs from source: create a
  Python 3.12 venv and `pip install` `requirements-app.lock.txt` with the same index
  flags `setup.sh` uses, put ffmpeg/ffprobe/deno in `bin\` (`Setup.ps1` fetches them),
  then `python -m drumtrackstudio`.
- `DrumTrackStudio.ps1` - the original **WinForms** app, which the Windows installer
  still ships. It stays the Windows release until the Python app has its own
  installer.

Windows installer build requirements: Windows 10/11, PowerShell 5.1+, [Python 3.10+](https://www.python.org/downloads/)
on PATH (dev only — end users never need it), and [Inno Setup 6](https://jrsoftware.org/isinfo.php)
to build the installer.

```powershell
./Setup.ps1            # dev environment: fetches bin/ tools, builds env/ venv (pinned versions)
./Build-Runtime.ps1    # verifies bin/ hashes, builds the self-contained runtime/ bundle
./Build-Exe.ps1        # compiles DrumTrackStudio.ps1 -> DrumTrackStudio.exe (PS2EXE)
./Build-Installer.ps1  # produces dist/DrumTrackStudio-Setup-<version>.exe + checksums.txt
```

Dependency pinning: Python packages are locked in `requirements.lock.txt`; the
vendored yt-dlp/ffmpeg builds are pinned by SHA256 in `tools.lock.json` and verified
before packaging. To upgrade a tool, swap the exe, test end-to-end, and update the
hash in the same commit.

Optional code signing: if you have a certificate (e.g. an internal company cert
pushed to managed machines via Intune/GPO), set `DTS_CERT_THUMBPRINT` to its
thumbprint (CurrentUser\My store) and the build scripts sign the exe and installer
via signtool; with no cert configured, signing is skipped cleanly.

Releases are built automatically by GitHub Actions on version tags (`v*`), including
lint (PSScriptAnalyzer), the full build chain, and checksum generation.

## Project layout

```
drumtrackstudio/        cross-platform Python + Qt app
  pipeline.py           download/separate/mix pipeline (no GUI dependency)
  gui.py                Qt window
  cli.py                terminal front end (./run.sh <url>)
  settings.py, paths.py settings.json + per-OS folders
setup.sh, run.sh        macOS/Linux setup and launcher
requirements-app.lock.txt  extra pins for the Python app (Qt, yt-dlp)
tools/detect_features.py   BPM/key detection + click track (both apps)
DrumTrackStudio.ps1     Windows WinForms app: GUI + in-process pipeline (source)
Build-Runtime.ps1       builds the bundled Python runtime; verifies vendored binaries
Build-Exe.ps1           compiles the exe (PS2EXE), optional signing, checksum
Build-Installer.ps1     builds the Inno Setup installer
installer.iss           installer definition
Setup.ps1               developer environment bootstrap
requirements.lock.txt   pinned Python dependencies
tools.lock.json         pinned SHA256 hashes for yt-dlp/ffmpeg/ffprobe
app.ico                 app icon
.github/workflows/      lint + release automation
```

## Credits / third-party tools

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — Unlicense
- [FFmpeg](https://ffmpeg.org/) — LGPL/GPL depending on build
- [Demucs](https://github.com/facebookresearch/demucs) — MIT
- [Qt for Python (PySide6)](https://doc.qt.io/qtforpython/) — LGPL
- [Deno](https://deno.com) — MIT
- [PS2EXE](https://github.com/MScholtes/PS2EXE) — used only at build time to compile the .exe
- [Inno Setup](https://jrsoftware.org/isinfo.php) — used only at build time to build the installer

## A note on use

This tool downloads audio from YouTube. Only use it on content you own or have
the right to use — respect copyright and each video's terms of use.

## License

MIT — see [LICENSE](LICENSE).
