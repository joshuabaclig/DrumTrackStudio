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

### Trim & lead-in editor

Some videos open with a sampled intro, others start the song instantly with no time
to sit down at the kit. After each download, the **trim editor** opens:

- **Scrub** the waveform: click to move the playhead, scroll to zoom, play and pause.
- **Cut** a sampled intro or ending by dragging the Start/End handles (or typing
  times like `0:12.5`), with ±10 ms / ±100 ms nudges and "Trim silence".
- **Add a lead-in gap** of up to 30 seconds of silence before the song, and
  **Preview** it with a countdown, exactly as the finished track will play.

Edits are applied before stem separation, so the karaoke/drumless mix, the
practice-speed copies and the click track all line up with the trimmed track.
"Keep original" skips editing for that song; the Settings tab turns the editor off.

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
./run.sh "https://www.youtube.com/watch?v=..." --mode drumless --trim-start 0:12.5 --lead-in 4
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

There's one app, `drumtrackstudio/` (Python + Qt), on every OS. Windows, macOS and
Linux run the same code with the same pinned packages on Python 3.12; only the way
it's set up and launched differs.

| | macOS / Linux | Windows |
| --- | --- | --- |
| Dev setup | `./setup.sh` | `./Setup.ps1` (needs [Python 3.12](https://www.python.org/downloads/)) |
| Run the app | `./run.sh` | `env\Scripts\python -m drumtrackstudio` |
| Run the tests | `env/bin/python -m pytest` | `env\Scripts\python -m pytest` |

Both setup scripts install `requirements-app.lock.txt` (the app);
`requirements-dev.lock.txt` adds pytest (`Setup.ps1` installs it, on macOS/Linux run
`env/bin/python -m pip install -r requirements-dev.lock.txt`). The tests run headless
(Qt's offscreen platform) and include real ffmpeg edits, the trim editor and the full
GUI round trip; `-m slow` also runs a real Demucs separation, and `-m audio` plays
(muted) through your sound device.

**Windows installer.** The installer bundles an embeddable Python 3.12 (`runtime\`)
with the pinned packages, the app, and ffmpeg/ffprobe/deno (`bin\`); its Start Menu
shortcut runs `runtime\pythonw.exe -m drumtrackstudio`. Building it needs Windows
10/11, Python 3.12 and [Inno Setup 6](https://jrsoftware.org/isinfo.php):

```powershell
./Setup.ps1 -BinOnly           # fetch the pinned ffmpeg/ffprobe/deno into bin\
./Build-Runtime.ps1 -RunTests  # verify bin\ hashes, build runtime\, test the app ON that runtime
./Build-Installer.ps1          # dist\DrumTrackStudio-Setup-<version>.exe + checksums.txt
```

Dependency pinning: Python packages are locked in `requirements*.lock.txt`; the
embeddable Python and the ffmpeg/ffprobe/deno builds are pinned by SHA256 in
`tools.lock.json` and verified before packaging. To upgrade one, change it, test
end-to-end, and update the pin in the same commit.

Optional code signing: set `DTS_CERT_THUMBPRINT` to a certificate's thumbprint
(CurrentUser\My store) and `Build-Installer.ps1` signs the installer via signtool;
with no cert configured, signing is skipped cleanly.

GitHub Actions runs the tests on Windows, macOS and Linux and builds the Windows
installer on every pull request (the installer is attached to the run for testing).
Version tags (`v*`) publish a release. Before tagging `vX.Y.Z`, set the version in
`drumtrackstudio/__init__.py` and `installer.iss` and add `release-notes/vX.Y.Z.md`;
it becomes the release description, and the build stops early if any is missing.

## Project layout

```
drumtrackstudio/           the app (every OS)
  pipeline.py              download -> edit -> analyze -> separate -> mix (no GUI dependency)
  edit.py                  trim/lead-in model, ffmpeg filter, worker<->editor hand-off
  editor.py                the trim & lead-in editor window
  gui.py                   main window
  cli.py                   terminal front end (./run.sh <url>)
  settings.py, paths.py    settings.json + per-OS folders
tools/detect_features.py   BPM/key detection + click track
tests/                     pytest suite (headless)
setup.sh, run.sh           macOS/Linux setup and launcher
Setup.ps1                  Windows dev setup / fetches bin\ tools
Build-Runtime.ps1          builds + tests the bundled Windows runtime
Build-Installer.ps1        builds the Inno Setup installer
installer.iss              installer definition
requirements*.lock.txt     pinned Python packages (engine, app, tests)
tools.lock.json            pinned SHA256 hashes: embeddable Python, ffmpeg, ffprobe, deno
app.ico                    app icon
.github/workflows/         tests on 3 OSes, Windows build, releases
```

## Credits / third-party tools

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — Unlicense
- [FFmpeg](https://ffmpeg.org/) — LGPL/GPL depending on build
- [Demucs](https://github.com/facebookresearch/demucs) — MIT
- [Qt for Python (PySide6)](https://doc.qt.io/qtforpython/) — LGPL
- [Deno](https://deno.com) — MIT
- [Python](https://www.python.org/) — PSF License (bundled in the Windows installer)
- [Inno Setup](https://jrsoftware.org/isinfo.php) — used only at build time to build the installer

## A note on use

This tool downloads audio from YouTube. Only use it on content you own or have
the right to use — respect copyright and each video's terms of use.

## License

MIT — see [LICENSE](LICENSE).
