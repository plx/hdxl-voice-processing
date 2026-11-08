#!/usr/bin/env python3
"""Original strict interchange for pinned Sound + injected Pitch pulse references.

This module does not locate pulses. The independent development executable does.
Candidates are not promoted automatically; raw outside-domain points remain visible.
"""
import hashlib
import math
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(1, str(ROOT / 'Tools/Reference'))
from common import canonical, load_json, number, pcm_wave
from setup import verify_tool

MAX_SAMPLES = 192000 * 5
MAX_FRAMES = 5000
MAX_POINTS = 30000
MAX_OUTPUT_BYTES = 4 * 1024 * 1024
PITCH_KEYS = {'domainEndSeconds', 'firstCenterSeconds', 'stepSeconds', 'ceilingHz', 'frequenciesHz'}
PERIOD_DEFAULTS = {'minimumSeconds': .0001, 'maximumSeconds': .02, 'maximumAdjacentFactor': 1.3}


def validate_period_settings(settings):
    if not isinstance(settings, dict) or set(settings) != set(PERIOD_DEFAULTS):
        raise ValueError('Unknown period settings')
    lo, hi, factor = (settings[key] for key in PERIOD_DEFAULTS)
    if not all(finite(x) for x in (lo, hi, factor)) or not 0 < lo < hi <= .1 or not 1 <= factor <= 10:
        raise ValueError('Invalid period bounds/factor')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate_pitch(pitch, rate, count):
    if type(rate) is not int or not 4000 <= rate <= 192000:
        raise ValueError('Unsupported pulse sample rate')
    if type(count) is not int or not 1 <= count <= min(MAX_SAMPLES, rate * 5):
        raise ValueError('Unsupported pulse sample count')
    if not isinstance(pitch, dict) or set(pitch) != PITCH_KEYS:
        raise ValueError('Unknown/incomplete sampled F0 fields')
    scalars = [pitch[key] for key in PITCH_KEYS - {'frequenciesHz'}]
    if not all(finite(x) and x > 0 for x in scalars):
        raise ValueError('Invalid sampled F0 axis')
    if pitch['domainEndSeconds'] != count * (1 / rate):
        raise ValueError('F0 and PCM domains differ')
    values = pitch['frequenciesHz']
    if not isinstance(values, list) or not 1 <= len(values) <= MAX_FRAMES:
        raise ValueError('Invalid sampled F0 frame count')
    if not 20 < pitch['ceilingHz'] <= rate / 4:
        raise ValueError('Unsupported F0 ceiling')
    if any(not finite(v) or (v != 0 and not 20 <= v < pitch['ceilingHz']) for v in values):
        raise ValueError('F0 must be zero/unvoiced or finite, positive and below the ceiling')
    first, step = pitch['firstCenterSeconds'], pitch['stepSeconds']
    last = math.fma(float(len(values) - 1), step, first)
    if first > pitch['domainEndSeconds'] or last > pitch['domainEndSeconds']:
        raise ValueError('Sampled F0 centers exceed the observed domain')
    # Interior-only contours are valid. Their uncovered edges must not acquire
    # fabricated F0 observations; the reference retains its explicit grid.


def encode_pitch(pitch, rate, count):
    validate_pitch(pitch, rate, count)
    # Praat's text reader requires leading-zero decimal notation, not '.5'.
    values = ['File type = "ooTextFile"', 'Object class = "Pitch 1"', '', '0',
              repr(pitch['domainEndSeconds']), str(len(pitch['frequenciesHz'])),
              repr(pitch['stepSeconds']), repr(pitch['firstCenterSeconds']),
              repr(pitch['ceilingHz']), '1']
    for value in pitch['frequenciesHz']:
        # There is exactly one selected candidate; no reference pitch estimator runs.
        values += ['1', '1', repr(float(value)), '0.9' if value else '0']
    return ('\n'.join(values) + '\n').encode()


def integer(token):
    if not re.fullmatch(r'0|[1-9][0-9]*', token):
        raise ValueError('Invalid pulse protocol integer')
    return int(token)


def scalar(token):
    value = number(token)
    if value is None:
        raise ValueError('Unexpected undefined pulse protocol scalar')
    return value


def parse(raw, pitch, rate, count, period_settings=None):
    validate_pitch(pitch, rate, count)
    period_settings = PERIOD_DEFAULTS if period_settings is None else period_settings
    validate_period_settings(period_settings)
    if not isinstance(raw, str) or len(raw.encode()) > MAX_OUTPUT_BYTES:
        raise ValueError('Pulse protocol exceeds byte budget')
    lines = [line.split('\t') for line in raw.splitlines()]
    if len(lines) < 7 or lines[0] != ['begin', 'pulse-reference-v2'] or lines[-1] != ['end', 'pulse-reference-v2']:
        raise ValueError('Missing pulse protocol boundaries')
    if lines[1] != ['input', str(rate), str(count)]:
        raise ValueError('Reference PCM identity differs')
    n = len(pitch['frequenciesHz'])
    settings = lines[2]
    if len(settings) != 4 or settings[0] != 'periodSettings' or list(map(scalar, settings[1:])) != [period_settings[k] for k in PERIOD_DEFAULTS]:
        raise ValueError('Reference period settings differ')
    axis = lines[3]
    if len(axis) != 6 or axis[0] != 'pitch' or integer(axis[1]) != n:
        raise ValueError('Reference F0 frame coverage differs')
    expected_axis = [pitch['firstCenterSeconds'], pitch['stepSeconds'], 0., pitch['domainEndSeconds']]
    if list(map(scalar, axis[2:])) != expected_axis:
        raise ValueError('Reference F0 axis differs')
    if len(lines) < n + 7:
        raise ValueError('Truncated F0 frame rows')
    for i, frequency in enumerate(pitch['frequenciesHz']):
        row = lines[i + 4]
        if len(row) != 4 or row[0] != 'f0' or integer(row[1]) != i + 1:
            raise ValueError('Missing/repeated/reordered F0 frame')
        if scalar(row[2]) != math.fma(float(i), pitch['stepSeconds'], pitch['firstCenterSeconds']):
            raise ValueError('Reference F0 timestamp differs')
        value = number(row[3])
        if value != (frequency if frequency else None):
            raise ValueError('Reference did not use the injected F0 contour')
    size = lines[n + 4]
    if len(size) != 2 or size[0] != 'count':
        raise ValueError('Missing pulse count')
    points = integer(size[1])
    if points > MAX_POINTS or len(lines) < n + points + 7:
        raise ValueError('Pulse coverage/count budget differs')
    times = []
    for i, row in enumerate(lines[n + 5:n + 5 + points], 1):
        if len(row) != 3 or row[0] != 'pulse' or integer(row[1]) != i:
            raise ValueError('Missing/repeated/reordered pulse')
        value = scalar(row[2])
        if times and value <= times[-1]:
            raise ValueError('Pulse locations must increase strictly')
        # Edge extrapolation is retained explicitly, never clamped to observed PCM.
        if not -0.1 <= value <= pitch['domainEndSeconds'] + 0.1:
            raise ValueError('Reference pulse exceeds bounded edge extension')
        times.append(value)
    header = lines[n + 5 + points]
    observed = sum(0 <= t <= pitch['domainEndSeconds'] for t in times)
    state = 'insufficientData' if observed < 3 else 'complete'
    if len(header) != 3 or header[:2] != ['amplitudes', state]:
        raise ValueError('Reference amplitude state differs')
    amplitudes = integer(header[2])
    if amplitudes > max(0, observed - 2) or len(lines) != n + points + amplitudes + 7:
        raise ValueError('Amplitude coverage/count differs')
    values = []
    positions = {t: i for i, t in enumerate(times)}
    interior = {i for i, t in enumerate(times) if 0 <= t <= pitch['domainEndSeconds']}
    if interior:
        interior -= {min(interior), max(interior)}
    for i, row in enumerate(lines[n + 6 + points:-1], 1):
        if len(row) != 4 or row[0] != 'amplitude' or integer(row[1]) != i:
            raise ValueError('Missing/repeated/reordered amplitude')
        time, value = scalar(row[2]), scalar(row[3])
        if time not in positions or positions[time] not in interior or value <= 0:
            raise ValueError('Invalid cycle-amplitude observation')
        if values and time <= values[-1]['timeSeconds']:
            raise ValueError('Amplitude positions must increase strictly')
        values.append({'pulseIndex': positions[time], 'timeSeconds': time, 'rmsAmplitude': value})
    return {'unit': 'seconds', 'pulseTimesSeconds': times, 'pulseCount': points,
            'outsideDomainIndices': [i for i, t in enumerate(times) if t < 0 or t >= pitch['domainEndSeconds']],
            'injectedF0Verified': True, 'amplitudeState': state, 'amplitudes': values,
            'amplitudeUnit': 'linearAmplitude', 'amplitudeDefinition': 'praat7002HannRMSPointTwoNeighborPeriods'}


def make_record(wave, encoded_pitch, raw, pitch, rate, count, precision, period_settings):
    """Bind the raw executable transcript without launching or estimating anything."""
    if precision not in ('float32', 'float64'):
        raise ValueError('Unsupported input precision')
    if encoded_pitch != encode_pitch(pitch, rate, count):
        raise ValueError('Pitch transport differs from the explicit contour')
    data = parse(raw, pitch, rate, count, period_settings)
    lock = load_json(ROOT / 'Tools/Reference/toolchain.json')
    ingredients = {'schemaVersion': 2, 'toolchain': lock, 'sampleRate': rate, 'sampleCount': count,
                  'inputPrecision': precision, 'pitch': pitch,
                  'periodSettings': period_settings,
                  'inputSHA256': digest(wave), 'pitchSHA256': digest(encoded_pitch),
                  'rawSHA256': digest(raw.encode()),
                  'sourceSHA256': {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in
                                   (Path(__file__).resolve(), HERE / 'probe.praat',
                                    ROOT / 'Tools/Reference/common.py', ROOT / 'Tools/Reference/setup.py')}}
    return {'referenceIdentity': digest(canonical(ingredients)), **ingredients, 'data': data}


def evaluate(samples, rate, pitch, *, precision='float64', period_settings=None):
    if precision not in ('float32', 'float64'):
        raise ValueError('Unsupported input precision')
    validate_pitch(pitch, rate, len(samples))
    period_settings = dict(PERIOD_DEFAULTS) if period_settings is None else dict(period_settings)
    validate_period_settings(period_settings)
    if any(not finite(s) or abs(s) > 1 for s in samples):
        raise ValueError('Expected finite normalized mono PCM')
    if precision == 'float32':
        samples = list(struct.unpack(f'<{len(samples)}f', struct.pack(f'<{len(samples)}f', *samples)))
    wave, encoded_pitch = pcm_wave(samples, rate), encode_pitch(pitch, rate, len(samples))
    lock = load_json(ROOT / 'Tools/Reference/toolchain.json')
    binary = verify_tool(ROOT / '.build/reference-tool' / lock['version'] / lock['executablePath'], lock)
    with tempfile.TemporaryDirectory(prefix='pulse-reference-', dir=ROOT / '.build') as temporary:
        scratch = Path(temporary)
        (scratch / 'input.wav').write_bytes(wave)
        (scratch / 'input.Pitch').write_bytes(encoded_pitch)
        command = [str(binary), *lock['options'], str(HERE / 'probe.praat'),
                   str(scratch / 'input.wav'), str(scratch / 'input.Pitch'),
                   *[str(period_settings[k]) for k in PERIOD_DEFAULTS]]
        process = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', timeout=120,
                                 env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    if process.returncode or process.stderr.strip():
        raise ValueError(f'Pulse reference failed ({process.returncode}): {process.stderr[:1200]}')
    record = make_record(wave, encoded_pitch, process.stdout, pitch, rate, len(samples), precision, period_settings)
    return record, wave, encoded_pitch, process.stdout
