"""The Qt trim editor, headless (QT_QPA_PLATFORM=offscreen): waveform peaks,
marker logic, mouse dragging, keyboard, buttons, and the full GUI round trip
(main window -> worker thread -> editor -> worker -> finished file)."""
import os
import threading

import pytest

pytest.importorskip('PySide6')

from PySide6.QtCore import QPoint, Qt, QTimer  # noqa: E402
from PySide6.QtTest import QTest  # noqa: E402
from PySide6.QtWidgets import QDialog  # noqa: E402

from conftest import SR, make_wav, onsets, wav_info  # noqa: E402


@pytest.fixture
def wav(tmp_path):
    # silence until 1.2 s, bursts every second, silence after 5.3 s
    return make_wav(tmp_path / 'song.wav', 6.0, (1.2, 2.2, 3.2, 4.2, 5.2), burst_len=0.1)


@pytest.fixture
def dialog(qapp, wav):
    from drumtrackstudio.editor import TrimEditorDialog
    d = TrimEditorDialog(wav, 'Test Song', lead_in=2.5, audio=False)
    d.confirm_close = False
    d.resize(1000, 520)
    d.show()
    QTest.qWaitForWindowExposed(d)
    yield d
    d.release()
    d.close()
    d.deleteLater()


def test_peaks(wav):
    from drumtrackstudio.editor import Peaks
    p = Peaks(wav)
    assert p.duration == pytest.approx(6.0)
    lo, hi = p.columns(0, 6.0, 600)
    assert len(lo) == len(hi) == 600
    assert hi.max() == pytest.approx(0.8, abs=0.01) and lo.min() == pytest.approx(-0.8, abs=0.01)
    assert hi[:110].max() == 0                    # 0-1.1 s is silent
    assert hi[121] > 0.5                           # burst at 1.2 s -> column 120-121
    # deep zoom (more columns than buckets) still returns the requested width
    lo, hi = p.columns(1.2, 1.2005, 400)
    assert len(hi) == 400
    first, last = p.audible_range()
    assert first == pytest.approx(1.2, abs=0.002) and last == pytest.approx(5.3, abs=0.002)


def test_peaks_on_silence(tmp_path):
    from drumtrackstudio.editor import Peaks
    p = Peaks(make_wav(tmp_path / 's.wav', 2.0))
    assert p.audible_range() is None


def test_initial_state(dialog):
    s = dialog.spec()
    assert (s.start, s.end, s.lead_in) == (0.0, None, 2.5)   # untouched end means "to the end"
    assert dialog.spin_end.value() == pytest.approx(6.0)
    assert '2.5 s lead-in' in dialog.lbl_result.text() and '0:08.500' in dialog.lbl_result.text()
    assert not dialog.btn_play.isEnabled()                   # audio=False
    assert dialog.lbl_audio.isVisible()


def test_markers_clamp_and_sync(dialog):
    dialog.set_start(2.0)
    assert dialog.spin_start.value() == pytest.approx(2.0)
    dialog.set_end(1.0)                         # can't go before start
    assert dialog.view.end == pytest.approx(2.1)
    dialog.set_end(99)
    assert dialog.view.end == pytest.approx(6.0)
    dialog.set_start(10)                        # can't pass end
    assert dialog.view.start == pytest.approx(5.9)
    dialog.set_start(-3)
    assert dialog.view.start == 0
    dialog.spin_start.setValue(1.25)            # typing in the box moves the handle
    assert dialog.view.start == pytest.approx(1.25)


def test_time_box_accepts_typed_text(dialog):
    sb = dialog.spin_end
    sb.lineEdit().selectAll()
    QTest.keyClicks(sb.lineEdit(), '0:04.75')
    QTest.keyClick(sb.lineEdit(), Qt.Key.Key_Return)
    assert dialog.view.end == pytest.approx(4.75)
    assert sb.text() == '0:04.750'


def test_nudge_buttons(dialog):
    from PySide6.QtWidgets import QPushButton
    dialog.set_start(2.0)
    buttons = [b for b in dialog.findChildren(QPushButton) if b.text() == '+0.1 s']
    buttons[0].click()                          # first row = Start
    assert dialog.view.start == pytest.approx(2.1)


def test_trim_silence(dialog):
    dialog.btn_silence.click()
    assert dialog.view.start == pytest.approx(1.19, abs=0.003)
    assert dialog.view.end == pytest.approx(5.35, abs=0.003)
    dialog.btn_reset.click()
    assert (dialog.view.start, dialog.view.end) == (0.0, pytest.approx(6.0))


def test_drag_start_handle_with_mouse(dialog):
    v = dialog.view
    v.set_view(0, 6.0)
    y = v.height() // 2
    x0 = int(v.x_of(0.0)) + 2
    x1 = int(v.x_of(3.0))
    QTest.mousePress(v, Qt.MouseButton.LeftButton, Qt.KeyboardModifier.NoModifier, QPoint(x0, y))
    QTest.mouseMove(v, QPoint(x1, y))
    QTest.mouseRelease(v, Qt.MouseButton.LeftButton, Qt.KeyboardModifier.NoModifier, QPoint(x1, y))
    assert dialog.view.start == pytest.approx(3.0, abs=6.0 / v.width() * 2)
    assert dialog.spin_start.value() == pytest.approx(dialog.view.start, abs=0.001)


def test_click_seeks_and_keys_set_markers(dialog):
    v = dialog.view
    QTest.mouseClick(v, Qt.MouseButton.LeftButton, Qt.KeyboardModifier.NoModifier,
                     QPoint(int(v.x_of(2.0)), v.height() // 2))
    assert v.playhead == pytest.approx(2.0, abs=0.02)
    QTest.keyClick(dialog, Qt.Key.Key_BracketLeft)
    assert v.start == pytest.approx(v.playhead)
    dialog.seek(4.5)
    QTest.keyClick(dialog, Qt.Key.Key_BracketRight)
    assert v.end == pytest.approx(4.5)
    assert '0:04.500' in dialog.lbl_pos.text() or v.playhead == pytest.approx(4.5)


def test_zoom_and_scroll(dialog):
    v = dialog.view
    v.zoom(0.1, 3.0)
    assert v.view1 - v.view0 == pytest.approx(0.6)
    assert v.view0 <= 3.0 <= v.view1
    dialog.scroll.setValue(dialog.scroll.maximum())
    assert v.view1 == pytest.approx(6.0, abs=0.002)
    v.zoom(1e-6, 1.0)                                     # clamps at max zoom
    assert v.view1 - v.view0 == pytest.approx(0.05)
    dialog.btn_fit.click()
    assert (v.view0, v.view1) == (0.0, pytest.approx(6.0))


def test_escape_does_not_cancel(dialog):
    QTest.keyClick(dialog, Qt.Key.Key_Escape)
    assert dialog.isVisible()


@pytest.mark.parametrize('button, choice, code', [
    ('btn_apply', 'apply', QDialog.DialogCode.Accepted),
    ('btn_skip', 'skip', QDialog.DialogCode.Accepted),
    ('btn_cancel', 'cancel', QDialog.DialogCode.Rejected),
])
def test_buttons(dialog, button, choice, code):
    dialog.set_start(1.0)
    getattr(dialog, button).click()
    assert dialog.choice == choice
    assert dialog.result() == code
    assert not dialog.isVisible()


def test_window_close_cancels(dialog):
    dialog.close()
    assert dialog.choice == 'cancel'


def test_renders(dialog, tmp_path):
    """Paint every state once (catches drawing exceptions) and keep a screenshot."""
    dialog.set_start(1.1)
    dialog.set_end(5.4)
    dialog.seek(2.3)
    dialog.view.countdown = 1.5
    img = dialog.grab()
    dialog.view.countdown = None
    out = tmp_path / 'editor.png'
    assert img.save(str(out)) and out.stat().st_size > 1000
    shots = os.environ.get('DTS_SCREENSHOT_DIR')
    if shots:
        img.save(os.path.join(shots, 'editor.png'))


@pytest.mark.audio
def test_playback_moves_playhead(qapp, wav):
    from PySide6.QtMultimedia import QMediaDevices
    if not QMediaDevices.audioOutputs():
        pytest.skip('no audio output device')
    from drumtrackstudio.editor import TrimEditorDialog
    d = TrimEditorDialog(wav, 'x', audio=True)
    d.confirm_close = False
    try:
        if d.audio_out is None:
            pytest.skip(d._audio_note)
        d.audio_out.setVolume(0.0)       # don't actually beep at whoever runs the tests
        d.show()
        d.seek(1.0)
        d.toggle_play()
        QTest.qWait(1200)
        assert d.playing
        assert 1.3 < d.view.playhead < 3.0
        d.set_end(3.0)
        d.spin_lead.setValue(0.5)
        d.preview()                       # 0.5 s countdown, then plays start..end and stops
        assert d.view.countdown is not None
        QTest.qWait(400 + 500 + 3000 + 800)
        assert not d.playing and d.view.playhead == pytest.approx(3.0, abs=0.05)
    finally:
        d.release()
        d.close()


# ----------------------------------------------- main window, full round trip -----
@pytest.fixture
def window(qapp, monkeypatch):
    from drumtrackstudio import gui
    monkeypatch.setattr(gui.MainWindow, 'check_for_update', lambda self: None)
    monkeypatch.setattr(gui, 'reveal', lambda path: None)
    monkeypatch.setattr(gui, 'missing_tools', lambda mode: [])
    msgs = []
    monkeypatch.setattr(gui.QMessageBox, 'information', lambda *a, **k: msgs.append(a[2]))
    monkeypatch.setattr(gui.QMessageBox, 'critical', lambda *a, **k: msgs.append(a[2]))
    w = gui.MainWindow()
    w.messages = msgs
    yield w
    w.close()


def drive_editor(monkeypatch, action):
    """Make TrimEditorDialog.exec() run `action(dialog)` on the GUI thread instead
    of waiting for a person."""
    from drumtrackstudio.editor import TrimEditorDialog
    seen = {}

    def exec_(self):
        seen['dialog_thread'] = threading.current_thread() is threading.main_thread()
        self.confirm_close = False
        self.show()
        action(self)
        return self.result()
    monkeypatch.setattr(TrimEditorDialog, 'exec', exec_)
    return seen


def run_job(qapp, window, timeout_ms=60000):
    done = []
    window.bridge.finished.connect(lambda r, e: done.append((r, e)))
    window.start()
    elapsed = 0
    while not done and elapsed < timeout_ms:
        QTest.qWait(50)
        elapsed += 50
    assert done, 'pipeline never finished'
    return done[0]


def test_gui_round_trip_apply(qapp, window, monkeypatch, tmp_path, fake_download):
    fake_download.source = make_wav(tmp_path / 'src.wav', 6.0, (1.0, 2.0, 3.0, 4.0, 5.0))

    def edit(d):
        d.set_start(1.5)
        d.set_end(4.5)
        d.spin_lead.setValue(2.0)
        d.btn_apply.click()
    seen = drive_editor(monkeypatch, edit)
    window.txt_url.setText('https://example.invalid/watch?v=x')
    result, error = run_job(qapp, window)
    assert error == '' and result, window.messages
    assert seen['dialog_thread']                                  # editor ran on the GUI thread
    assert abs(wav_info(result.out_file)[0] - 5.0 * SR) <= 1
    assert onsets(result.out_file) == pytest.approx([2.5, 3.5, 4.5], abs=0.001)
    assert window.s['LeadInSeconds'] == 2.0                        # remembered for next time
    from drumtrackstudio import settings
    assert settings.load()['LeadInSeconds'] == 2.0
    assert window.btn_go.isEnabled() and window.pipeline is None


def test_gui_round_trip_cancel(qapp, window, monkeypatch, tmp_path, fake_download):
    fake_download.source = make_wav(tmp_path / 'src.wav', 3.0, (1.0,))
    drive_editor(monkeypatch, lambda d: d.btn_cancel.click())
    window.txt_url.setText('https://example.invalid/watch?v=x')
    result, error = run_job(qapp, window)
    assert result is None and error == 'Cancelled.'
    assert window.lbl_status.text() == 'Cancelled.'
    assert not window.messages                                     # no error popup for a cancel
    assert not os.listdir(window.s['OutputDir'])


def test_gui_editor_off_skips_editor(qapp, window, monkeypatch, tmp_path, fake_download):
    fake_download.source = make_wav(tmp_path / 'src.wav', 3.0, (1.0,))
    seen = drive_editor(monkeypatch, lambda d: pytest.fail('editor should not open'))
    window.chk_trim.setChecked(False)
    window.txt_url.setText('https://example.invalid/watch?v=x')
    result, error = run_job(qapp, window)
    assert result and not seen
    assert fake_download.calls[0][1] == window.s['Format']           # straight download, no WAV detour


def test_gui_editor_failure_continues_without_edits(qapp, window, monkeypatch, tmp_path, fake_download):
    fake_download.source = make_wav(tmp_path / 'src.wav', 3.0, (1.0,))
    from drumtrackstudio import editor, gui

    def boom(*a, **k):
        raise RuntimeError('simulated')
    monkeypatch.setattr(editor, 'TrimEditorDialog', boom)
    warned = []
    monkeypatch.setattr(gui.QMessageBox, 'warning', lambda *a, **k: warned.append(a[2]))
    window.txt_url.setText('https://example.invalid/watch?v=x')
    result, error = run_job(qapp, window)
    assert result and warned and 'simulated' in warned[0]
    assert abs(wav_info(result.out_file)[0] - 3.0 * SR) <= 1


def test_closing_window_with_editor_open(qapp, window, monkeypatch, tmp_path, fake_download):
    """Closing the app while the editor is up cancels the job and frees the worker."""
    fake_download.source = make_wav(tmp_path / 'src.wav', 3.0, (1.0,))
    gui_window = window

    def close_app(d):
        QTimer.singleShot(0, gui_window.close)
        # real exec() would block here; spin until the window close closes us
        for _ in range(100):
            if not d.isVisible():
                break
            QTest.qWait(20)
    drive_editor(monkeypatch, close_app)
    from drumtrackstudio import gui
    monkeypatch.setattr(gui.QMessageBox, 'warning',
                        lambda *a, **k: gui.QMessageBox.StandardButton.Yes)
    window.txt_url.setText('https://example.invalid/watch?v=x')
    result, error = run_job(qapp, window)
    assert result is None and error == 'Cancelled.'


def test_settings_checkbox_persists(qapp, window):
    from drumtrackstudio import settings
    assert window.chk_trim.isChecked()
    window.chk_trim.setChecked(False)
    assert settings.load()['TrimEditor'] is False


def test_main_window_renders(qapp, window):
    img = window.grab()
    assert not img.isNull()
    shots = os.environ.get('DTS_SCREENSHOT_DIR')
    if shots:
        img.save(os.path.join(shots, 'main.png'))
        window.centralWidget().setCurrentIndex(1)
        window.grab().save(os.path.join(shots, 'settings.png'))
