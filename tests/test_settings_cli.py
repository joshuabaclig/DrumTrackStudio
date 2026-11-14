"""settings.json compatibility (including files written by the old Windows
PowerShell app) and the CLI's trim flags."""
import json

import pytest

from drumtrackstudio import cli, settings


def write(obj, bom=False):
    settings.SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(obj) if not isinstance(obj, str) else obj
    settings.SETTINGS_FILE.write_bytes((b'\xef\xbb\xbf' if bom else b'') + text.encode('utf-8'))


def test_defaults_include_trim_settings():
    s = settings.load()
    assert s['TrimEditor'] is True and s['LeadInSeconds'] == 0.0


def test_round_trip():
    s = settings.load()
    s.update(TrimEditor=False, LeadInSeconds=4.5, Format='flac', PracticeSpeeds=['75'])
    settings.save(s)
    assert settings.load() == s


def test_upgrade_from_powershell_app_file():
    """v1.3 Windows settings.json: UTF-8 BOM, no trim keys, one-element arrays
    written as bare values by ConvertTo-Json."""
    write({'Format': 'mp3', 'SampleRate': '48000', 'OutputDir': 'D:\\Music\\DTS', 'StemsDir': 'D:\\Stems',
           'Model': 'htdemucs_6s', 'PracticeSpeeds': '75', 'ClickTrack': True, 'CustomRemove': 'drums'}, bom=True)
    s = settings.load()
    assert s['Format'] == 'mp3' and s['SampleRate'] == '48000' and s['Model'] == 'htdemucs_6s'
    assert s['OutputDir'] == 'D:\\Music\\DTS' and s['PracticeSpeeds'] == ['75'] and s['CustomRemove'] == ['drums']
    assert s['TrimEditor'] is True and s['LeadInSeconds'] == 0.0


@pytest.mark.parametrize('value', [-1, 31, 'abc', None, True, float('nan'), [2]])
def test_bad_lead_in_falls_back(value):
    write({'LeadInSeconds': value, 'TrimEditor': 'yes'}) if value == value else \
        write('{"LeadInSeconds": NaN}')
    s = settings.load()
    assert s['LeadInSeconds'] == 0.0 and s['TrimEditor'] is True


def test_corrupt_file_gives_defaults():
    write('{not json')
    assert settings.load() == settings.defaults()


# ------------------------------------------------------------------- CLI -----
@pytest.fixture
def captured(monkeypatch):
    jobs = []

    class FakePipeline:
        def __init__(self, job, log_file, **kw):
            jobs.append(job)

        def run(self):
            from drumtrackstudio.pipeline import Result
            return Result('out.wav')

    monkeypatch.setattr(cli, 'Pipeline', FakePipeline)
    monkeypatch.setattr(cli, 'missing_tools', lambda mode: [])
    return jobs


def test_cli_trim_flags(captured, capsys):
    assert cli.main(['https://x', '--mode', 'drumless', '--trim-start', '0:12.5', '--trim-end', '3:30',
                     '--lead-in', '4']) == 0
    job = captured[0]
    assert job.mode == 'mix' and job.remove == ['drums']
    assert (job.edit_spec.start, job.edit_spec.end, job.edit_spec.lead_in) == (12.5, 210.0, 4.0)


def test_cli_without_trim_flags_has_no_edit(captured):
    assert cli.main(['https://x']) == 0
    assert captured[0].edit_spec is None


def test_cli_lead_in_only(captured):
    cli.main(['https://x', '--lead-in', '2.5'])
    assert (captured[0].edit_spec.start, captured[0].edit_spec.end, captured[0].edit_spec.lead_in) == (0.0, None, 2.5)


@pytest.mark.parametrize('args', [
    ['--trim-start', 'soon'], ['--lead-in', '45'], ['--trim-start', '10', '--trim-end', '5'], ['--lead-in', '-1'],
])
def test_cli_rejects_bad_times(captured, capsys, args):
    with pytest.raises(SystemExit) as e:
        cli.main(['https://x'] + args)
    assert e.value.code == 2
    assert not captured
