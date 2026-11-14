"""Trim & lead-in editor (Qt): shown after a download so the user can cut a sampled
intro/outro and add a silent lead-in before the song starts.

- Peaks:            min/max waveform envelope of a WAV (numpy + soundfile), zoomable
- WaveformView:     draws the waveform, ruler, cut regions, draggable start/end
                    handles and the playhead; click/drag to scrub, wheel to zoom
- ResultStrip:      what the result will be: [lead-in silence][kept audio]
- TrimEditorDialog: the window; plays audio with QtMultimedia when an output
                    device exists (the editor still works by eye without one)
"""
import html
import math
import time

import numpy as np
from PySide6.QtCore import QPointF, QRectF, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QColor, QFont, QKeySequence, QPainter, QPalette, QPen, QShortcut, QValidator
from PySide6.QtWidgets import (
    QAbstractSpinBox, QDialog, QDoubleSpinBox, QGridLayout, QHBoxLayout, QLabel, QMessageBox,
    QPushButton, QScrollBar, QSizePolicy, QVBoxLayout, QWidget,
)

from .edit import MAX_LEAD_IN, EditError, EditSpec, format_time, parse_time

ACCENT = QColor('#c6392b')
ACCENT_DARK = QColor('#a02c21')
MIN_KEEP = 0.1          # seconds - matches EditSpec validation
MIN_SPAN = 0.05         # seconds visible at maximum zoom
SILENCE_DB = -50.0      # "Trim silence" threshold


class Peaks:
    """Min/max envelope of a WAV at one bucket per BLOCK samples (about 1.5 ms at
    44.1 kHz), read in chunks so a long track never sits in memory as floats."""
    BLOCK = 64

    def __init__(self, path: str):
        import soundfile as sf
        info = sf.info(path)
        self.rate = info.samplerate
        self.duration = info.frames / info.samplerate if info.samplerate else 0.0
        lo, hi = [], []
        for block in sf.blocks(path, blocksize=self.BLOCK * 8192, dtype='float32', always_2d=True):
            mono = block.mean(axis=1)
            pad = (-len(mono)) % self.BLOCK
            if pad:
                mono = np.pad(mono, (0, pad))
            m = mono.reshape(-1, self.BLOCK)
            lo.append(m.min(axis=1))
            hi.append(m.max(axis=1))
        self.lo = np.concatenate(lo) if lo else np.zeros(1, np.float32)
        self.hi = np.concatenate(hi) if hi else np.zeros(1, np.float32)
        self.bucket = self.BLOCK / self.rate if self.rate else 1.0

    def columns(self, t0: float, t1: float, width: int):
        """(lo, hi) arrays of length width covering [t0, t1)."""
        width = max(1, int(width))
        n = len(self.hi)
        i0 = min(n - 1, max(0, int(t0 / self.bucket)))
        i1 = min(n, max(i0 + 1, int(math.ceil(t1 / self.bucket))))
        seg_lo, seg_hi = self.lo[i0:i1], self.hi[i0:i1]
        rel = np.linspace(0, len(seg_hi), width, endpoint=False).astype(np.int64)
        rel = np.clip(rel, 0, len(seg_hi) - 1)
        # reduceat: column k spans rel[k]..rel[k+1]; where zoomed in past one bucket
        # per column (rel repeats) it returns that single bucket, which is right
        return np.minimum.reduceat(seg_lo, rel), np.maximum.reduceat(seg_hi, rel)

    def audible_range(self, threshold_db: float = SILENCE_DB):
        """(first, last) time the signal exceeds threshold_db, or None if silent."""
        thr = 10 ** (threshold_db / 20)
        loud = np.nonzero(np.maximum(np.abs(self.lo), np.abs(self.hi)) > thr)[0]
        if not len(loud):
            return None
        return loud[0] * self.bucket, min(self.duration, (loud[-1] + 1) * self.bucket)


class TimeSpinBox(QDoubleSpinBox):
    """A seconds value shown and typed as m:ss.mmm (plain seconds are accepted too)."""

    def __init__(self, maximum: float, parent=None):
        super().__init__(parent)
        self.setDecimals(3)
        self.setRange(0.0, maximum)
        self.setSingleStep(0.01)
        self.setKeyboardTracking(False)   # commit on Enter / focus-out, not per keystroke
        self.setAccelerated(True)
        self.setMinimumWidth(110)

    def textFromValue(self, value: float) -> str:
        return format_time(value)

    def valueFromText(self, text: str) -> float:
        try:
            return parse_time(text)
        except EditError:
            return self.value()

    def validate(self, text, pos):
        try:
            v = parse_time(text)
        except EditError:
            return QValidator.State.Intermediate, text, pos
        if self.minimum() <= v <= self.maximum():
            return QValidator.State.Acceptable, text, pos
        return QValidator.State.Intermediate, text, pos


class WaveformView(QWidget):
    seeked = Signal(float)          # user clicked / scrubbed to a time
    start_dragged = Signal(float)
    end_dragged = Signal(float)
    view_changed = Signal()

    RULER = 20
    HANDLE_GRAB = 7   # px either side of a marker line that grabs it

    def __init__(self, peaks: Peaks, parent=None):
        super().__init__(parent)
        self.peaks = peaks
        self.duration = max(peaks.duration, MIN_SPAN)
        self.view0, self.view1 = 0.0, self.duration
        self.start, self.end = 0.0, self.duration
        self.playhead = 0.0
        self.countdown = None   # seconds left in a lead-in preview, or None
        self._drag = None
        self.setMouseTracking(True)
        self.setMinimumHeight(170)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)

    # ----------------------------------------------------------- geometry -----
    def x_of(self, t: float) -> float:
        return (t - self.view0) / (self.view1 - self.view0) * self.width()

    def t_of(self, x: float) -> float:
        return min(self.duration, max(0.0, self.view0 + x / max(1, self.width()) * (self.view1 - self.view0)))

    def set_view(self, t0: float, t1: float) -> None:
        span = min(self.duration, max(MIN_SPAN, t1 - t0))
        t0 = min(max(0.0, t0), self.duration - span)
        self.view0, self.view1 = t0, t0 + span
        self.view_changed.emit()
        self.update()

    def zoom(self, factor: float, anchor: float) -> None:
        """factor < 1 zooms in, keeping the time `anchor` under the same pixel."""
        span = self.view1 - self.view0
        new = min(self.duration, max(MIN_SPAN, span * factor))
        frac = (anchor - self.view0) / span if span else 0.5
        self.set_view(anchor - frac * new, anchor - frac * new + new)

    def ensure_visible(self, t: float) -> None:
        span = self.view1 - self.view0
        if t < self.view0 or t > self.view1:
            self.set_view(t - span * 0.1, t - span * 0.1 + span)

    # ------------------------------------------------------------- paint -----
    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        pal = self.palette()
        w, h = self.width(), self.height()
        base, text = pal.color(QPalette.ColorRole.Base), pal.color(QPalette.ColorRole.Text)
        dark = base.lightness() < 128
        p.fillRect(0, 0, w, h, base)

        # ruler
        p.fillRect(0, 0, w, self.RULER, pal.color(QPalette.ColorRole.Window))
        span = self.view1 - self.view0
        step = next((s for s in (0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600)
                     if s / span * w >= 80), 600)
        decimals = 0 if step >= 1 else (1 if step >= 0.1 else 2)
        small = QFont(self.font())
        small.setPointSizeF(max(7.0, small.pointSizeF() * 0.85))
        p.setFont(small)
        grid = QColor(text)
        grid.setAlpha(40)
        t = math.floor(self.view0 / step) * step
        while t <= self.view1 + 1e-9:
            x = self.x_of(t)
            p.setPen(text)
            p.drawLine(QPointF(x, self.RULER - 5), QPointF(x, self.RULER))
            p.drawText(QPointF(x + 3, self.RULER - 7), format_time(t, decimals))
            p.setPen(grid)
            p.drawLine(QPointF(x, self.RULER), QPointF(x, h))
            t += step

        # waveform: one vertical line per pixel column
        top = self.RULER + 4
        mid = top + (h - top) / 2
        amp = (h - top) / 2 - 2
        lo, hi = self.peaks.columns(self.view0, self.view1, w)
        wave = QColor(ACCENT) if not dark else QColor('#e8695c')
        p.setPen(QPen(wave, 1))
        for x in range(len(hi)):
            y1 = mid - float(hi[x]) * amp
            y2 = mid - float(lo[x]) * amp
            if y2 - y1 < 1:
                y2 = y1 + 1
            p.drawLine(QPointF(x + 0.5, y1), QPointF(x + 0.5, y2))
        center = QColor(text)
        center.setAlpha(60)
        p.setPen(center)
        p.drawLine(QPointF(0, mid), QPointF(w, mid))

        # cut regions (dimmed) and the start/end handles
        # neutral gray reads as "removed" on both light and dark backgrounds
        shade = QColor(128, 128, 128, 110 if not dark else 150)
        xs, xe = self.x_of(self.start), self.x_of(self.end)
        if xs > 0:
            p.fillRect(QRectF(0, top, min(xs, w), h - top), shade)
        if xe < w:
            p.fillRect(QRectF(max(0.0, xe), top, w - max(0.0, xe), h - top), shade)
        for x, label in ((xs, 'Start'), (xe, 'End')):
            if -10 <= x <= w + 10:
                p.setPen(QPen(ACCENT_DARK if not dark else QColor('#ff8a7d'), 2))
                p.drawLine(QPointF(x, top), QPointF(x, h))
                tab = QRectF(x - (36 if label == 'End' else 0), top, 36, 15)
                p.fillRect(tab, ACCENT_DARK)
                p.setPen(Qt.GlobalColor.white)
                p.drawText(tab, Qt.AlignmentFlag.AlignCenter, label)

        # playhead
        xp = self.x_of(self.playhead)
        if 0 <= xp <= w:
            p.setPen(QPen(text, 1.5))
            p.drawLine(QPointF(xp, self.RULER), QPointF(xp, h))

        if self.countdown is not None:
            f = QFont(self.font())
            f.setPointSizeF(f.pointSizeF() * 2)
            f.setBold(True)
            p.setFont(f)
            p.setPen(text)
            p.drawText(QRectF(0, top, w, h - top), Qt.AlignmentFlag.AlignCenter,
                       f"Lead-in  {max(0.0, self.countdown):.1f} s")
        p.end()

    # ------------------------------------------------------------- mouse -----
    def _handle_at(self, x: float):
        ds, de = abs(x - self.x_of(self.start)), abs(x - self.x_of(self.end))
        if min(ds, de) > self.HANDLE_GRAB:
            return None
        return 'start' if ds <= de else 'end'

    def mousePressEvent(self, e) -> None:
        if e.button() != Qt.MouseButton.LeftButton:
            return
        x = e.position().x()
        self._drag = self._handle_at(x) or 'seek'
        self._drag_to(x)

    def mouseMoveEvent(self, e) -> None:
        x = e.position().x()
        if self._drag:
            self._drag_to(x)
        else:
            self.setCursor(Qt.CursorShape.SizeHorCursor if self._handle_at(x) else Qt.CursorShape.IBeamCursor)

    def mouseReleaseEvent(self, _e) -> None:
        self._drag = None

    def _drag_to(self, x: float) -> None:
        t = self.t_of(x)
        {'start': self.start_dragged, 'end': self.end_dragged, 'seek': self.seeked}[self._drag].emit(t)

    def wheelEvent(self, e) -> None:
        d = e.angleDelta()
        span = self.view1 - self.view0
        if d.x() or e.modifiers() & Qt.KeyboardModifier.ShiftModifier:   # pan
            steps = (d.x() or d.y()) / 120
            self.set_view(self.view0 - steps * span * 0.1, self.view1 - steps * span * 0.1)
        elif d.y():                                                         # zoom at the cursor
            self.zoom(0.8 ** (d.y() / 120), self.t_of(e.position().x()))
        e.accept()


class ResultStrip(QWidget):
    """A thin bar showing the result's shape: [lead-in silence][kept audio]."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.lead_in, self.kept = 0.0, 1.0
        self.setFixedHeight(18)

    def set_parts(self, lead_in: float, kept: float) -> None:
        self.lead_in, self.kept = lead_in, kept
        self.update()

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        w, h = self.width(), self.height()
        total = max(1e-9, self.lead_in + self.kept)
        xl = w * self.lead_in / total
        pal = self.palette()
        gap = QColor(pal.color(QPalette.ColorRole.Text))
        gap.setAlpha(45)
        p.fillRect(QRectF(0, 0, xl, h), gap)
        p.fillRect(QRectF(xl, 0, w - xl, h), ACCENT)
        p.setPen(pal.color(QPalette.ColorRole.Text))
        if xl > 60:
            p.drawText(QRectF(0, 0, xl, h), Qt.AlignmentFlag.AlignCenter, f"{self.lead_in:g} s gap")
        p.setPen(Qt.GlobalColor.white)
        p.drawText(QRectF(xl, 0, w - xl, h), Qt.AlignmentFlag.AlignCenter, 'song')
        p.end()


class TrimEditorDialog(QDialog):
    """Modal editor. After exec(): .choice is 'apply' | 'skip' | 'cancel' and
    .spec() is the EditSpec to apply (for 'apply')."""
    APPLY, SKIP, CANCEL = 'apply', 'skip', 'cancel'

    def __init__(self, path: str, title: str = '', lead_in: float = 0.0, parent=None, audio: bool = True):
        super().__init__(parent)
        self.path = path
        self.choice = self.CANCEL
        self._finished = False
        self.confirm_close = True   # tests turn this off to close without a prompt
        self.peaks = Peaks(path)
        self.duration = self.peaks.duration
        self.setWindowTitle(f"Trim & lead-in  -  {title}" if title else 'Trim & lead-in')
        self.setSizeGripEnabled(True)
        self.resize(960, 520)

        self.player = None
        self.audio_out = None
        self._countdown_end = None
        self._preview = False
        self._pending_ms = None
        self._audio_note = ''

        v = QVBoxLayout(self)
        head = QLabel(f"<b>{html.escape(title)}</b>" if title else "")
        head.setTextFormat(Qt.TextFormat.RichText)
        v.addWidget(head)
        hint = QLabel('Drag the <b>Start</b> / <b>End</b> handles (or type times below) to cut a sampled '
                      'intro or ending. Click the waveform to move the playhead; scroll to zoom, '
                      'Shift+scroll to pan. Keys: Space play/pause, [ / ] set start/end at the playhead, '
                      'P preview.')
        hint.setWordWrap(True)
        v.addWidget(hint)

        self.view = WaveformView(self.peaks)
        v.addWidget(self.view, 1)
        self.scroll = QScrollBar(Qt.Orientation.Horizontal)
        v.addWidget(self.scroll)

        # transport
        row = QHBoxLayout()
        self.btn_play = QPushButton('Play')
        self.btn_stop = QPushButton('Stop')
        self.btn_preview = QPushButton('Preview from start (with lead-in)')
        self.btn_fit = QPushButton('Zoom to fit')
        for b in (self.btn_play, self.btn_stop, self.btn_preview, self.btn_fit):
            b.setAutoDefault(False)
            row.addWidget(b)
        row.addStretch()
        self.lbl_pos = QLabel()
        f = self.lbl_pos.font()
        f.setFamily('Consolas' if f.family() == 'Segoe UI' else 'monospace')
        f.setStyleHint(QFont.StyleHint.Monospace)
        self.lbl_pos.setFont(f)
        row.addWidget(self.lbl_pos)
        v.addLayout(row)

        # start / end / lead-in
        g = QGridLayout()
        self.spin_start = TimeSpinBox(self.duration)
        self.spin_end = TimeSpinBox(self.duration)
        self.spin_end.setValue(self.duration)
        for r, (name, spin, setter) in enumerate((('Start:', self.spin_start, self.set_start),
                                                   ('End:', self.spin_end, self.set_end))):
            g.addWidget(QLabel(name), r, 0)
            g.addWidget(spin, r, 1)
            spin.valueChanged.connect(setter)
            col = 2
            for label, delta in (('-0.1 s', -0.1), ('-0.01 s', -0.01), ('+0.01 s', 0.01), ('+0.1 s', 0.1)):
                b = QPushButton(label)
                b.setAutoDefault(False)
                b.setMaximumWidth(70)
                b.clicked.connect(lambda _=False, s=spin, d=delta: s.setValue(s.value() + d))
                g.addWidget(b, r, col)
                col += 1
            at = QPushButton('Set at playhead')
            at.setAutoDefault(False)
            at.clicked.connect(lambda _=False, fn=setter: fn(self.view.playhead))
            g.addWidget(at, r, col)
            go = QPushButton('Go to')
            go.setAutoDefault(False)
            go.clicked.connect(lambda _=False, s=spin: self.seek(s.value()))
            g.addWidget(go, r, col + 1)
        self.btn_silence = QPushButton('Trim silence')
        self.btn_silence.setAutoDefault(False)
        self.btn_silence.setToolTip('Move Start/End to where the sound actually begins and ends')
        g.addWidget(self.btn_silence, 0, 8)
        self.btn_reset = QPushButton('Reset')
        self.btn_reset.setAutoDefault(False)
        g.addWidget(self.btn_reset, 1, 8)

        g.addWidget(QLabel('Lead-in gap:'), 2, 0)
        self.spin_lead = QDoubleSpinBox()
        self.spin_lead.setRange(0.0, MAX_LEAD_IN)
        self.spin_lead.setDecimals(1)
        self.spin_lead.setSingleStep(0.5)
        self.spin_lead.setSuffix(' s')
        self.spin_lead.setValue(min(MAX_LEAD_IN, max(0.0, float(lead_in))))
        self.spin_lead.setButtonSymbols(QAbstractSpinBox.ButtonSymbols.UpDownArrows)
        g.addWidget(self.spin_lead, 2, 1)
        lead_note = QLabel('silence added before the song, so you have time to get to the kit')
        lead_note.setWordWrap(True)
        g.addWidget(lead_note, 2, 2, 1, 7)
        g.setColumnStretch(9, 1)
        v.addLayout(g)

        self.strip = ResultStrip()
        v.addWidget(self.strip)
        self.lbl_result = QLabel()
        v.addWidget(self.lbl_result)
        self.lbl_audio = QLabel()
        self.lbl_audio.setWordWrap(True)
        self.lbl_audio.setStyleSheet(f"color: {ACCENT.name()};")
        self.lbl_audio.hide()
        v.addWidget(self.lbl_audio)

        btns = QHBoxLayout()
        self.btn_cancel = QPushButton('Cancel job')
        self.btn_skip = QPushButton('Keep original')
        self.btn_skip.setToolTip('Continue without trimming or adding a lead-in')
        self.btn_apply = QPushButton('Apply and continue')
        self.btn_apply.setDefault(True)
        self.btn_cancel.setAutoDefault(False)
        self.btn_skip.setAutoDefault(False)
        btns.addWidget(self.btn_cancel)
        btns.addStretch()
        btns.addWidget(self.btn_skip)
        btns.addWidget(self.btn_apply)
        v.addLayout(btns)

        # wiring
        self.view.seeked.connect(self.seek)
        self.view.start_dragged.connect(self.set_start)
        self.view.end_dragged.connect(self.set_end)
        self.view.view_changed.connect(self._sync_scrollbar)
        self.scroll.valueChanged.connect(self._scrolled)
        self.btn_play.clicked.connect(self.toggle_play)
        self.btn_stop.clicked.connect(self.stop)
        self.btn_preview.clicked.connect(self.preview)
        self.btn_fit.clicked.connect(lambda: self.view.set_view(0.0, self.duration))
        self.btn_silence.clicked.connect(self.trim_silence)
        self.btn_reset.clicked.connect(self.reset)
        self.spin_lead.valueChanged.connect(self._update_result)
        self.btn_apply.clicked.connect(lambda: self._finish(self.APPLY))
        self.btn_skip.clicked.connect(lambda: self._finish(self.SKIP))
        self.btn_cancel.clicked.connect(lambda: self._finish(self.CANCEL))
        for key, fn in ((Qt.Key.Key_Space, self.toggle_play), (Qt.Key.Key_BracketLeft,
                        lambda: self.set_start(self.view.playhead)),
                        (Qt.Key.Key_BracketRight, lambda: self.set_end(self.view.playhead)),
                        (Qt.Key.Key_P, self.preview)):
            QShortcut(QKeySequence(key), self, activated=fn)

        self.timer = QTimer(self)
        self.timer.setInterval(30)
        self.timer.timeout.connect(self._tick)

        if audio:
            self._init_audio()
        else:
            self._disable_audio('Playback is turned off.')
        self._sync_scrollbar()
        self._update_result()

    # ------------------------------------------------------------- audio -----
    def _init_audio(self) -> None:
        try:
            from PySide6.QtMultimedia import QAudioOutput, QMediaDevices, QMediaPlayer
        except ImportError:
            self._disable_audio('Playback is unavailable (Qt Multimedia is missing).')
            return
        if not QMediaDevices.audioOutputs():
            self._disable_audio('No audio output device was found, so playback is off. You can still '
                                'trim by eye with the waveform and the time fields.')
            return
        self.player = QMediaPlayer(self)
        self.audio_out = QAudioOutput(self)
        self.player.setAudioOutput(self.audio_out)
        self.player.errorOccurred.connect(
            lambda _err, msg='': self._disable_audio(f"Playback failed ({msg or 'unknown error'}). "
                                                     'You can still trim by eye.'))
        self.player.playbackStateChanged.connect(self._state_changed)
        self.player.mediaStatusChanged.connect(self._media_status_changed)
        self.player.setSource(QUrl.fromLocalFile(self.path))
        self.timer.start()

    def _media_ready(self) -> bool:
        from PySide6.QtMultimedia import QMediaPlayer
        S = QMediaPlayer.MediaStatus
        return self.player.mediaStatus() in (S.LoadedMedia, S.BufferingMedia, S.BufferedMedia, S.EndOfMedia)

    def _set_player_pos(self, t: float) -> None:
        """Seek the player. Loading is asynchronous and a seek before the media has
        loaded is silently dropped, so remember it and apply it once loaded."""
        ms = int(round(t * 1000))
        if self._media_ready():
            self._pending_ms = None
            self.player.setPosition(ms)
        else:
            self._pending_ms = ms

    def _media_status_changed(self, _status) -> None:
        if self._pending_ms is not None and self._media_ready():
            ms, self._pending_ms = self._pending_ms, None
            self.player.setPosition(ms)

    def _disable_audio(self, why: str) -> None:
        self._audio_note = why
        self.lbl_audio.setText(why)
        self.lbl_audio.show()
        for b in (self.btn_play, self.btn_stop, self.btn_preview):
            b.setEnabled(False)
        if self.player:
            self.player.stop()

    @property
    def playing(self) -> bool:
        if not self.player:
            return False
        from PySide6.QtMultimedia import QMediaPlayer
        return self.player.playbackState() == QMediaPlayer.PlaybackState.PlayingState

    def _state_changed(self, _state) -> None:
        self.btn_play.setText('Pause' if self.playing else 'Play')

    def toggle_play(self) -> None:
        if not self.player or not self.btn_play.isEnabled():
            return
        self._countdown_end = None
        self.view.countdown = None
        if self.playing:
            self.player.pause()
            return
        self._preview = False
        if self.view.playhead >= self.duration - 0.05:
            self.seek(self.view.start)
        self._set_player_pos(self.view.playhead)
        self.player.play()

    def stop(self) -> None:
        self._countdown_end = None
        self.view.countdown = None
        self._preview = False
        if self.player:
            self.player.pause()
        self.seek(self.view.start)

    def preview(self) -> None:
        """Count down the lead-in, then play from the start point to the end point:
        exactly what the finished track will sound like."""
        if not self.player or not self.btn_preview.isEnabled():
            return
        self.player.pause()
        self.seek(self.view.start)
        self._preview = True
        lead = self.spin_lead.value()
        if lead > 0:
            self._countdown_end = time.monotonic() + lead
            self.view.countdown = lead
            self.view.update()
        else:
            self._start_preview_playback()

    def _start_preview_playback(self) -> None:
        self._countdown_end = None
        self.view.countdown = None
        self._set_player_pos(self.view.start)
        self.player.play()

    def _tick(self) -> None:
        if self._countdown_end is not None:
            left = self._countdown_end - time.monotonic()
            if left <= 0:
                self._start_preview_playback()
            else:
                self.view.countdown = left
            self.view.update()
            return
        if self.playing:
            t = self.player.position() / 1000.0
            if self._preview and t >= self.view.end:
                self.player.pause()
                self._preview = False
                t = self.view.end
            self.view.playhead = min(t, self.duration)
            self.view.ensure_visible(self.view.playhead)
            self._update_pos()
            self.view.update()

    def seek(self, t: float) -> None:
        t = min(max(0.0, float(t)), self.duration)
        self.view.playhead = t
        if self.player:
            self._set_player_pos(t)
        self._update_pos()
        self.view.update()

    # ----------------------------------------------------------- markers -----
    def set_start(self, t: float) -> None:
        t = min(max(0.0, float(t)), self.view.end - MIN_KEEP)
        self.view.start = t
        if abs(self.spin_start.value() - t) > 0.0005:
            self.spin_start.blockSignals(True)
            self.spin_start.setValue(t)
            self.spin_start.blockSignals(False)
        self.view.update()
        self._update_result()

    def set_end(self, t: float) -> None:
        t = max(min(self.duration, float(t)), self.view.start + MIN_KEEP)
        self.view.end = t
        if abs(self.spin_end.value() - t) > 0.0005:
            self.spin_end.blockSignals(True)
            self.spin_end.setValue(t)
            self.spin_end.blockSignals(False)
        self.view.update()
        self._update_result()

    def trim_silence(self) -> None:
        r = self.peaks.audible_range()
        if r is None:
            return
        first, last = r
        # a few ms of margin so a soft attack isn't clipped
        self.set_end(self.duration)
        self.set_start(max(0.0, first - 0.01))
        self.set_end(min(self.duration, last + 0.05))
        self.seek(self.view.start)

    def reset(self) -> None:
        self.set_start(0.0)
        self.set_end(self.duration)
        self.view.set_view(0.0, self.duration)
        self.seek(0.0)

    # ------------------------------------------------------------ result -----
    def spec(self) -> EditSpec:
        end = None if self.view.end >= self.duration - 0.0005 else round(self.view.end, 6)
        return EditSpec(start=round(self.view.start, 6), end=end, lead_in=round(self.spin_lead.value(), 3))

    def _update_result(self) -> None:
        kept = self.view.end - self.view.start
        lead = self.spin_lead.value()
        self.strip.set_parts(lead, kept)
        parts = []
        if lead > 0:
            parts.append(f"{lead:g} s lead-in")
        parts.append(f"{format_time(kept)} of the song")
        self.lbl_result.setText(f"Result: {' + '.join(parts)} = {format_time(lead + kept)}"
                                f"   (original {format_time(self.duration)})")
        self._update_pos()

    def _update_pos(self) -> None:
        self.lbl_pos.setText(f"{format_time(self.view.playhead)} / {format_time(self.duration)}")

    def _sync_scrollbar(self) -> None:
        span = self.view.view1 - self.view.view0
        self.scroll.blockSignals(True)
        self.scroll.setRange(0, max(0, int(round((self.duration - span) * 1000))))
        self.scroll.setPageStep(max(1, int(span * 1000)))
        self.scroll.setSingleStep(max(1, int(span * 100)))
        self.scroll.setValue(int(round(self.view.view0 * 1000)))
        self.scroll.blockSignals(False)

    def _scrolled(self, value: int) -> None:
        span = self.view.view1 - self.view.view0
        self.view.set_view(value / 1000.0, value / 1000.0 + span)

    # ------------------------------------------------------------ closing -----
    def _finish(self, choice: str) -> None:
        self.choice = choice
        self._finished = True
        self.release()
        if choice == self.CANCEL:
            self.reject()
        else:
            self.accept()

    def release(self) -> None:
        """Stop playback and let go of the file (Windows locks open files)."""
        self.timer.stop()
        if self.player:
            self.player.stop()
            self.player.setSource(QUrl())

    def keyPressEvent(self, e) -> None:
        # Esc would silently cancel the whole job - make it a no-op instead
        if e.key() == Qt.Key.Key_Escape:
            e.ignore()
            return
        super().keyPressEvent(e)

    def closeEvent(self, e) -> None:
        """The window's X button: confirm, since it cancels the job."""
        if not self._finished and self.confirm_close:
            ans = QMessageBox.question(self, 'Trim & lead-in',
                                       'Close the editor and cancel this job?\n\n'
                                       'Choose "Keep original" instead to continue without edits.')
            if ans != QMessageBox.StandardButton.Yes:
                e.ignore()
                return
        self.choice = self.choice if self._finished else self.CANCEL
        self._finished = True
        self.release()
        super().closeEvent(e)
