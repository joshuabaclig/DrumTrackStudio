"""Per-OS locations for settings, logs, output folders and bundled tools.

Windows paths match the PowerShell app exactly, so both versions share one
settings.json while the PowerShell app is still around.
"""
import os
import shutil
import sys
from pathlib import Path

APP_NAME = 'DrumTrackStudio'
IS_WINDOWS = sys.platform == 'win32'
IS_MAC = sys.platform == 'darwin'

ROOT = Path(__file__).resolve().parent.parent
BIN_DIR = ROOT / 'bin'
FEAT_SCRIPT = ROOT / 'tools' / 'detect_features.py'


def config_dir() -> Path:
    if IS_WINDOWS:
        return Path(os.environ['APPDATA']) / APP_NAME
    if IS_MAC:
        return Path.home() / 'Library' / 'Application Support' / APP_NAME
    return Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / APP_NAME


def log_dir() -> Path:
    if IS_WINDOWS:
        return Path(os.environ['LOCALAPPDATA']) / APP_NAME / 'logs'
    if IS_MAC:
        return Path.home() / 'Library' / 'Logs' / APP_NAME
    return Path(os.environ.get('XDG_STATE_HOME') or Path.home() / '.local' / 'state') / APP_NAME / 'logs'


def documents_dir() -> Path:
    # Qt knows the real Documents folder on every OS (OneDrive redirection on
    # Windows, XDG user-dirs on Linux); fall back to ~/Documents without Qt.
    try:
        from PySide6.QtCore import QStandardPaths
        loc = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.DocumentsLocation)
        if loc:
            return Path(loc)
    except ImportError:
        pass
    return Path.home() / 'Documents'


def output_base() -> Path:
    return documents_dir() / APP_NAME


def desktop_entry_installed() -> bool:
    """True if setup.sh installed the Linux app-menu entry."""
    if IS_WINDOWS or IS_MAC:
        return False
    data_home = Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local' / 'share')
    return (data_home / 'applications' / 'drumtrackstudio.desktop').is_file()


def find_tool(name: str):
    """A tool from the repo's bin/ folder if present, else from PATH. None if missing."""
    exe = name + '.exe' if IS_WINDOWS else name
    local = BIN_DIR / exe
    if local.is_file():
        return str(local)
    return shutil.which(name)
