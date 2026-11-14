"""Command-line front end: same pipeline and saved settings as the GUI."""
import argparse
import sys

from . import __version__, settings
from .edit import MAX_LEAD_IN, EditError, EditSpec, parse_time
from .pipeline import Cancelled, Job, Pipeline, PipelineError, missing_tools, open_log

PRESETS = {'audio': ('audio', [], ''), 'karaoke': ('mix', ['vocals'], 'Karaoke'),
           'drumless': ('mix', ['drums'], 'Drumless')}


def _time_arg(text: str) -> float:
    try:
        v = parse_time(text)
    except EditError as e:
        raise argparse.ArgumentTypeError(str(e)) from e
    if v < 0:
        raise argparse.ArgumentTypeError('times must not be negative')
    return v


def main(argv=None) -> int:
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
    ed = ap.add_argument_group('trim / lead-in (times as seconds, e.g. 12.5, or minutes:seconds, e.g. 1:02.5)')
    ed.add_argument('--trim-start', type=_time_arg, metavar='TIME',
                    help='cut everything before this point (e.g. a sampled intro)')
    ed.add_argument('--trim-end', type=_time_arg, metavar='TIME',
                    help='cut everything after this point')
    ed.add_argument('--lead-in', type=_time_arg, metavar='SECONDS',
                    help=f"add this much silence before the track (0-{MAX_LEAD_IN:g} s) to get ready")
    ap.add_argument('--version', action='version', version=__version__)
    a = ap.parse_args(argv)

    edit_spec = None
    if a.trim_start is not None or a.trim_end is not None or a.lead_in is not None:
        edit_spec = EditSpec(start=a.trim_start or 0.0, end=a.trim_end, lead_in=a.lead_in or 0.0)
        if edit_spec.lead_in > MAX_LEAD_IN:
            ap.error(f"--lead-in must be between 0 and {MAX_LEAD_IN:g} seconds")
        if edit_spec.end is not None and edit_spec.end - edit_spec.start < 0.1:
            ap.error('--trim-end must be after --trim-start')

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
              practice_speeds=list(s['PracticeSpeeds']), click_track=bool(s['ClickTrack']),
              edit_spec=edit_spec)
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
