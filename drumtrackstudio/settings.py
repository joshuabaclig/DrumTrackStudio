"""settings.json load/save - same keys and validation as the PowerShell app."""
import json

from . import paths

FORMAT_CHOICES = ['best', 'aac', 'alac', 'flac', 'm4a', 'mp3', 'opus', 'vorbis', 'wav']
RATE_DISPLAY = {
    '44100 (CD quality, default)': '44100',
    '48000': '48000',
    '22050': '22050',
    'Keep source (no resampling)': 'source',
}
MODEL_DISPLAY = {
    'htdemucs (4 stems - vocals/drums/bass/other)': 'htdemucs',
    'htdemucs_6s (6 stems - adds guitar/piano; ~350 MB on first use)': 'htdemucs_6s',
}
MODEL_STEMS = {
    'htdemucs': ['vocals', 'drums', 'bass', 'other'],
    'htdemucs_6s': ['vocals', 'drums', 'bass', 'other', 'guitar', 'piano'],
}
ALL_STEMS = ['vocals', 'drums', 'bass', 'other', 'guitar', 'piano']
SPEED_CHOICES = ['90', '75', '60', '50']

SETTINGS_FILE = paths.config_dir() / 'settings.json'


def defaults() -> dict:
    base = paths.output_base()
    return {'Format': 'wav', 'SampleRate': '44100',
            'OutputDir': str(base / 'Downloads'), 'StemsDir': str(base / 'Stems'),
            'Model': 'htdemucs', 'PracticeSpeeds': [], 'ClickTrack': False,
            'CustomRemove': ['vocals']}


def load() -> dict:
    s = defaults()
    try:
        if not SETTINGS_FILE.exists():
            return s
        # utf-8-sig: Windows PowerShell 5.1 writes UTF-8 with a BOM
        j = json.loads(SETTINGS_FILE.read_text(encoding='utf-8-sig'))
        if str(j.get('Format')) in FORMAT_CHOICES:
            s['Format'] = str(j['Format'])
        if str(j.get('SampleRate')) in RATE_DISPLAY.values():
            s['SampleRate'] = str(j['SampleRate'])
        for k in ('OutputDir', 'StemsDir'):
            if isinstance(j.get(k), str) and j[k].strip():
                s[k] = j[k]
        if j.get('Model') in MODEL_STEMS:
            s['Model'] = j['Model']
        if j.get('PracticeSpeeds') is not None:
            s['PracticeSpeeds'] = [str(x) for x in _as_list(j['PracticeSpeeds']) if str(x) in SPEED_CHOICES]
        if j.get('ClickTrack') is not None:
            s['ClickTrack'] = bool(j['ClickTrack'])
        if j.get('CustomRemove') is not None:
            cr = [str(x) for x in _as_list(j['CustomRemove']) if str(x) in ALL_STEMS]
            if cr:
                s['CustomRemove'] = cr
    except (OSError, ValueError, AttributeError):
        s = defaults()   # corrupted file -> defaults, never fatal
    return s


def save(s: dict) -> None:
    SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS_FILE.write_text(json.dumps(s, indent=4), encoding='utf-8')


def _as_list(v):
    # PowerShell's ConvertTo-Json writes a one-element array as a bare value
    return v if isinstance(v, list) else [v]
