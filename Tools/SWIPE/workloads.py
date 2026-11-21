"""Independent closed SWIPE-prime/YIN workload inventory and receipt checks.

Profiles and geometry come from the original scalar oracles, never from Swift
output. Buffer accounting describes payloads on the supported 64-bit Apple ABI;
it excludes object bookkeeping and opaque vDSP setup tables.
"""
from array import array
import hashlib
import importlib.util
import math
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools/Reference'))
sys.path.insert(0, str(ROOT / 'Tools/SWIPE'))
from common import canonical
import swipe_oracle as swipe

_spec = importlib.util.spec_from_file_location('swipe_workload_yin', ROOT / 'Tools/YIN/oracle.py')
yin = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(yin)

ALGORITHMS = ('SWIPEPrime', 'YINFFT')
SHARDS = tuple(f'rate{rate}-{precision}' for rate in (16000, 44100, 48000)
               for precision in ('float32', 'float64')) + (
                   'MaximumGeometry', 'Silence', 'Noise', 'OwnedDiagnostics')
RECORD_KEYS = {
    'algorithm', 'algorithmicDelaySeconds', 'candidateCount', 'checksum', 'counts',
    'erbBinCount', 'hopSamples', 'inputSHA256', 'preparedBufferBytes', 'preparedInputBytes',
    'probes', 'profileIdentity', 'supportSamples', 'supportSeconds', 'windowLengths', 'workload',
}
COUNT_KEYS = {'full', 'partial', 'voiced', 'uncertain', 'unvoiced', 'unavailable',
              'exportedScalarSlots', 'exportedJSONBytes'}


def same_value(actual, expected):
    """Reject bool/integer confusion and undeclared fields in nested receipts."""
    if type(expected) is float:
        return type(actual) in (int, float) and actual == expected
    if type(actual) is not type(expected):
        return False
    if type(expected) is dict:
        return actual.keys() == expected.keys() and all(
            same_value(actual[key], value) for key, value in expected.items())
    if type(expected) is list:
        return len(actual) == len(expected) and all(
            same_value(a, b) for a, b in zip(actual, expected))
    return actual == expected


def expected_cases(shard=None):
    result = {}

    def add(kind='Harmonic', rate=48000, precision='float64', floor=80, ceiling=400, hop_ms=10):
        resolution = 192 if kind == 'MaximumGeometry' else 96
        hop = (rate * hop_ms + 500) // 1000
        profile = swipe.configuration(rate=rate, floor=floor, ceiling=ceiling, hop=hop,
                                      resolution=resolution, precision=precision)
        layout = swipe.geometry(profile)
        support = layout['requiredSampleCount']
        count = (support + 3 * hop + 1 if kind in ('MaximumGeometry', 'OwnedDiagnostics')
                 else rate * (10 if kind in ('Silence', 'Noise') else 2))
        name = f'{kind}.{precision}.{rate}Hz.n{count}.f{floor}-{ceiling}.h{hop_ms}.r{resolution}'
        baseline = dict(schemaVersion=1, tracker=None, estimator=yin.configuration(
            rate=rate, floor=floor, ceiling=ceiling, precision=precision, backend='fft',
            hop=min(hop, 2 * math.ceil(rate / floor) + 1)))
        workload = dict(name=name, kind=kind, configuration=profile, baseline=baseline,
                        requestedHopMilliseconds=hop_ms, inputSampleCount=count, chunkSamples=256)
        result[name] = dict(workload=workload, layout=layout,
                            shard=f'rate{rate}-{precision}' if kind == 'Harmonic' else kind)

    for rate in (16000, 44100, 48000):
        for precision in ('float32', 'float64'):
            for floor, ceiling in ((80, 400), (25, 2000)):
                for hop_ms in (5, 10, 20):
                    add(rate=rate, precision=precision, floor=floor, ceiling=ceiling, hop_ms=hop_ms)
    for precision in ('float32', 'float64'):
        add(kind='MaximumGeometry', rate=192000, precision=precision, floor=20, ceiling=48000)
        for kind in ('Silence', 'Noise', 'OwnedDiagnostics'):
            add(kind=kind, precision=precision)
    if len(result) != 44 or any(r['layout']['requiredSampleCount'] != 131072 for r in result.values()
                               if r['workload']['kind'] == 'MaximumGeometry'):
        raise ValueError('Closed workload inventory or literal maximum changed')
    if shard is not None:
        if shard not in SHARDS:
            raise ValueError('Unknown SWIPE comparison shard')
        result = {name: row for name, row in result.items() if row['shard'] == shard}
    return result


def window_candidate_counts(layout):
    return {length: sum(pair['lowerLength'] == length or
                        (pair['upperWeight'] > 0 and pair['upperLength'] == length)
                        for pair in layout['candidateWindows']) for length in layout['windowLengths']}


def expected_geometry(row, algorithm):
    workload, layout = row['workload'], row['layout']
    c = workload['configuration']
    stride = 4 if c['inputPrecision'] == 'float32' else 8
    rate = c['sampleRate']
    if algorithm == 'SWIPEPrime':
        support, hop = layout['requiredSampleCount'], c['hopLength']
        candidates, erb = len(layout['candidateFrequenciesHz']), len(layout['erbFrequenciesHz'])
        lengths = layout['windowLengths']
        selected = window_candidate_counts(layout)
        # Double? stride16, window mixture24, borrowed window80, Int8.
        payload = (8 * candidates * erb + 8 * support + 64 * candidates + 8 * erb
                   + 88 * len(lengths) + 3 * support * stride
                   + sum(44 * n + 24 + 32 * erb + 8 * selected[n] + 16 * candidates
                         for n in lengths))
    elif algorithm == 'YINFFT':
        estimator = workload['baseline']['estimator']
        _, _, lo, hi, support = yin.geometry(estimator)
        hop, integration = estimator['hopLength'], estimator['integrationLength']
        lags = hi + 2
        fft = 1 << (support + integration - 2).bit_length()
        # Candidate record stride56; real/complex scratch and framer payloads.
        payload = ((support + 2 * lags) * 8 + (hi - lo + 1) * 56 + 3 * support * stride
                   + (integration + support + 1 + 3 * fft) * 8 + 2 * (fft // 2 + 1) * 16)
        candidates, erb, lengths = 0, 0, []
    else:
        raise ValueError('Unknown comparison algorithm')
    return dict(preparedInputBytes=workload['inputSampleCount'] * stride,
                preparedBufferBytes=payload, supportSamples=support, hopSamples=hop,
                supportSeconds=support / rate, algorithmicDelaySeconds=support / rate / 2,
                windowLengths=lengths, candidateCount=candidates, erbBinCount=erb)


def expected_export_slots(row, algorithm, full):
    if row['workload']['kind'] != 'OwnedDiagnostics':
        return 0
    if algorithm == 'YINFFT':
        c = row['workload']['baseline']['estimator']
        return full * 2 * (math.ceil(c['sampleRate'] / c['pitchFloorHz']) + 2)
    layout = row['layout']
    candidates, erb = len(layout['candidateFrequenciesHz']), len(layout['erbFrequenciesHz'])
    selected = window_candidate_counts(layout)
    return full * (2 * candidates + 4 * erb + sum(
        n // 2 + 1 + erb + selected[n] + candidates for n in layout['windowLengths']))


def pcm_samples(row):
    """Original recipe, rounded once to the declared PCM precision.

    The supported Apple hosts are little endian. Keep generation independent
    from the native executable and include its exact bytes in the evidence.
    """
    workload = row['workload']
    c, kind = workload['configuration'], workload['kind']
    code = 'f' if c['inputPrecision'] == 'float32' else 'd'
    state = 44

    def values():
        nonlocal state
        for index in range(workload['inputSampleCount']):
            if kind == 'Silence':
                yield 0.
            elif kind == 'Noise':
                state = (1664525 * state + 1013904223) % (1 << 32)
                yield (state - 2147483648) / 4294967296
            else:
                phase = 2 * math.pi * 125 * index / c['sampleRate']
                yield (.4 * math.sin(phase) + .1 * math.sin(2 * phase + .13)
                       + .04 * math.sin(3 * phase))

    result = array(code, values())
    if sys.byteorder != 'little' or result.itemsize != (4 if code == 'f' else 8):
        raise ValueError('Unsupported PCM host byte layout')
    return result


def validate_matrix(matrix, shard=None):
    expected = expected_cases(shard)
    if type(matrix) is not list or len(matrix) != 2 * len(expected):
        raise ValueError('Missing or extra paired workload rows')
    seen, hashes, pcm_rows = set(), {}, {}
    for record in matrix:
        if type(record) is not dict or record.keys() != RECORD_KEYS:
            raise ValueError('Missing or extra workload receipt fields')
        workload, algorithm = record['workload'], record['algorithm']
        if type(workload) is not dict or type(algorithm) is not str:
            raise ValueError('Invalid workload identity')
        name = workload.get('name')
        if type(name) is not str or name not in expected or algorithm not in ALGORITHMS:
            raise ValueError('Unexpected workload or algorithm')
        key = name, algorithm
        if key in seen:
            raise ValueError('Duplicate workload/algorithm pair')
        seen.add(key)
        row = expected[name]
        if not same_value(workload, row['workload']):
            raise ValueError('Incorrect workload recipe/profile')
        geometry = expected_geometry(row, algorithm)
        if any(not same_value(record[k], value) for k, value in geometry.items()):
            raise ValueError('Incorrect support, workspace, grid or delay')
        if not 0 < record['preparedBufferBytes'] < 64 * 1024 * 1024:
            raise ValueError('Prepared worker exceeds the frozen memory bound')
        profile = workload['configuration'] if algorithm == 'SWIPEPrime' else workload['baseline']
        family = swipe.NAME if algorithm == 'SWIPEPrime' else 'yin-estimator-and-optional-tracker'
        identity = dict(identifier=dict(name=family, version=1),
                        sha256=hashlib.sha256(canonical(profile)).hexdigest())
        if not same_value(record['profileIdentity'], identity):
            raise ValueError('Incorrect profile identity')
        digest = record['inputSHA256']
        if type(digest) is not str or re.fullmatch('[a-f0-9]{64}', digest) is None:
            raise ValueError('Missing PCM identity')
        c = workload['configuration']
        signal = 'Harmonic' if workload['kind'] in ('MaximumGeometry', 'OwnedDiagnostics') else workload['kind']
        pcm_key = signal, c['sampleRate'], c['inputPrecision'], workload['inputSampleCount']
        if pcm_key in hashes and hashes[pcm_key] != digest:
            raise ValueError('Identical declared PCM differs across algorithms/profiles')
        hashes[pcm_key] = digest
        pcm_rows[pcm_key] = row
        support, hop = geometry['supportSamples'], geometry['hopSamples']
        full = (workload['inputSampleCount'] - support) // hop + 1
        partial = int(full * hop < workload['inputSampleCount'])
        counts = record['counts']
        if (type(counts) is not dict or counts.keys() != COUNT_KEYS
                or any(type(v) is not int or v < 0 for v in counts.values())):
            raise ValueError('Invalid coverage/export counts')
        if (counts['full'] != full or counts['partial'] != partial
                or sum(counts[k] for k in ('voiced', 'uncertain', 'unvoiced', 'unavailable')) != full + partial
                or counts['unavailable'] < partial):
            raise ValueError('Incorrect full/partial/status coverage')
        if workload['kind'] in ('Harmonic', 'OwnedDiagnostics') and counts['voiced'] != full:
            raise ValueError('Harmonic signal lost voiced coverage')
        if workload['kind'] == 'Silence' and counts['unvoiced'] != full:
            raise ValueError('Silence produced an estimate')
        if counts['exportedScalarSlots'] != expected_export_slots(row, algorithm, full):
            raise ValueError('Incorrect owned scalar export coverage')
        if ((counts['exportedJSONBytes'] > 0) != (workload['kind'] == 'OwnedDiagnostics')):
            raise ValueError('Incorrect owned JSON export coverage')
        checksum = record['checksum']
        if type(checksum) not in (int, float) or not math.isfinite(checksum) or checksum <= 0:
            raise ValueError('Missing finite observable checksum')
        indices = sorted({0, (full - 1) // 2, full - 1})
        probes = record['probes']
        if type(probes) is not list or len(probes) != len(indices):
            raise ValueError('Missing first/middle/last probes')
        for index, probe in zip(indices, probes):
            required = {'frameIndex', 'startSample', 'observedSamples', 'status'}
            if type(probe) is not dict or not required <= probe.keys() or probe.keys() - required - {'frequencyHz', 'strength'}:
                raise ValueError('Malformed scalar probe')
            if any(type(probe[k]) is not int or probe[k] != v for k, v in
                   (('frameIndex', index), ('startSample', index * hop), ('observedSamples', support))):
                raise ValueError('Incorrect probe timing/support')
            status = probe['status']
            if status not in ('voiced', 'uncertain', 'unvoiced', 'unavailable') or counts[status] == 0:
                raise ValueError('Probe status contradicts coverage')
            available = status in ('voiced', 'uncertain')
            for key in ('frequencyHz', 'strength'):
                value = probe.get(key)
                if available:
                    if type(value) not in (int, float) or not math.isfinite(value):
                        raise ValueError('Missing finite scalar estimate')
                elif value is not None:
                    raise ValueError('Unavailable probe fabricated a numeric estimate')
            if available and not c['pitchFloorHz'] <= probe['frequencyHz'] <= c['pitchCeilingHz']:
                raise ValueError('Probe frequency outside the declared range')
    if seen != {(name, algorithm) for name in expected for algorithm in ALGORITHMS}:
        raise ValueError('Incomplete paired workload inventory')
    for key, row in pcm_rows.items():
        if hashlib.sha256(pcm_samples(row).tobytes()).hexdigest() != hashes[key]:
            raise ValueError('PCM hash differs from the independent input recipe')
    return matrix
