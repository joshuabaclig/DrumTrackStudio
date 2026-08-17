# Drum Track Studio

A small Windows desktop app that takes a YouTube link and gives you back a WAV file:
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

## Where files go

| What | Where |
| --- | --- |
| Final tracks | `Documents\DrumTrackStudio\Downloads\` |
| Raw separation stems | `Documents\DrumTrackStudio\Stems\` |
| Logs (for troubleshooting) | `%LOCALAPPDATA%\DrumTrackStudio\logs\` (or the "Open logs" button in the app) |

## Building from source (developers)

Requirements: Windows 10/11, PowerShell 5.1+, [Python 3.10+](https://www.python.org/downloads/)
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
DrumTrackStudio.ps1     the whole app: GUI + in-process pipeline (source)
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
- [PS2EXE](https://github.com/MScholtes/PS2EXE) — used only at build time to compile the .exe
- [Inno Setup](https://jrsoftware.org/isinfo.php) — used only at build time to build the installer

## A note on use

This tool downloads audio from YouTube. Only use it on content you own or have
the right to use — respect copyright and each video's terms of use.

## License

MIT — see [LICENSE](LICENSE).
