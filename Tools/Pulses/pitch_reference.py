"""Separate external F0 provenance; injected and original pulse outputs must agree."""
import math
import os
from pathlib import Path
import subprocess
import tempfile

from reference import (ROOT, HERE, MAX_FRAMES, MAX_POINTS, MAX_OUTPUT_BYTES, digest,
                       integer, scalar, number, canonical, pcm_wave, load_json,
                       verify_tool, validate_pitch)

PROFILE = {'hopSeconds': .005, 'floorHz': 75., 'ceilingHz': 700., 'maximumCandidates': 15,
           'veryAccurate': True, 'silenceThreshold': .03, 'voicingThreshold': .45,
           'octaveCost': .01, 'octaveJumpCost': .35, 'voicedUnvoicedCost': .14}


def parse(raw, rate, count):
    if not isinstance(raw, str) or len(raw.encode()) > MAX_OUTPUT_BYTES:
        raise ValueError('F0 reference exceeds byte budget')
    rows = [line.split('\t') for line in raw.splitlines()]
    if len(rows) < 6 or rows[0] != ['begin', 'pulse-f0-reference-v1'] or rows[-1] != ['end', 'pulse-f0-reference-v1']:
        raise ValueError('F0 reference boundaries missing')
    if rows[1] != ['input', str(rate), str(count)]:
        raise ValueError('F0 reference input differs')
    expected = [1 if v is True else v for v in PROFILE.values()]
    if rows[2][0] != 'settings' or list(map(scalar, rows[2][1:])) != expected:
        raise ValueError('F0 reference recipe differs')
    axis = rows[3]
    if len(axis) != 6 or axis[0] != 'pitch':
        raise ValueError('Missing F0 axis')
    frames = integer(axis[1])
    if not 1 <= frames <= MAX_FRAMES or len(rows) < frames + 6:
        raise ValueError('Invalid F0 coverage')
    first, step, start, end = map(scalar, axis[2:])
    if step != PROFILE['hopSeconds'] or start != 0 or end != count * (1 / rate):
        raise ValueError('F0 domain/step differs')
    values = []
    for i, row in enumerate(rows[4:4 + frames]):
        if len(row) != 4 or row[:2] != ['f0', str(i + 1)] or scalar(row[2]) != math.fma(float(i), step, first):
            raise ValueError('F0 frame coverage/timestamp differs')
        value = number(row[3])
        if value is not None and value <= 0:
            raise ValueError('Invalid voiced F0')
        values.append(0. if value is None else value)
    pitch = dict(domainEndSeconds=end, firstCenterSeconds=first, stepSeconds=step,
                 ceilingHz=PROFILE['ceilingHz'], frequenciesHz=values)
    validate_pitch(pitch, rate, count)
    row = rows[frames + 4]
    if len(row) != 2 or row[0] != 'count':
        raise ValueError('Missing direct pulse count')
    points = integer(row[1])
    if points > MAX_POINTS or len(rows) != frames + points + 6:
        raise ValueError('Direct pulse coverage differs')
    times = []
    for i, row in enumerate(rows[frames + 5:-1], 1):
        if len(row) != 3 or row[:2] != ['pulse', str(i)]:
            raise ValueError('Direct pulse indices differ')
        value = scalar(row[2])
        if not -.1 <= value <= end + .1 or (times and value <= times[-1]):
            raise ValueError('Invalid direct pulse location')
        times.append(value)
    return pitch, times


def make_record(wave, raw, rate, count):
    pitch, direct = parse(raw, rate, count)
    lock = load_json(ROOT / 'Tools/Reference/toolchain.json')
    identity = {'schemaVersion': 1, 'kind': 'praat7002RawCCF0', 'profile': PROFILE,
                'toolchain': lock, 'inputSHA256': digest(wave), 'rawSHA256': digest(raw.encode()),
                'sourceSHA256': {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in
                                 (Path(__file__), HERE / 'pitch.praat', HERE / 'reference.py',
                                  ROOT / 'Tools/Reference/common.py', ROOT / 'Tools/Reference/setup.py')}}
    return {'referenceIdentity': digest(canonical(identity)), **identity,
            'pitch': pitch, 'directPulseTimesSeconds': direct}


def evaluate(samples, rate):
    wave = pcm_wave(samples, rate)
    # Validate the developer resource limit before starting the external process.
    validate_pitch(dict(domainEndSeconds=len(samples) * (1 / rate),
                        firstCenterSeconds=.5 / rate, stepSeconds=1 / rate,
                        ceilingHz=PROFILE['ceilingHz'], frequenciesHz=[0.]), rate, len(samples))
    lock = load_json(ROOT / 'Tools/Reference/toolchain.json')
    binary = verify_tool(ROOT / '.build/reference-tool' / lock['version'] / lock['executablePath'], lock)
    with tempfile.TemporaryDirectory(prefix='pulse-f0-reference-', dir=ROOT / '.build') as temporary:
        path = Path(temporary) / 'input.wav'
        path.write_bytes(wave)
        process = subprocess.run([str(binary), *lock['options'], str(HERE / 'pitch.praat'), str(path)],
                                 capture_output=True, text=True, encoding='utf-8', timeout=120,
                                 env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    if process.returncode or process.stderr.strip():
        raise ValueError(f'Reference F0 failed ({process.returncode}): {process.stderr[:1200]}')
    return make_record(wave, process.stdout, rate, len(samples)), process.stdout
