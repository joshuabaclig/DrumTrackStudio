"""The pipeline end to end with real ffmpeg, offline: Pipeline.download is replaced
by a copy of a synthesized WAV (see conftest.fake_download). Checks the audio
that comes out sample-accurately, not just that files exist."""
import glob
import os
import tempfile
import threading
import time

import numpy as np
import pytest

from conftest import SR, make_wav, onsets, wav_info
from drumtrackstudio import paths
from drumtrackstudio.edit import EditRequest, EditSpec
from drumtrackstudio.pipeline import Cancelled, Job, Pipeline, PipelineError

BURSTS = (1.0, 2.0, 3.0, 4.0, 5.0)


def work_dirs():
    return set(glob.glob(os.path.join(tempfile.gettempdir(), 'dts_work_*')))


def job(tmp_path, **kw):
    kw.setdefault('mode', 'audio')
    kw.setdefault('format', 'wav')
    return Job(url='https://example.invalid/watch?v=test', remove=kw.pop('remove', []),
               suffix=kw.pop('suffix', ''), downloads_dir=str(tmp_path / 'Downloads'),
               stems_dir=str(tmp_path / 'Stems'), **kw)


@pytest.fixture
def source(tmp_path, fake_download):
    fake_download.source = make_wav(tmp_path / 'src' / 'source.wav', 6.0, BURSTS)
    return fake_download


def answer(choice, spec=None, record=None):
    def on_edit(req: EditRequest):
        if record is not None:
            record.append(req)
        # answer from another thread, like the GUI does
        threading.Timer(0.05, lambda: req.respond(choice, spec)).start()
    return on_edit


def test_apply_edit_is_sample_accurate(tmp_path, ffmpeg):
    src = make_wav(tmp_path / 'a.wav', 6.0, BURSTS)
    p = Pipeline(job(tmp_path), tmp_path / 'log.txt')
    out = str(tmp_path / 'b.wav')
    p.apply_edit(src, out, EditSpec(1.5, 4.5, 2.0), p.duration(src))
    frames, sr = wav_info(out)
    assert sr == SR
    assert abs(frames - 5.0 * SR) <= 1                       # 2 s lead-in + 3 s kept
    # bursts at 2.0/3.0/4.0 in the source land at lead_in + (t - start)
    assert onsets(out) == pytest.approx([2.5, 3.5, 4.5], abs=0.001)
    import soundfile as sf
    data, _ = sf.read(out, always_2d=True)
    assert np.abs(data[:int(2.0 * SR)]).max() == 0           # lead-in is digital silence


@pytest.mark.parametrize('spec, length, expected_onsets', [
    (EditSpec(0, None, 3.0), 9.0, [4.0, 5.0, 6.0, 7.0, 8.0]),   # lead-in only
    (EditSpec(2.5, None, 0), 3.5, [0.5, 1.5, 2.5]),              # cut an intro
    (EditSpec(0, 3.5, 0), 3.5, [1.0, 2.0, 3.0]),                 # cut an ending
])
def test_apply_edit_variants(tmp_path, ffmpeg, spec, length, expected_onsets):
    src = make_wav(tmp_path / 'a.wav', 6.0, BURSTS)
    p = Pipeline(job(tmp_path), tmp_path / 'log.txt')
    out = str(tmp_path / 'b.wav')
    p.apply_edit(src, out, spec, p.duration(src))
    frames, _ = wav_info(out)
    assert abs(frames - length * SR) <= 1
    assert onsets(out) == pytest.approx(expected_onsets, abs=0.001)


def test_editor_apply_audio_mode_wav(tmp_path, source):
    before = work_dirs()
    seen = []
    p = Pipeline(job(tmp_path), tmp_path / 'log.txt',
                 on_edit=answer(EditRequest.APPLY, EditSpec(1.5, 4.5, 2.0), seen))
    r = p.run()
    assert r.out_file == str(tmp_path / 'Downloads' / 'Test Song.wav')
    assert source.calls[0][1] == 'wav'                                  # downloaded as WAV for editing
    assert seen[0].duration == pytest.approx(6.0, abs=0.001) and seen[0].title == 'Test Song'
    assert abs(wav_info(r.out_file)[0] - 5.0 * SR) <= 1
    assert onsets(r.out_file) == pytest.approx([2.5, 3.5, 4.5], abs=0.001)
    assert work_dirs() == before                                        # scratch folder removed


@pytest.mark.parametrize('fmt, ext', [('mp3', 'mp3'), ('flac', 'flac'), ('opus', 'opus'), ('m4a', 'm4a'),
                                      ('best', 'wav')])
def test_editor_apply_encodes_once_to_chosen_format(tmp_path, source, fmt, ext):
    p = Pipeline(job(tmp_path, format=fmt), tmp_path / 'log.txt',
                 on_edit=answer(EditRequest.APPLY, EditSpec(1.5, 4.5, 2.0)))
    r = p.run()
    assert r.out_file.endswith(f"Test Song.{ext}") and os.path.exists(r.out_file)
    assert source.calls[0][1] == 'wav'
    assert p.duration(r.out_file) == pytest.approx(5.0, abs=0.06)   # lossy codecs pad a little
    assert os.listdir(tmp_path / 'Downloads') == [f"Test Song.{ext}"]


def test_editor_skip_keeps_original(tmp_path, source):
    p = Pipeline(job(tmp_path), tmp_path / 'log.txt', on_edit=answer(EditRequest.SKIP))
    r = p.run()
    assert abs(wav_info(r.out_file)[0] - 6.0 * SR) <= 1
    assert onsets(r.out_file) == pytest.approx(list(BURSTS), abs=0.001)


def test_editor_cancel_stops_job_and_cleans_up(tmp_path, source):
    before = work_dirs()
    p = Pipeline(job(tmp_path), tmp_path / 'log.txt', on_edit=answer(EditRequest.CANCEL))
    with pytest.raises(Cancelled):
        p.run()
    assert not os.listdir(tmp_path / 'Downloads')
    assert work_dirs() == before


def test_closing_app_while_editor_open_releases_worker(tmp_path, source):
    """The editor never answers; pipeline.cancel() (what closing the app does)
    must still end the job promptly."""
    p = Pipeline(job(tmp_path), tmp_path / 'log.txt', on_edit=lambda req: None)
    threading.Timer(0.5, p.cancel).start()
    t0 = time.monotonic()
    with pytest.raises(Cancelled):
        p.run()
    assert time.monotonic() - t0 < 10


def test_fixed_edit_spec_without_editor(tmp_path, source):
    """The CLI path: Job.edit_spec, no on_edit callback."""
    p = Pipeline(job(tmp_path, edit_spec=EditSpec(2.5, None, 1.0)), tmp_path / 'log.txt')
    r = p.run()
    assert abs(wav_info(r.out_file)[0] - 4.5 * SR) <= 1
    assert onsets(r.out_file) == pytest.approx([1.5, 2.5, 3.5], abs=0.001)


def test_bad_edit_is_a_readable_error(tmp_path, source):
    p = Pipeline(job(tmp_path, edit_spec=EditSpec(0, 60.0, 0)), tmp_path / 'log.txt')
    with pytest.raises(PipelineError, match='past the end'):
        p.run()


def test_no_editing_keeps_previous_behaviour(tmp_path, source):
    """Editor off: download straight to the output folder in the chosen format,
    no scratch folder, nothing re-encoded."""
    before = work_dirs()
    p = Pipeline(job(tmp_path, format='mp3'), tmp_path / 'log.txt')
    r = p.run()
    assert source.calls == [(str(tmp_path / 'Downloads'), 'mp3')]
    assert r.out_file == str(tmp_path / 'Downloads' / 'Test Song.mp3')
    assert work_dirs() == before


def test_child_python_is_console_interpreter(monkeypatch, tmp_path):
    fake = tmp_path / 'runtime'
    fake.mkdir()
    (fake / 'python.exe').write_text('')
    (fake / 'pythonw.exe').write_text('')
    monkeypatch.setattr('sys.executable', str(fake / 'pythonw.exe'))
    assert paths.python_exe() == str(fake / 'python.exe')
    monkeypatch.setattr('sys.executable', str(fake / 'python.exe'))
    assert paths.python_exe() == str(fake / 'python.exe')


# ------------------------------------------------- heavier: real analysis -----
def test_click_track_lines_up_with_edit(tmp_path, fake_download):
    """BPM detection runs on the EDITED audio, so the click track has the
    lead-in and lines up with the trimmed song."""
    pytest.importorskip('librosa')
    beats = [0.5 + i * 0.5 for i in range(20)]        # 120 BPM from 0.5 s to 10 s
    fake_download.source = make_wav(tmp_path / 'src' / 'beat.wav', 11.0, beats, burst_len=0.03)
    p = Pipeline(job(tmp_path, click_track=True), tmp_path / 'log.txt',
                 on_edit=answer(EditRequest.APPLY, EditSpec(1.9, None, 3.0)))
    r = p.run()
    assert r.bpm == pytest.approx(120, abs=3)
    click = tmp_path / 'Downloads' / 'Test Song - Click Track.wav'
    assert click.exists()
    assert wav_info(click)[0] == wav_info(r.out_file)[0]            # same length as the edited song
    song_beats = onsets(r.out_file)
    assert song_beats[0] == pytest.approx(3.1, abs=0.001)            # beat at 2.0, cut at 1.9, 3 s gap
    clicks = onsets(click, threshold=0.05)
    assert clicks and min(clicks) >= 3.0 - 0.05                       # no clicks in the lead-in
    # every click sits on a beat of the edited song (librosa frame resolution ~12 ms)
    for c in clicks:
        assert min(abs(c - b) for b in song_beats) < 0.03


@pytest.mark.slow
def test_drumless_mix_with_edit(tmp_path, fake_download):
    """Full separation path on the edited audio (downloads the demucs model the
    first time, so it's marked slow)."""
    pytest.importorskip('demucs')
    fake_download.source = make_wav(tmp_path / 'src' / 's.wav', 8.0, (1, 2, 3, 4, 5, 6, 7), noise_floor=0.01)
    p = Pipeline(job(tmp_path, mode='mix', remove=['drums'], suffix='Drumless', format='flac'),
                 tmp_path / 'log.txt', on_edit=answer(EditRequest.APPLY, EditSpec(1.5, 6.5, 2.0)))
    r = p.run()
    assert r.out_file == str(tmp_path / 'Downloads' / 'Test Song - Drumless.flac')
    assert p.duration(r.out_file) == pytest.approx(7.0, abs=0.01)
    # the source copy in Downloads carries the same edit
    assert p.duration(str(tmp_path / 'Downloads' / 'Test Song.flac')) == pytest.approx(7.0, abs=0.01)
    stems = tmp_path / 'Stems' / 'htdemucs' / 'Test Song'
    assert {f.name for f in stems.iterdir()} >= {'vocals.wav', 'bass.wav', 'other.wav', 'drums.wav'}
    assert abs(wav_info(stems / 'vocals.wav')[0] - 7.0 * SR) <= 1
