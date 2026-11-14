"""Pure edit logic: time parsing/formatting, EditSpec validation, the ffmpeg filter
string, and the worker<->editor hand-off."""
import re
import threading
import time

import pytest

from drumtrackstudio.edit import (
    FADE, MAX_LEAD_IN, EditError, EditRequest, EditSpec, build_edit_filter, format_time, parse_time,
)


@pytest.mark.parametrize('text, expected', [
    ('0', 0.0), ('83.5', 83.5), ('1:23.5', 83.5), ('1:23,5', 83.5), ('01:02', 62.0),
    ('0:01:23.500', 83.5), ('1:00:00', 3600.0), ('.5', 0.5), (' 2:03.25 ', 123.25), (12, 12.0),
])
def test_parse_time(text, expected):
    assert parse_time(text) == pytest.approx(expected)


@pytest.mark.parametrize('text', ['', 'abc', '1:2:3:4', '-5', '1:75', '1::2', '1.2.3'])
def test_parse_time_rejects(text):
    with pytest.raises(EditError):
        parse_time(text)


@pytest.mark.parametrize('seconds, text', [
    (0, '0:00.000'), (83.5, '1:23.500'), (59.9996, '1:00.000'), (3725.25, '1:02:05.250'), (-3, '0:00.000'),
])
def test_format_time(seconds, text):
    assert format_time(seconds) == text


def test_format_parse_round_trip():
    for v in (0.0, 0.001, 9.999, 61.25, 599.5, 3599.999, 3600.001):
        assert parse_time(format_time(v)) == pytest.approx(v, abs=0.0005)


def test_spec_resolves_end_and_validates():
    r = EditSpec(1.0, None, 2.0).resolved(10.0)
    assert (r.start, r.end, r.lead_in) == (1.0, 10.0, 2.0)
    assert EditSpec(0, 10.0005).resolved(10.0).end == 10.0   # ffprobe rounding slack
    for bad in (EditSpec(-1), EditSpec(5, 5.05), EditSpec(6, 5), EditSpec(0, 11),
                EditSpec(0, None, -1), EditSpec(0, None, MAX_LEAD_IN + 0.1)):
        with pytest.raises(EditError):
            bad.resolved(10.0)


def test_spec_noop_and_length():
    assert EditSpec().is_noop(10)
    assert EditSpec(0, 10, 0).is_noop(10)
    assert not EditSpec(0.01).is_noop(10)
    assert not EditSpec(lead_in=0.5).is_noop(10)
    assert EditSpec(2, 8, 4).result_length(10) == pytest.approx(10.0)


def test_filter_full_edit():
    f = build_edit_filter(EditSpec(1.5, 4.5, 2.0), 6.0)
    assert f == ('atrim=start=1.500000:end=4.500000,asetpts=PTS-STARTPTS,'
                 f'afade=t=in:st=0:d={FADE:.3f},'
                 f'afade=t=out:st={3.0 - FADE:.6f}:d={FADE:.3f},'
                 'adelay=delays=2000:all=1')


def test_filter_only_fades_real_cuts():
    f = build_edit_filter(EditSpec(0, None, 3.25), 6.0)   # lead-in only: no cuts, no fades
    assert 'afade' not in f and f.endswith('adelay=delays=3250:all=1')
    f = build_edit_filter(EditSpec(2.0, None, 0), 6.0)    # start cut only
    assert 'afade=t=in' in f and 'afade=t=out' not in f and 'adelay' not in f


def test_filter_is_locale_proof():
    import locale
    old = locale.setlocale(locale.LC_NUMERIC)
    try:
        for name in ('de_DE.UTF-8', 'de_DE', 'German_Germany.1252'):
            try:
                locale.setlocale(locale.LC_NUMERIC, name)
                break
            except locale.Error:
                continue
        # filters are comma-separated, but a number must never contain a comma
        assert not re.search(r'\d,\d', build_edit_filter(EditSpec(1.25, 3.5, 1.5), 6.0))
    finally:
        locale.setlocale(locale.LC_NUMERIC, old)


def test_request_respond_from_other_thread():
    req = EditRequest('x.wav', 10.0, 'x')
    cancelled = threading.Event()
    spec = EditSpec(1, None, 2)
    threading.Timer(0.05, lambda: req.respond(EditRequest.APPLY, spec)).start()
    assert req.wait(cancelled) == (EditRequest.APPLY, spec)
    req.respond(EditRequest.SKIP)     # second answer is ignored
    assert req.wait(cancelled) == (EditRequest.APPLY, spec)


def test_request_wait_returns_on_cancel():
    req = EditRequest('x.wav', 10.0, 'x')
    cancelled = threading.Event()
    threading.Timer(0.05, cancelled.set).start()
    t0 = time.monotonic()
    assert req.wait(cancelled, poll=0.02) == (EditRequest.CANCEL, None)
    assert time.monotonic() - t0 < 2


def test_request_rejects_bad_answers():
    req = EditRequest('x.wav', 10.0, 'x')
    with pytest.raises(ValueError):
        req.respond('maybe')
    with pytest.raises(ValueError):
        req.respond(EditRequest.APPLY)   # apply needs a spec
