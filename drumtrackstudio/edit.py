"""Trim + lead-in edits: the data model, time parsing/formatting, the ffmpeg filter
that applies an edit, and the hand-off between the pipeline's worker thread and
whoever answers an edit request (the GUI's trim editor, or a test).

No Qt dependency - shared by pipeline.py, cli.py, editor.py and the tests.
"""
import re
import threading
from dataclasses import dataclass
from typing import Optional

MAX_LEAD_IN = 30.0   # seconds of silence that can be added before the song
FADE = 0.015         # seconds; a short fade at each cut point prevents an audible click


class EditError(ValueError):
    pass


@dataclass
class EditSpec:
    """Keep [start, end) of the source, then put lead_in seconds of silence before it.
    end=None means "to the end of the track"."""
    start: float = 0.0
    end: Optional[float] = None
    lead_in: float = 0.0

    def resolved(self, duration: float) -> 'EditSpec':
        """A copy with end filled in and everything validated against the source
        length. Raises EditError with a user-readable message."""
        end = duration if self.end is None else float(self.end)
        start = float(self.start)
        lead_in = float(self.lead_in)
        if start < 0:
            raise EditError('The start point can\'t be before the beginning of the track.')
        if end > duration + 0.001:
            raise EditError(f"The end point ({format_time(end)}) is past the end of the track "
                            f"({format_time(duration)}).")
        end = min(end, duration)
        if end - start < 0.1:
            raise EditError('The start point must be before the end point (keep at least 0.1 s).')
        if not 0 <= lead_in <= MAX_LEAD_IN:
            raise EditError(f"The lead-in gap must be between 0 and {MAX_LEAD_IN:g} seconds.")
        return EditSpec(start, end, lead_in)

    def is_noop(self, duration: float) -> bool:
        r = self.resolved(duration)
        return r.start < 0.0005 and r.end > duration - 0.0005 and r.lead_in < 0.0005

    def result_length(self, duration: float) -> float:
        r = self.resolved(duration)
        return r.lead_in + (r.end - r.start)


def build_edit_filter(spec: EditSpec, duration: float) -> str:
    """The ffmpeg -af chain for an edit. atrim cuts at exact sample positions; the
    fades only go where audio was actually cut; adelay inserts the lead-in silence.
    Numbers are formatted with '.', never the OS locale's decimal separator."""
    r = spec.resolved(duration)
    kept = r.end - r.start
    parts = [f"atrim=start={r.start:.6f}:end={r.end:.6f}", 'asetpts=PTS-STARTPTS']
    if r.start > 0.0005:
        parts.append(f"afade=t=in:st=0:d={FADE:.3f}")
    if r.end < duration - 0.0005:
        parts.append(f"afade=t=out:st={max(0.0, kept - FADE):.6f}:d={FADE:.3f}")
    lead_ms = int(round(r.lead_in * 1000))
    if lead_ms > 0:
        parts.append(f"adelay=delays={lead_ms}:all=1")
    return ','.join(parts)


# ------------------------------------------------------------- time text -----
_TIME_RE = re.compile(r'^\s*(?:(\d+):)?(?:(\d+):)?(\d+(?:[.,]\d*)?|[.,]\d+)\s*$')


def parse_time(text) -> float:
    """'83.5', '1:23.5', '1:23,5' or '0:01:23.500' -> seconds. Raises EditError."""
    if isinstance(text, (int, float)):
        return float(text)
    m = _TIME_RE.match(str(text))
    if not m:
        raise EditError(f"'{text}' isn't a time - use seconds (83.5) or minutes:seconds (1:23.5).")
    a, b, sec = m.groups()
    sec = float(sec.replace(',', '.'))
    if b is not None:            # h:m:s
        hours, minutes = int(a), int(b)
    else:
        hours, minutes = 0, int(a) if a is not None else 0
    if (a is not None) and sec >= 60:
        raise EditError(f"'{text}': seconds must be under 60 when minutes are given.")
    return hours * 3600 + minutes * 60 + sec


def format_time(seconds: float, decimals: int = 3) -> str:
    """seconds -> 'm:ss.mmm' (or 'h:mm:ss.mmm' past an hour)."""
    seconds = max(0.0, float(seconds))
    scale = 10 ** decimals
    total = int(round(seconds * scale))
    whole, frac = divmod(total, scale)
    h, rem = divmod(whole, 3600)
    m, s = divmod(rem, 60)
    tail = f".{frac:0{decimals}d}" if decimals > 0 else ''
    if h:
        return f"{h}:{m:02d}:{s:02d}{tail}"
    return f"{m}:{s:02d}{tail}"


# ------------------------------------------------- worker <-> editor hand-off -----
class EditRequest:
    """Created by the pipeline (worker thread) after the download; answered by the
    editor (GUI thread) with respond(). The worker blocks in wait() until then, or
    until the pipeline is cancelled (e.g. the app is closed with the editor open)."""
    APPLY, SKIP, CANCEL = 'apply', 'skip', 'cancel'

    def __init__(self, source: str, duration: float, title: str):
        self.source = source
        self.duration = duration
        self.title = title
        self._event = threading.Event()
        self._choice = None
        self._spec = None

    def respond(self, choice: str, spec: Optional[EditSpec] = None) -> None:
        if choice not in (self.APPLY, self.SKIP, self.CANCEL):
            raise ValueError(choice)
        if choice == self.APPLY and spec is None:
            raise ValueError('apply needs an EditSpec')
        if self._event.is_set():
            return   # first answer wins
        self._choice, self._spec = choice, spec
        self._event.set()

    @property
    def answered(self) -> bool:
        return self._event.is_set()

    def wait(self, cancelled: threading.Event, poll: float = 0.1):
        """Block until answered. Returns (choice, spec); choice is CANCEL if the
        pipeline was cancelled while waiting."""
        while not self._event.wait(poll):
            if cancelled.is_set():
                return self.CANCEL, None
        return self._choice, self._spec
