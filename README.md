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
saved to `Downloads/` named `<Song Title> - Karaoke.wav` / `<Song Title> - Drumless.wav`
so they're easy to drag onto a USB stick without collisions.

Stem separation uses [Demucs](https://github.com/facebookresearch/demucs) (Meta's
open-source source-separation model), running locally on CPU — no cloud service,
no API key.

## Setup (one time)

Requirements: Windows 10/11, [Python 3.10+](https://www.python.org/downloads/)
installed and on PATH.

1. Clone or download this repo.
2. Run `Setup.ps1` (right-click → "Run with PowerShell"). This downloads yt-dlp,
   ffmpeg/ffprobe, and installs a local Python environment with Demucs
   (CPU-only PyTorch — a few GB, takes a few minutes).
3. Run `Build-Exe.ps1` to compile `DrumTrackStudio.exe`. This uses
   [PS2EXE](https://github.com/MScholtes/PS2EXE) to produce a real, console-free
   executable, using the included `app.ico` icon.
4. Double-click `DrumTrackStudio.exe` to launch. Pin it to your taskbar/Start menu
   like any other app.

## Usage

Paste a YouTube URL, choose a mode, click Download. A status label shows progress;
when it's done, the app opens the output file's location automatically. The first
Karaoke or Drumless run also downloads the Demucs model (~300MB), which is cached
for every run after that.

## Project layout

```
DrumTrackStudio.ps1   GUI (source)
run-pipeline.ps1       download + separation pipeline, runs hidden in the background
Build-Exe.ps1           compiles DrumTrackStudio.ps1 -> DrumTrackStudio.exe
Setup.ps1               one-time environment bootstrap (see above)
app.ico                 app icon
bin/                    yt-dlp.exe, ffmpeg.exe, ffprobe.exe (fetched by Setup.ps1, not committed)
env/                    Python virtual environment (built by Setup.ps1, not committed)
Downloads/              final output files land here
Stems/                  raw Demucs output (working files, per-song subfolders)
```

## Credits / third-party tools

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — Unlicense
- [FFmpeg](https://ffmpeg.org/) — LGPL/GPL depending on build
- [Demucs](https://github.com/facebookresearch/demucs) — MIT
- [PS2EXE](https://github.com/MScholtes/PS2EXE) — used only at build time to compile the .exe

## A note on use

This tool downloads audio from YouTube. Only use it on content you own or have
the right to use — respect copyright and each video's terms of use.

## License

MIT — see [LICENSE](LICENSE).
