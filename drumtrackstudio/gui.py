"""Qt (PySide6) window - same two tabs, modes and settings as the WinForms app.
The pipeline runs on a worker thread and reports back through Qt signals."""
import json
import os
import subprocess
import sys
import threading
import urllib.request
from pathlib import Path

from PySide6.QtCore import QObject, Qt, QTimer, QUrl, Signal
from PySide6.QtGui import QColor, QDesktopServices, QIcon, QPalette
from PySide6.QtWidgets import (
    QApplication, QButtonGroup, QCheckBox, QComboBox, QFileDialog, QGridLayout, QGroupBox,
    QHBoxLayout, QLabel, QLineEdit, QMainWindow, QMessageBox, QProgressBar, QPushButton,
    QRadioButton, QTabWidget, QVBoxLayout, QWidget,
)

from . import REPO_SLUG, __version__, paths, settings
from .pipeline import Cancelled, Job, Pipeline, PipelineError, missing_tools, open_log, write_log

TITLE = 'Drum Track Studio'
ACCENT = '#c6392b'
ACCENT_DARK = '#a02c21'


class Bridge(QObject):
    """Thread-safe hand-off from the worker thread to the GUI thread."""
    status = Signal(str)
    progress = Signal(str, int)
    finished = Signal(object, str)   # (Result or None, error message)
    update_available = Signal(str)


def reveal(path: str) -> None:
    """Show a file in the OS file manager (selected, where the OS supports it)."""
    try:
        if paths.IS_WINDOWS:
            subprocess.Popen(['explorer', f'/select,{path}'])
            return
        if paths.IS_MAC:
            subprocess.Popen(['open', '-R', path])
            return
    except OSError:
        pass
    open_folder(os.path.dirname(path))


def open_folder(path: str) -> None:
    Path(path).mkdir(parents=True, exist_ok=True)
    QDesktopServices.openUrl(QUrl.fromLocalFile(path))


def small(label: QLabel) -> QLabel:
    f = label.font()
    f.setPointSizeF(f.pointSizeF() * 0.88)
    label.setFont(f)
    label.setWordWrap(True)
    # muted text: 65% of the way from the background to the text color, so it
    # stays readable in both light and dark themes
    pal = label.palette()
    fg, bg = pal.color(QPalette.ColorRole.WindowText), pal.color(QPalette.ColorRole.Window)
    pal.setColor(QPalette.ColorRole.WindowText, QColor(
        *(int(b + (f - b) * 0.65) for f, b in zip(fg.getRgb()[:3], bg.getRgb()[:3]))))
    label.setPalette(pal)
    return label


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(f"{TITLE}  v{__version__}")
        icon = paths.ROOT / 'app.ico'
        if icon.exists():
            self.setWindowIcon(QIcon(str(icon)))
        self.s = settings.load()
        for d in (self.s['OutputDir'], self.s['StemsDir']):
            try:
                Path(d).mkdir(parents=True, exist_ok=True)
            except OSError:
                pass
        self.log_file = open_log()
        self.pipeline = None
        self.bridge = Bridge()
        self.bridge.status.connect(self.on_status)
        self.bridge.progress.connect(self.on_progress)
        self.bridge.finished.connect(self.on_finished)
        self.bridge.update_available.connect(self.on_update_available)

        tabs = QTabWidget()
        tabs.addTab(self.build_download_tab(), 'Download')
        tabs.addTab(self.build_settings_tab(), 'Settings')
        self.setCentralWidget(tabs)
        self.setMinimumWidth(580)

        self.saved_timer = QTimer(self, singleShot=True, interval=2500)
        self.saved_timer.timeout.connect(lambda: self.lbl_saved.setText(''))
        self.update_stem_checks()
        write_log(self.log_file, f"App started v{__version__} ({sys.platform})")
        threading.Thread(target=self.check_for_update, daemon=True).start()

    # ------------------------------------------------------- Download tab -----
    def build_download_tab(self) -> QWidget:
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(20, 16, 20, 16)

        top = QHBoxLayout()
        top.addWidget(QLabel('YouTube URL:'))
        top.addStretch()
        self.lbl_update = QLabel('')
        self.lbl_update.setOpenExternalLinks(True)
        top.addWidget(self.lbl_update)
        v.addLayout(top)

        row = QHBoxLayout()
        self.txt_url = QLineEdit()
        self.txt_url.setPlaceholderText('https://www.youtube.com/watch?v=...')
        self.txt_url.returnPressed.connect(self.start)
        row.addWidget(self.txt_url)
        btn_paste = QPushButton('Paste')
        btn_paste.clicked.connect(lambda: self.txt_url.setText(QApplication.clipboard().text().strip()))
        row.addWidget(btn_paste)
        v.addLayout(row)
        v.addSpacing(8)

        grp = QGroupBox('What do you want?')
        g = QVBoxLayout(grp)
        self.r_audio = QRadioButton('Audio Only  (download, no separation)')
        self.r_karaoke = QRadioButton('Vocal Karaoke  (vocals removed - instrumental backing track)')
        self.r_drumless = QRadioButton('Drumless  (drums removed - play along on your kit)')
        self.r_custom = QRadioButton('Custom mix  (choose which stems to remove)')
        self.r_audio.setChecked(True)
        self.modes = QButtonGroup(self)
        for r in (self.r_audio, self.r_karaoke, self.r_drumless, self.r_custom):
            self.modes.addButton(r)
            g.addWidget(r)
        self.r_custom.toggled.connect(self.update_stem_checks)

        stems = QGridLayout()
        stems.setContentsMargins(20, 0, 0, 0)
        self.stem_checks = {}
        for i, stem in enumerate(settings.ALL_STEMS):
            cb = QCheckBox(stem)
            cb.setChecked(stem in self.s['CustomRemove'])
            cb.toggled.connect(self.on_custom_remove_changed)
            stems.addWidget(cb, i // 3, i % 3)
            self.stem_checks[stem] = cb
        g.addLayout(stems)
        v.addWidget(grp)
        v.addSpacing(8)

        self.bar = QProgressBar()
        self.bar.setRange(0, 100)
        self.bar.setValue(0)
        self.bar.setTextVisible(False)
        self.bar.setFixedHeight(14)
        v.addWidget(self.bar)
        self.lbl_status = small(QLabel('Ready.'))
        self.lbl_status.setMinimumHeight(34)
        self.lbl_status.setAlignment(Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignLeft)
        v.addWidget(self.lbl_status)

        self.btn_go = QPushButton('Download')
        self.btn_go.setMinimumHeight(42)
        f = self.btn_go.font()
        f.setBold(True)
        f.setPointSizeF(f.pointSizeF() * 1.1)
        self.btn_go.setFont(f)
        self.btn_go.setStyleSheet(
            f"QPushButton {{ background: {ACCENT}; color: white; border: 1px solid {ACCENT_DARK}; border-radius: 4px; }}"
            f"QPushButton:hover {{ background: {ACCENT_DARK}; }}"
            "QPushButton:disabled { background: #9e9e9e; border-color: #8a8a8a; }")
        self.btn_go.clicked.connect(self.start)
        v.addWidget(self.btn_go)
        v.addSpacing(6)

        row = QHBoxLayout()
        for text, fn in (('Open output folder', lambda: open_folder(self.s['OutputDir'])),
                         ('Open Stems folder', lambda: open_folder(self.s['StemsDir'])),
                         ('Open logs', lambda: open_folder(str(paths.log_dir())))):
            b = QPushButton(text)
            b.clicked.connect(fn)
            row.addWidget(b)
        v.addLayout(row)
        v.addStretch()
        return w

    # ------------------------------------------------------- Settings tab -----
    def build_settings_tab(self) -> QWidget:
        w = QWidget()
        v = QVBoxLayout(w)
        v.setContentsMargins(20, 16, 20, 16)
        grid = QGridLayout()
        grid.setColumnStretch(1, 1)

        self.cmb_format = QComboBox()
        self.cmb_format.addItems(settings.FORMAT_CHOICES)
        self.cmb_format.setCurrentText(self.s['Format'])
        self.cmb_format.currentTextChanged.connect(lambda t: self.set_and_save('Format', t))
        grid.addWidget(QLabel('Output format:'), 0, 0)
        grid.addWidget(self.cmb_format, 0, 1, Qt.AlignmentFlag.AlignLeft)
        grid.addWidget(small(QLabel(
            'Applies to all modes. Karaoke/Drumless/Custom are separated as WAV first, then converted, '
            'so non-WAV formats take a little longer. ("best" = keep whatever YouTube serves; separated '
            'mixes stay WAV.)')), 1, 0, 1, 2)

        self.cmb_rate = QComboBox()
        self.cmb_rate.addItems(list(settings.RATE_DISPLAY))
        self.cmb_rate.setCurrentText(next((k for k, val in settings.RATE_DISPLAY.items()
                                           if val == self.s['SampleRate']), ''))
        self.cmb_rate.currentTextChanged.connect(
            lambda t: self.set_and_save('SampleRate', settings.RATE_DISPLAY[t]))
        grid.addWidget(QLabel('Sample rate:'), 2, 0)
        grid.addWidget(self.cmb_rate, 2, 1, Qt.AlignmentFlag.AlignLeft)

        self.cmb_model = QComboBox()
        self.cmb_model.addItems(list(settings.MODEL_DISPLAY))
        self.cmb_model.setCurrentText(next((k for k, val in settings.MODEL_DISPLAY.items()
                                            if val == self.s['Model']), ''))
        self.cmb_model.currentTextChanged.connect(self.on_model_changed)
        grid.addWidget(QLabel('Separation model:'), 3, 0)
        grid.addWidget(self.cmb_model, 3, 1)
        grid.addWidget(small(QLabel(
            'htdemucs_6s adds guitar and piano stems for Custom mix; the first run with it downloads '
            'an extra ~350 MB model.')), 4, 0, 1, 2)
        v.addLayout(grid)
        v.addSpacing(8)

        self.txt_out = self.folder_row(v, 'Output folder (final tracks):', 'OutputDir',
                                       'Choose where finished tracks are saved')
        self.txt_stems = self.folder_row(v, 'Stems folder (raw separation output):', 'StemsDir',
                                         'Choose where raw separation stems are saved')
        v.addSpacing(8)

        v.addWidget(QLabel('Also export practice-speed copies (slower, same pitch):'))
        row = QHBoxLayout()
        self.speed_checks = {}
        for sp in settings.SPEED_CHOICES:
            cb = QCheckBox(f"{sp}%")
            cb.setChecked(sp in self.s['PracticeSpeeds'])
            cb.toggled.connect(lambda _=False: self.set_and_save(
                'PracticeSpeeds', [x for x in settings.SPEED_CHOICES if self.speed_checks[x].isChecked()]))
            row.addWidget(cb)
            self.speed_checks[sp] = cb
        row.addStretch()
        v.addLayout(row)

        self.chk_click = QCheckBox('Also export a click track at the detected BPM')
        self.chk_click.setChecked(bool(self.s['ClickTrack']))
        self.chk_click.toggled.connect(lambda on: self.set_and_save('ClickTrack', on))
        v.addWidget(self.chk_click)

        self.lbl_saved = QLabel('')
        self.lbl_saved.setStyleSheet(f"color: {ACCENT};")
        v.addWidget(self.lbl_saved)
        v.addStretch()
        return w

    def folder_row(self, layout, label, key, caption) -> QLineEdit:
        layout.addWidget(QLabel(label))
        row = QHBoxLayout()
        txt = QLineEdit(self.s[key])
        txt.setReadOnly(True)
        txt.setCursorPosition(0)   # show the start of long paths, not the end
        row.addWidget(txt)
        btn = QPushButton('Browse...')

        def browse():
            start = self.s[key] if os.path.isdir(self.s[key]) else str(Path.home())
            d = QFileDialog.getExistingDirectory(self, caption, start)
            if d:
                txt.setText(d)
                txt.setCursorPosition(0)
                self.set_and_save(key, d)

        btn.clicked.connect(browse)
        row.addWidget(btn)
        layout.addLayout(row)
        return txt

    # ----------------------------------------------------------- settings -----
    def set_and_save(self, key, value) -> None:
        self.s[key] = value
        try:
            settings.save(self.s)
            self.lbl_saved.setText('Settings saved.')
        except OSError as e:
            self.lbl_saved.setText('Could not save settings (see logs).')
            write_log(self.log_file, f"Settings save failed: {e}")
        self.saved_timer.start()

    def on_model_changed(self, text) -> None:
        self.set_and_save('Model', settings.MODEL_DISPLAY[text])
        self.update_stem_checks()

    def on_custom_remove_changed(self) -> None:
        self.set_and_save('CustomRemove', [s for s in settings.ALL_STEMS if self.stem_checks[s].isChecked()])

    def update_stem_checks(self) -> None:
        avail = settings.MODEL_STEMS[self.s['Model']]
        for stem, cb in self.stem_checks.items():
            cb.setEnabled(self.r_custom.isChecked() and stem in avail)

    # ---------------------------------------------------------------- run -----
    def start(self) -> None:
        if self.pipeline:
            return
        url = self.txt_url.text().strip()
        if not url:
            QMessageBox.information(self, TITLE, 'Paste a YouTube URL first.')
            return

        mode, remove, suffix = 'audio', [], ''
        if self.r_karaoke.isChecked():
            mode, remove, suffix = 'mix', ['vocals'], 'Karaoke'
        elif self.r_drumless.isChecked():
            mode, remove, suffix = 'mix', ['drums'], 'Drumless'
        elif self.r_custom.isChecked():
            mode = 'mix'
            avail = settings.MODEL_STEMS[self.s['Model']]
            remove = [s for s in settings.ALL_STEMS if self.stem_checks[s].isChecked() and s in avail]
            if not remove:
                QMessageBox.information(self, TITLE, 'Pick at least one stem to remove for a custom mix.')
                return
            if len(remove) >= len(avail):
                QMessageBox.information(self, TITLE, "You can't remove every stem - nothing would be left in the mix.")
                return
            suffix = ', '.join('No ' + s.capitalize() for s in remove)

        missing = missing_tools(mode)
        if missing:
            QMessageBox.critical(self, TITLE, 'Missing required tools: ' + ', '.join(missing) +
                                 '\n\nRun the setup script again (see the README).')
            return
        try:
            Path(self.s['OutputDir']).mkdir(parents=True, exist_ok=True)
        except OSError:
            QMessageBox.critical(self, TITLE, f"Can't create the output folder:\n{self.s['OutputDir']}"
                                              "\n\nPick a different folder in Settings.")
            return

        job = Job(url=url, mode=mode, remove=remove, suffix=suffix,
                  downloads_dir=self.s['OutputDir'], stems_dir=self.s['StemsDir'],
                  format=self.s['Format'], sample_rate=self.s['SampleRate'], model=self.s['Model'],
                  practice_speeds=list(self.s['PracticeSpeeds']), click_track=bool(self.s['ClickTrack']))
        self.log_file = open_log()   # the app may stay open past midnight
        self.pipeline = Pipeline(job, self.log_file, self.bridge.status.emit, self.bridge.progress.emit)
        self.btn_go.setEnabled(False)
        self.btn_go.setText('Working...')
        self.lbl_status.setText('Starting...')
        threading.Thread(target=self.worker, args=(self.pipeline,), daemon=True).start()

    def worker(self, pipeline) -> None:
        try:
            self.bridge.finished.emit(pipeline.run(), '')
        except Cancelled:
            self.bridge.finished.emit(None, 'Cancelled.')
        except PipelineError as e:
            self.bridge.finished.emit(None, str(e))
        except Exception as e:  # noqa: BLE001 - surface anything unexpected to the user
            write_log(self.log_file, f"ERROR (unexpected): {e!r}")
            self.bridge.finished.emit(None, 'Processing stopped unexpectedly.')

    def on_status(self, text) -> None:
        self.lbl_status.setText(text)

    def on_progress(self, mode, value) -> None:
        if mode == 'marquee':
            self.bar.setRange(0, 0)   # Qt's indeterminate ("busy") bar
        else:
            self.bar.setRange(0, 100)
            self.bar.setValue(max(0, min(100, value)))

    def on_finished(self, result, error) -> None:
        self.pipeline = None
        self.btn_go.setEnabled(True)
        self.btn_go.setText('Download')
        self.bar.setRange(0, 100)
        self.bar.setValue(0)
        if result:
            self.lbl_status.setText('Ready.')
            extra = ''
            if result.bpm > 0:
                key_part = f", {result.key}" if result.key else ''
                extra = f"\n\nDetected: {round(result.bpm)} BPM{key_part} (from source audio)"
            QMessageBox.information(self, TITLE, f"Finished!\n\nSaved to:\n{result.out_file}{extra}")
            if os.path.exists(result.out_file):
                reveal(result.out_file)
            else:
                open_folder(self.s['OutputDir'])
        elif error != 'Cancelled.':
            self.lbl_status.setText(f"Error: {error}")
            QMessageBox.critical(self, TITLE, f"Error: {error}\n\nDetails: use the 'Open logs' button.")

    def closeEvent(self, e) -> None:
        if self.pipeline:
            ans = QMessageBox.warning(self, TITLE, 'A download/separation is still running. Close anyway?',
                                      QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No)
            if ans != QMessageBox.StandardButton.Yes:
                e.ignore()
                return
            self.pipeline.cancel()
        e.accept()

    # ------------------------------------------------------- update check -----
    def check_for_update(self) -> None:
        try:
            req = urllib.request.Request(f"https://api.github.com/repos/{REPO_SLUG}/releases/latest",
                                         headers={'User-Agent': 'DrumTrackStudio'})
            with urllib.request.urlopen(req, timeout=5) as r:
                latest = json.load(r)['tag_name'].lstrip('v')
            if _version_tuple(latest) > _version_tuple(__version__):
                self.bridge.update_available.emit(latest)
        except Exception:  # noqa: BLE001 - offline / rate-limited: stay quiet
            pass

    def on_update_available(self, latest) -> None:
        self.lbl_update.setText(f'<a href="https://github.com/{REPO_SLUG}/releases/latest" '
                                f'style="color:{ACCENT}">Update available: v{latest}</a>')


def _version_tuple(v: str):
    return tuple(int(x) for x in v.split('.') if x.isdigit())


def main() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName(TITLE)
    # Link the window to setup.sh's app-menu entry (taskbar icon on Wayland). Only
    # when that entry exists: otherwise the desktop portal logs a warning.
    if paths.desktop_entry_installed():
        app.setDesktopFileName('drumtrackstudio')
    win = MainWindow()
    win.show()
    return app.exec()
