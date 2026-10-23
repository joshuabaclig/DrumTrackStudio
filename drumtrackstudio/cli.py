"""Command-line front end: same pipeline and saved settings as the GUI."""
import argparse
import sys

from . import __version__, settings
from .pipeline import Cancelled, Job, Pipeline, PipelineError, missing_tools, open_log

PRESETS = {'audio': ('audio', [], ''), 'karaoke': ('mix', ['vocals'], 'Karaoke'),
           'drumless': ('mix', ['drums'], 'Drumless')}


def main() -> int:
    s = settings.load()
    ap = argparse.ArgumentParser(prog='drumtrackstudio',
                                 description='Download a YouTube track and optionally remove stems. '
                                             'Unset options use the GUI\'s saved settings.')
    ap.add_argument('url')
    ap.add_argument('--mode', choices=list(PRESETS) + ['custom'], default='audio')
    ap.add_argument('--remove', nargs='+', choices=settings.ALL_STEMS, metavar='STEM',
                    help='stems to remove with --mode custom (vocals drums bass other guitar piano)')
    ap.add_argument('--format', choices=settings.FORMAT_CHOICES, default=s['Format'])
    ap.add_argument('--model', choices=list(settings.MODEL_STEMS), default=s['Model'])
    ap.add_argument('--version', action='version', version=__version__)
    a = ap.parse_args()

    if a.mode == 'custom':
        avail = settings.MODEL_STEMS[a.model]
        remove = [x for x in (a.remove or []) if x in avail]
        if not remove or len(remove) >= len(avail):
            ap.error(f"--mode custom needs --remove with 1 to {len(avail) - 1} of: {' '.join(avail)}")
        mode, suffix = 'mix', ', '.join('No ' + x.capitalize() for x in remove)
    else:
        mode, remove, suffix = PRESETS[a.mode]

    missing = missing_tools(mode)
    if missing:
        print('Missing required tools: ' + ', '.join(missing) + ' - run the setup script.', file=sys.stderr)
        return 1

    job = Job(url=a.url, mode=mode, remove=remove, suffix=suffix,
              downloads_dir=s['OutputDir'], stems_dir=s['StemsDir'], format=a.format,
              sample_rate=s['SampleRate'], model=a.model,
              practice_speeds=list(s['PracticeSpeeds']), click_track=bool(s['ClickTrack']))
    log_file = open_log()
    last = {'pct': -1}

    def on_progress(kind, value):
        if kind == 'percent' and value // 10 != last['pct'] // 10:
            last['pct'] = value
            print(f"  {value}%", flush=True)

    p = Pipeline(job, log_file, on_status=lambda t: print(t, flush=True), on_progress=on_progress)
    try:
        r = p.run()
    except KeyboardInterrupt:
        p.cancel()
        print('Cancelled.', file=sys.stderr)
        return 130
    except Cancelled:
        return 130
    except PipelineError as e:
        print(f"Error: {e}\nLog: {log_file}", file=sys.stderr)
        return 1
    print(f"\nSaved to: {r.out_file}")
    if r.bpm > 0:
        print(f"Detected: {round(r.bpm)} BPM" + (f", {r.key}" if r.key else ''))
    return 0
