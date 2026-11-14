"""Shared fixtures. Every test runs against a throwaway settings file, log folder
and output folders - never the real user's - and Qt runs offscreen (no display
needed, so the same suite runs headless in CI on Windows, macOS and Linux)."""
import os
import shutil
import sys
from pathlib import Path

import numpy as np
import pytest

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from drumtrackstudio import paths, settings  # noqa: E402

SR = 44100


@pytest.fixture(autouse=True)
def isolated_user_files(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, 'SETTINGS_FILE', tmp_path / 'config' / 'settings.json')
    monkeypatch.setattr(paths, 'log_dir', lambda: tmp_path / 'logs')
    monkeypatch.setattr(paths, 'output_base', lambda: tmp_path / 'out')
    yield


@pytest.fixture
def ffmpeg():
    exe = paths.find_tool('ffmpeg')
    if not exe or not paths.find_tool('ffprobe'):
        pytest.skip('ffmpeg/ffprobe not installed')
    return exe


def tone_burst(sr=SR, freq=1000.0, length=0.02, amp=0.8):
    t = np.arange(int(length * sr)) / sr
    return (np.sin(2 * np.pi * freq * t) * amp).astype(np.float32)


def make_wav(path, duration, bursts=(), sr=SR, channels=2, noise_floor=0.0, burst_len=0.02):
    """A WAV of `duration` seconds: silence (or a faint noise floor) with a short
    1 kHz burst starting at each time in `bursts`. Returns the path."""
    import soundfile as sf
    n = int(round(duration * sr))
    mono = np.zeros(n, dtype=np.float32)
    if noise_floor:
        mono += (np.random.default_rng(0).standard_normal(n) * noise_floor).astype(np.float32)
    b = tone_burst(sr, length=burst_len)
    for t in bursts:
        i = int(round(t * sr))
        j = min(n, i + len(b))
        mono[i:j] += b[:j - i]
    data = np.repeat(mono[:, None], channels, axis=1) if channels > 1 else mono
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(path), data, sr, subtype='PCM_16')
    return str(path)


def onsets(path, threshold=0.1, min_gap=0.1):
    """Start times (s) of each burst in a WAV: first sample above threshold after
    at least min_gap of quiet."""
    import soundfile as sf
    data, sr = sf.read(str(path), always_2d=True)
    loud = np.nonzero(np.abs(data).max(axis=1) > threshold)[0]
    out, last = [], -10**9
    for i in loud:
        if i - last > min_gap * sr:
            out.append(i / sr)
        last = i
    return out


def wav_info(path):
    import soundfile as sf
    i = sf.info(str(path))
    return i.frames, i.samplerate


@pytest.fixture
def qapp():
    pytest.importorskip('PySide6')
    from PySide6.QtWidgets import QApplication
    app = QApplication.instance() or QApplication([])
    yield app


@pytest.fixture
def fake_download(monkeypatch, ffmpeg):
    """Replace yt-dlp with a local file: Pipeline.download() 'downloads' the WAV
    given by fake_download.source (as 'Test Song') into dest_dir, converted to the
    requested format just like yt-dlp's --audio-format would. Records the calls."""
    from drumtrackstudio.pipeline import Pipeline

    class Fake:
        source = None
        calls = []

    def download(self, dest_dir, fmt):
        Fake.calls.append((dest_dir, fmt))
        ext = {'best': 'wav', 'aac': 'm4a', 'vorbis': 'ogg'}.get(fmt, fmt)
        dest = os.path.join(dest_dir, f"Test Song.{ext}")
        if ext == 'wav':
            shutil.copyfile(Fake.source, dest)
        else:
            code, _ = self.run_tool([self.ffmpeg, '-y', '-i', Fake.source, dest])
            assert code == 0
        return dest

    Fake.calls = []
    monkeypatch.setattr(Pipeline, 'download', download)
    return Fake
