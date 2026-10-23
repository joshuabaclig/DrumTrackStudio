"""Download -> analyze -> separate -> mix -> deliver. A port of the PowerShell
app's $PipelineScript with no Qt dependency; progress is reported through the
on_status / on_progress callbacks, which may be called from a worker thread.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

from . import __version__, paths
from .settings import MODEL_STEMS

DOWNLOAD_PROGRESS = r'\[download\]\s+(\d+(?:\.\d+)?)%'
DEMUCS_PROGRESS = r'^\s*(\d+(?:\.\d+)?)%\|'   # tqdm bar on demucs' stderr


class PipelineError(Exception):
    pass


class Cancelled(Exception):
    pass


@dataclass
class Job:
    url: str
    mode: str                  # 'audio' | 'mix'
    remove: list               # stems to remove (mix mode)
    suffix: str                # e.g. 'Karaoke', 'Drumless', 'No Vocals, No Bass'
    downloads_dir: str
    stems_dir: str
    format: str = 'wav'
    sample_rate: str = '44100'
    model: str = 'htdemucs'
    practice_speeds: list = field(default_factory=list)
    click_track: bool = False


@dataclass
class Result:
    out_file: str
    bpm: float = 0.0
    key: str = ''


def open_log():
    """Today's log file; also prunes logs older than 14 days."""
    d = paths.log_dir()
    d.mkdir(parents=True, exist_ok=True)
    cutoff = time.time() - timedelta(days=14).total_seconds()
    for f in d.glob('*.log'):
        try:
            if f.stat().st_mtime < cutoff:
                f.unlink()
        except OSError:
            pass
    return d / f"DrumTrackStudio_{datetime.now():%Y%m%d}.log"


def write_log(log_file, text: str) -> None:
    with open(log_file, 'a', encoding='utf-8') as f:
        f.write(f"[{datetime.now():%H:%M:%S}] {text}\n")


def missing_tools(mode: str) -> list:
    """Human-readable names of required tools that aren't installed."""
    missing = []
    if not paths.find_tool('ffmpeg') or not paths.find_tool('ffprobe'):
        missing.append('ffmpeg/ffprobe')
    try:
        import yt_dlp  # noqa: F401
    except ImportError:
        missing.append('yt-dlp (Python package)')
    if not paths.find_tool('deno'):
        missing.append('deno')
    if mode != 'audio':
        try:
            import demucs  # noqa: F401
        except ImportError:
            missing.append('demucs (Python package)')
    return missing


class Pipeline:
    def __init__(self, job: Job, log_file, on_status=None, on_progress=None):
        self.job = job
        self.log_file = log_file
        self._on_status = on_status or (lambda text: None)
        self._on_progress = on_progress or (lambda mode, value: None)   # mode: 'none'|'percent'|'marquee'
        self._proc = None
        self._cancelled = threading.Event()
        self.ffmpeg = paths.find_tool('ffmpeg')
        self.ffprobe = paths.find_tool('ffprobe')

    # ------------------------------------------------------------ helpers -----
    def log(self, text: str) -> None:
        write_log(self.log_file, text)

    def status(self, text: str) -> None:
        self._on_status(text)
        self.log(f"STATUS: {text}")

    def cancel(self) -> None:
        self._cancelled.set()
        p = self._proc
        if p and p.poll() is None:
            p.kill()

    def run_tool(self, args, progress_pattern=None):
        """Run a console tool with no window, streaming stdout/stderr line by line
        to the log and parsing a progress percentage from either stream.
        Returns (exit_code, stdout_text)."""
        if self._cancelled.is_set():
            raise Cancelled()
        env = os.environ.copy()
        env['PATH'] = str(paths.BIN_DIR) + os.pathsep + env.get('PATH', '')
        env['PYTHONIOENCODING'] = 'utf-8'
        self.log('RUN: ' + subprocess.list2cmdline([str(a) for a in args]))
        flags = subprocess.CREATE_NO_WINDOW if paths.IS_WINDOWS else 0
        # text mode splits on '\r' too, so tqdm's in-place bars arrive as lines
        p = subprocess.Popen([str(a) for a in args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             stdin=subprocess.DEVNULL, text=True, encoding='utf-8', errors='replace',
                             env=env, creationflags=flags)
        self._proc = p
        out_lines = []
        rx = re.compile(progress_pattern) if progress_pattern else None
        lock = threading.Lock()

        def pump(stream, keep):
            for line in stream:
                line = line.rstrip('\n')
                with lock:
                    if keep:
                        out_lines.append(line)
                    if line.strip():
                        with open(self.log_file, 'a', encoding='utf-8') as f:
                            f.write(line + '\n')
                if rx:
                    m = rx.search(line)
                    if m:
                        self._on_progress('percent', int(min(100.0, float(m.group(1)))))

        t_err = threading.Thread(target=pump, args=(p.stderr, False), daemon=True)
        t_err.start()
        pump(p.stdout, True)
        t_err.join()
        code = p.wait()
        self._proc = None
        if self._cancelled.is_set():
            raise Cancelled()
        return code, '\n'.join(out_lines)

    def sample_rate(self, path: str) -> int:
        _, out = self.run_tool([self.ffprobe, '-v', 'error', '-select_streams', 'a:0',
                                '-show_entries', 'stream=sample_rate',
                                '-of', 'default=noprint_wrappers=1:nokey=1', path])
        for line in out.splitlines():
            if line.strip().isdigit():
                return int(line.strip())
        return 0

    def ensure_rate(self, path: str) -> None:
        rate = self.job.sample_rate
        if rate == 'source' or self.sample_rate(path) == int(rate):
            return
        self.log(f"Resampling to {rate}Hz: {path}")
        p = Path(path)
        tmp = p.with_name(p.stem + '.rate.tmp' + p.suffix)
        code, _ = self.run_tool([self.ffmpeg, '-y', '-i', path, '-ar', rate, str(tmp)])
        if code != 0 or not tmp.exists():
            raise PipelineError('Resampling failed.')
        os.replace(tmp, path)

    def convert_stem(self, src_wav: str, dest_no_ext: str) -> str:
        """Convert a WAV stem to the chosen format. Returns the new file's path."""
        fmt = self.job.format
        ext_map = {'mp3': 'mp3', 'm4a': 'm4a', 'aac': 'm4a', 'alac': 'm4a', 'flac': 'flac',
                   'opus': 'opus', 'vorbis': 'ogg'}
        codec_map = {
            'mp3': ['-c:a', 'libmp3lame', '-q:a', '0'],
            'm4a': ['-c:a', 'aac', '-b:a', '256k'],
            'aac': ['-c:a', 'aac', '-b:a', '256k'],
            'alac': ['-c:a', 'alac'],
            'flac': ['-c:a', 'flac'],
            'opus': ['-c:a', 'libopus', '-b:a', '192k'],
            'vorbis': ['-c:a', 'libvorbis', '-q:a', '6'],
        }
        dest = f"{dest_no_ext}.{ext_map[fmt]}"
        args = [self.ffmpeg, '-y', '-i', src_wav] + codec_map[fmt]
        if self.job.sample_rate != 'source':
            args += ['-ar', self.job.sample_rate]
        code, _ = self.run_tool(args + [dest])
        if code != 0 or not os.path.exists(dest):
            raise PipelineError(f"Conversion to {fmt} failed.")
        return dest

    def audio_features(self, path: str, click_out):
        """BPM/key (+ optional click track). Non-fatal: failures are only logged."""
        try:
            args = [sys.executable, paths.FEAT_SCRIPT, path]
            if click_out:
                args += ['--click-track', click_out]
            code, out = self.run_tool(args)
            if code != 0:
                self.log('Feature detection exited nonzero (non-fatal).')
                return 0.0, ''
            for line in out.splitlines():
                if re.match(r'^\s*\{.*"bpm".*\}\s*$', line):
                    j = json.loads(line)
                    self.log(f"Detected: {j.get('bpm')} BPM, {j.get('key')}")
                    return float(j.get('bpm') or 0), str(j.get('key') or '')
        except Cancelled:
            raise
        except Exception as e:  # noqa: BLE001 - non-fatal by design
            self.log(f"Feature detection failed (non-fatal): {e}")
        return 0.0, ''

    def export_practice_speeds(self, final_path: str) -> None:
        """Slowed-down copies (atempo keeps pitch). Non-fatal."""
        rate_map = {'90': '0.9', '75': '0.75', '60': '0.6', '50': '0.5'}
        p = Path(final_path)
        for sp in self.job.practice_speeds:
            if sp not in rate_map:
                continue
            self.status(f"Exporting {sp}% practice copy...")
            out = p.with_name(f"{p.stem} - {sp}%{p.suffix}")
            code, _ = self.run_tool([self.ffmpeg, '-y', '-i', final_path,
                                     '-filter:a', 'atempo=' + rate_map[sp], str(out)])
            if code != 0:
                self.log(f"Practice-speed export {sp}% failed (non-fatal).")

    # --------------------------------------------------------------- run -----
    def run(self) -> Result:
        try:
            return self._run()
        except PipelineError as e:
            self.log(f"ERROR: {e}")
            raise
        except Cancelled:
            self.log('=== pipeline cancelled ===')
            raise

    def _run(self) -> Result:
        job = self.job
        self.log(f"=== pipeline start (v{__version__}, {sys.platform}) URL={job.url} Mode={job.mode} "
                 f"Model={job.model} Remove={','.join(job.remove)} Format={job.format} Rate={job.sample_rate} ===")
        Path(job.downloads_dir).mkdir(parents=True, exist_ok=True)

        # ---------- 1. Download ----------
        self.status('Downloading audio from YouTube...')
        self._on_progress('percent', 0)
        path_file = Path(tempfile.gettempdir()) / f"dts_path_{uuid.uuid4()}.txt"
        args = [sys.executable, '-m', 'yt_dlp', '-v', '--newline',
                '-f', 'bestaudio', '--extract-audio', '--audio-format', job.format,
                '--audio-quality', '0', '--no-playlist']
        if job.sample_rate != 'source':
            args += ['--postprocessor-args', f"ffmpeg:-ar {job.sample_rate}"]
        args += ['--ffmpeg-location', os.path.dirname(self.ffmpeg),
                 '-o', os.path.join(job.downloads_dir, '%(title)s.%(ext)s'),
                 '--print-to-file', 'after_move:filepath', str(path_file),
                 job.url]
        code, _ = self.run_tool(args, DOWNLOAD_PROGRESS)
        if code != 0 or not path_file.exists():
            raise PipelineError('Download failed. Check the URL and your internet connection.')
        lines = [ln for ln in path_file.read_text(encoding='utf-8').splitlines() if ln.strip()]
        path_file.unlink(missing_ok=True)
        file = lines[-1] if lines else ''
        if not file or not os.path.exists(file):
            raise PipelineError('Downloaded file not found.')
        self.log(f"Saved: {file}")
        self._on_progress('percent', 100)
        self.ensure_rate(file)
        title = Path(file).stem

        # ---------- 2. BPM/key on the source audio (before separation) ----------
        bpm, key = 0.0, ''
        if paths.FEAT_SCRIPT.exists():
            self.status('Analyzing BPM and key...')
            self._on_progress('marquee', 0)
            click = os.path.join(job.downloads_dir, f"{title} - Click Track.wav") if job.click_track else None
            bpm, key = self.audio_features(file, click)

        if job.mode == 'audio':
            self.export_practice_speeds(file)
            self.log('=== pipeline done (audio) ===')
            return Result(file, bpm, key)

        # ---------- 3. Separate (one WAV per stem) ----------
        self.status('Separating stems with AI... this can take several minutes (first run also downloads the model)')
        self._on_progress('percent', 0)
        code, _ = self.run_tool([sys.executable, '-m', 'demucs', '-n', job.model, '-o', job.stems_dir, file],
                                DEMUCS_PROGRESS)
        if code != 0:
            raise PipelineError('Stem separation failed. See log for details.')

        stem_dir = Path(job.stems_dir) / job.model / title
        keep = [s for s in MODEL_STEMS[job.model] if s not in job.remove]
        for k in keep:
            if not (stem_dir / f"{k}.wav").exists():
                raise PipelineError(f"Expected stem output not found: {k}.wav")

        # ---------- 4. Mix the kept stems ----------
        if len(keep) == 1:
            stem_file = str(stem_dir / f"{keep[0]}.wav")
        else:
            self.status('Mixing stems...')
            self._on_progress('marquee', 0)
            stem_file = str(stem_dir / 'dts_mix.wav')
            args = [self.ffmpeg, '-y']
            for k in keep:
                args += ['-i', str(stem_dir / f"{k}.wav")]
            args += ['-filter_complex', f"amix=inputs={len(keep)}:duration=longest:dropout_transition=0:normalize=0",
                     '-ac', '2', stem_file]
            code, _ = self.run_tool(args)
            if code != 0 or not os.path.exists(stem_file):
                raise PipelineError('Mixing stems failed.')
        self.ensure_rate(stem_file)

        # ---------- 5. Deliver in the configured format ----------
        self.status('Finalizing...')
        dest_no_ext = os.path.join(job.downloads_dir, f"{title} - {job.suffix}")
        if job.format in ('wav', 'best'):
            # stems are WAV already; 'best' has no meaning for stems - keep WAV
            dest = dest_no_ext + '.wav'
            try:
                shutil.copyfile(stem_file, dest)
            except OSError as e:
                raise PipelineError('Could not copy final file to the output folder.') from e
        else:
            dest = self.convert_stem(stem_file, dest_no_ext)

        self.export_practice_speeds(dest)
        self.log(f"=== pipeline done: {dest} ===")
        return Result(dest, bpm, key)
