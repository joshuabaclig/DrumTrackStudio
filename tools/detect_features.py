"""Detect BPM and musical key of an audio file; optionally write a click track.

Usage:
    python detect_features.py <audio-file> [--click-track <out.wav>]

Prints exactly ONE line of JSON to stdout on success:
    {"bpm": 128.3, "key": "C major"}
All diagnostics go to stderr. Exit code 0 on success, 1 on any failure.

Called by DrumTrackStudio.ps1 (Get-AudioFeatures) via the bundled runtime\\python.exe.
Non-WAV inputs (m4a etc.) decode through audioread -> ffmpeg, which the caller puts on
PATH; wav/flac/mp3 decode natively through soundfile.
"""
import argparse
import json
import sys

import numpy as np

# Krumhansl-Kessler key profiles (major/minor pitch-class weightings).
KRUMHANSL_MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
KRUMHANSL_MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
PITCHES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']


def detect_key(y, sr):
    """Krumhansl-Schmuckler: correlate mean chroma against all 24 rotated profiles."""
    import librosa
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
    profile = chroma.mean(axis=1)
    best_r, best_key = -2.0, None
    for mode_name, template in (('major', KRUMHANSL_MAJOR), ('minor', KRUMHANSL_MINOR)):
        t = np.asarray(template, dtype=float)
        for shift in range(12):
            r = np.corrcoef(np.roll(t, shift), profile)[0, 1]
            if r > best_r:
                best_r, best_key = r, f"{PITCHES[shift]} {mode_name}"
    return best_key


def write_click(path, beat_times, duration_sec, sr):
    """Zero-filled buffer matching the source's length, with a short decaying sine
    burst at each ACTUAL detected beat time (from librosa.beat.beat_track's beat
    frames), not a fixed-interval grid starting at t=0. A synthetic grid assumes
    beat one lands exactly at sample 0, which is essentially never true (lead-in
    silence, intros, pickup notes) and also can't track a real recording's small
    tempo fluctuations the way the actual detected beats do.
    """
    import soundfile as sf
    n = int(round(duration_sec * sr))
    buf = np.zeros(n, dtype=np.float32)
    click_len = int(0.004 * sr)  # 4 ms
    t = np.arange(click_len) / sr
    click = (np.sin(2 * np.pi * 1000.0 * t) * np.exp(-t / 0.001) * 0.8).astype(np.float32)
    for bt in beat_times:
        i = int(round(bt * sr))
        if i >= n:
            break
        end = min(i + click_len, n)
        buf[i:end] += click[:end - i]
    sf.write(path, buf, sr)


def main():
    ap = argparse.ArgumentParser(description='Detect BPM/key; optionally write a click track.')
    ap.add_argument('audio', help='path to the audio file to analyze')
    ap.add_argument('--click-track', help='write a click-track WAV to this path')
    args = ap.parse_args()
    try:
        import librosa
        y, sr = librosa.load(args.audio, sr=None, mono=True)
        tempo, beat_frames = librosa.beat.beat_track(y=y, sr=sr)
        bpm = float(np.atleast_1d(tempo)[0])
        key = detect_key(y, sr)
        if args.click_track and bpm > 0:
            beat_times = librosa.frames_to_time(beat_frames, sr=sr)
            write_click(args.click_track, beat_times, len(y) / sr, sr)
        print(json.dumps({"bpm": round(bpm, 1), "key": key}))
        return 0
    except Exception as e:  # noqa: BLE001 - caller treats any failure as non-fatal
        print(f"detect_features failed: {e}", file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
