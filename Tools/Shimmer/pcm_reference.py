"""Strict separate PCM extraction and shimmer-query transcript for pinned Praat."""
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile

import pcm_catalog
import shimmer_oracle
from shimmer_reference import ROOT, HERE, canonical, digest, load_json, verify_tool

SETTING_KEYS = ('queryStartSeconds', 'queryEndSeconds', 'minimumPeriodSeconds',
                'maximumPeriodSeconds', 'maximumAdjacentPeriodFactor', 'maximumAmplitudeFactor')


def scalar(token, *, nullable=False, signed=False):
    if nullable and token == '--undefined--': return None
    if not re.fullmatch(r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?', token):
        raise ValueError('Invalid shimmer PCM decimal syntax')
    value = float(token)
    if not math.isfinite(value) or (not signed and value < 0):
        raise ValueError('Invalid shimmer PCM scalar')
    return value


def integer(token):
    if not re.fullmatch(r'0|[1-9][0-9]*', token):
        raise ValueError('Invalid shimmer PCM count')
    return int(token)


def parse(raw, case, source):
    pcm_catalog.validate(case)
    if not isinstance(raw, str) or len(raw.encode()) > 4 * 1024 * 1024 or not raw.endswith('\n'):
        raise ValueError('Invalid shimmer PCM text')
    rows = [line.split('\t') for line in raw.splitlines()]
    cursor = 0
    def row(tag, size):
        nonlocal cursor
        if cursor >= len(rows) or len(rows[cursor]) != size or rows[cursor][0] != tag:
            raise ValueError('Missing/reordered shimmer PCM row: ' + tag)
        value = rows[cursor]
        cursor += 1
        return value
    if row('begin', 2)[1] != 'shimmer-pcm-v1': raise ValueError('Invalid PCM protocol version')
    if row('input', 3)[1:] != [str(case['sampleRate']), str(case['sampleCount'])]:
        raise ValueError('Shimmer PCM geometry differs')
    if [scalar(v) for v in row('settings', 7)[1:]] != [case[k] for k in SETTING_KEYS]:
        raise ValueError('Shimmer PCM query settings differ')
    count = integer(row('pulses', 2)[1])
    expected = source['fixture']['reference']['data']['pulseTimesSeconds']
    if count != len(expected): raise ValueError('Inherited pulse count differs')
    for i, time in enumerate(expected, 1):
        r = row('pulse', 3)
        if r[1] != str(i) or scalar(r[2], signed=True) != time:
            raise ValueError('Inherited pulse identity differs')
    selected = [i for i, t in enumerate(expected) if case['queryStartSeconds'] <= t <= case['queryEndSeconds']]
    if row('selected', 2)[1] != str(len(selected)): raise ValueError('Selected pulse count differs')
    state = 'insufficientPulses' if len(selected) < 3 else 'complete'
    header = row('amplitudes', 3)
    if header[1] != state: raise ValueError('Amplitude extraction state differs')
    size = integer(header[2])
    if size > max(0, len(selected) - 2): raise ValueError('Too many extracted amplitudes')
    allowed = {expected[i]: i for i in selected[1:-1]}
    amplitudes = []
    for i in range(1, size + 1):
        r = row('amplitude', 4)
        time, value = scalar(r[2]), scalar(r[3])
        if r[1] != str(i) or time not in allowed or value <= 0 or (amplitudes and time <= amplitudes[-1]['timeSeconds']):
            raise ValueError('Invalid or reordered extracted amplitude')
        amplitudes.append(dict(pulseIndex=allowed[time], timeSeconds=time, rmsAmplitude=value))
    tier, sound = None, None
    if state == 'insufficientPulses':
        if row('queries', 2)[1] != 'skippedInsufficientPulses': raise ValueError('Unexpected skipped-query state')
    else:
        tier, sound = {}, {}
        for key in shimmer_oracle.MEASUREMENTS:
            tier[key] = scalar(row('tier-' + key, 2)[1], nullable=True)
            sound[key] = scalar(row('sound-' + key, 2)[1], nullable=True)
        if tier != sound: raise ValueError('Combined waveform and extracted tier queries differ')
        for key, minimum in (('local', 2), ('db', 2), ('apq3', 3), ('apq5', 5), ('apq11', 11), ('dda', 3)):
            if size < minimum and tier[key] is not None: raise ValueError('Shimmer value without sufficient amplitudes')
        if (tier['local'] is None) != (tier['db'] is None) or (tier['apq3'] is None) != (tier['dda'] is None):
            raise ValueError('Inconsistent PCM shimmer availability')
        if tier['apq3'] is not None and tier['dda'] != 3 * tier['apq3']:
            raise ValueError('PCM shimmer DDA/APQ3 relation differs')
    if row('end', 2)[1] != 'shimmer-pcm-v1' or cursor != len(rows):
        raise ValueError('Incomplete or extra shimmer PCM records')
    return dict(pulseCount=count, selectedPulseIndices=selected, amplitudeState=state,
                amplitudes=amplitudes, tierValues=tier, soundValues=sound)


def make_record(case, source, raw):
    lock = load_json(ROOT / 'Tools/Reference/toolchain.json')
    data = parse(raw, case, source)
    body = dict(schemaVersion=1, input=case, inheritedFiles=source['files'],
        pulseReferenceIdentity=source['fixture']['reference']['referenceIdentity'],
        scriptSHA256=digest((HERE / 'pcm_probe.praat').read_bytes()), stdoutSHA256=digest(raw.encode()),
        toolchain=lock, command=['<verified-praat>', *lock['options'], 'pcm_probe.praat',
            '<verified-wave>', '<verified-pitch>', *[repr(float(case[k])) for k in SETTING_KEYS]],
        environment={'LC_ALL': 'C', 'LANG': 'C'}, data=data)
    return {'referenceIdentity': digest(canonical(body)), **body}


def evaluate(case, source, binary=None):
    pcm_catalog.validate(case)
    lock = load_json(ROOT / 'Tools/Reference/toolchain.json')
    binary = verify_tool(binary or ROOT / '.build/reference-tool' / lock['version'] / lock['executablePath'], lock)
    with tempfile.TemporaryDirectory(prefix='shimmer-pcm-', dir=ROOT / '.build') as temp:
        temp = Path(temp)
        for suffix in ('.wav', '.Pitch'):
            path = source['paths'][suffix]
            encoded = path.read_bytes()
            if digest(encoded) != source['files'][str(path.relative_to(ROOT))]:
                raise ValueError('Shimmer PCM source changed before execution')
            (temp / ('input' + suffix)).write_bytes(encoded)
        result = subprocess.run([str(binary), *lock['options'], str(HERE / 'pcm_probe.praat'),
            str(temp / 'input.wav'), str(temp / 'input.Pitch'), *[repr(float(case[k])) for k in SETTING_KEYS]],
            capture_output=True, text=True, encoding='utf-8', timeout=30,
            env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    if result.returncode or result.stderr.strip():
        raise ValueError(f'Shimmer PCM reference failed ({result.returncode}): {result.stderr[:1200]}')
    return make_record(case, source, result.stdout), result.stdout
