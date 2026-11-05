"""Original inputs and frozen CPPS budgets; expected values never come from Swift."""
import math
import hashlib
import struct
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools/Reference'))
from common import read_pcm

COMPARISON = {
    'power': {'absolute': 1e-10, 'relative': 1e-11},
    'decibelAbsolute': 1e-8, 'slopeAbsolute': 1e-6, 'quefrencyAbsolute': 1e-12,
    'axisAbsolute': 1e-12,
    'wholePCM': {'decibelAbsolute': 1e-4, 'slopeAbsolute': .01, 'quefrencyAbsolute': 1e-8},
}


def settings(**changes):
    return {'constructionFloorHz': 60., 'hopSeconds': .002, 'maximumFrequencyHz': 5000.,
            'preEmphasisFromHz': 50., 'timeWindowSeconds': .01, 'quefrencyWindowSeconds': .001,
            'subtractTrendBeforeSmoothing': False, 'pitchFloorHz': 60., 'pitchCeilingHz': 330.,
            'pitchTolerance': .05, 'interpolation': 'Parabolic', 'fitStartSeconds': .001,
            'fitEndSeconds': 0., 'trend': 'Straight', 'fit': 'Robust', **changes}


def cases():
    result = []
    def object_case(name, kind, time, q, pre=False, tolerance=.05, frames=13):
        result.append({'name': name, 'source': {'kind': 'power-object', 'equation': kind,
            'frameCount': frames, 'binCount': 513, 'firstCenter': .05, 'qStep': .0001,
            'duration': .1 + (frames - 1) * .002}, 'profile': settings(timeWindowSeconds=time,
            quefrencyWindowSeconds=q, subtractTrendBeforeSmoothing=pre, pitchTolerance=tolerance)})
    object_case('time-10ms', 'time-impulse', .01, 0)
    for name, width in [('below2', .003999999999), ('at2', .004), ('above2', .004000000001)]:
        object_case('time-' + name, 'time-impulse', width, 0)
    for name, width in [('1ms', .001), ('5ms', .005), ('below2', .000199999999),
                        ('at2', .0002), ('above2', .000200000001)]:
        object_case('q-' + name, 'q-impulse', 0, width)
    object_case('q-edge', 'q-edge', 0, .001)
    object_case('affine-both', 'affine', .01, .001)
    object_case('singleton', 'affine', .05, .001, frames=1)
    for name, time, q, pre in [('no-smooth', 0, 0, False), ('pretrend-no-smooth', 0, 0, True),
                              ('smoothed', .01, .001, False), ('pretrend-smoothed', .01, .001, True)]:
        object_case('tilted-' + name, 'tilted', time, q, pre)
    object_case('tolerance-low', 'tilted', .01, .001, tolerance=.000001)
    object_case('tolerance-high', 'tilted', .01, .001, tolerance=.9)
    def pcm(name, path, **changes):
        result.append({'name': name, 'source': {'kind': 'pcm', 'path': path},
                       'validationScope': 'whole-cpps-parity', 'profile': settings(**changes)})
    for name in ('bl01-vowel-a', 'bl01-consonant-rich', 'bl02-vowel-i', 'bl02-consonant-rich',
                 'bl03-vowel-a', 'bl03-all-voiced', 'bl01-noisy', 'bl01-dropout'):
        pcm('speech-' + name, f'Tests/HDXLVoiceProcessingTests/Fixtures/Corpus/samples/corpus-{name}.wav')
    # Acquisition loss is explicitly known from the original corpus transformation;
    # a whole conditioned interval spanning it is characterization, not a valid
    # mask-selected measurement. Retain it rather than hiding the failed parity.
    dropout = next(case for case in result if case['name'] == 'speech-bl01-dropout')
    dropout['validationScope'] = 'unmasked-acquisition-loss-characterization'
    dropout['source']['missingAcquisition'] = {'startSample': 22050, 'sampleCount': 8820}
    for name, start, count in [('before', 0, 22050), ('after', 30870, 57330)]:
        pcm('dropout-acquired-' + name, dropout['source']['path'])
        result[-1]['source']['startSample'] = start
        result[-1]['source']['sampleCount'] = count
    all_voiced = 'Tests/HDXLVoiceProcessingTests/Fixtures/Corpus/samples/corpus-bl03-all-voiced.wav'
    pcm('speech-5ms-q-comparison', all_voiced, quefrencyWindowSeconds=.005)
    pcm('speech-pretrend', all_voiced, subtractTrendBeforeSmoothing=True)
    for hop in (.005, .01, .03): pcm(f'speech-hop-{hop}', all_voiced, hopSeconds=hop)
    for window in (.02, .05): pcm(f'speech-time-{window}', all_voiced, timeWindowSeconds=window)
    pcm('pcm-120ms', 'Tests/HDXLVoiceProcessingTests/Fixtures/Reference/saw-120ms.wav')
    return result


def power(case):
    source = case['source']
    if source['kind'] != 'power-object': raise ValueError('Not a constructed power object')
    kind = source['equation']
    values = []
    for row in range(source['binCount']):
        q = row * source['qStep']
        for column in range(source['frameCount']):
            if kind == 'time-impulse': value = 1.0 + (column == 6)
            elif kind == 'q-impulse': value = 1.0 + (row == 256)
            elif kind == 'q-edge': value = 1.0 + (row == 0)
            elif kind == 'affine': value = 1 + .01 * column + .005 * row
            elif kind == 'tilted':
                value = 10 ** ((30 - 400*q + 12*math.exp(-((q-.008)/.0004)**2)
                    + .8*math.sin(row*1.07 + .31*column) + 3*math.cos(row*.17)) / 10)
            else: raise ValueError('Unknown original equation')
            values.append(value)
    return values


def object_text(case):
    s, p = case['source'], case['profile']
    # Public short-text object serialization. Leading zeroes are required for
    # decimal fractions: Praat's token reader does not accept '.05' as '0.05'.
    header = ['File type = "ooTextFile"', 'Object class = "PowerCepstrogram 2"', '',
        '0', repr(s['duration']), str(s['frameCount']), repr(p['hopSeconds']), repr(s['firstCenter']),
        '0', repr((s['binCount']-1)*s['qStep']), str(s['binCount']), repr(s['qStep']), '0']
    return ('\n'.join(header + [format(value, '.17g') for value in power(case)]) + '\n').encode()


def pcm(case):
    path = (ROOT / case['source']['path']).resolve()
    if not path.is_relative_to(ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures'):
        raise ValueError('Source leaves the independently governed fixture tree')
    values, record = read_pcm(path)
    if 'startSample' in case['source']:
        start, count = case['source']['startSample'], case['source']['sampleCount']
        if not 0 <= start < start + count <= len(values): raise ValueError('Invalid source slice')
        values = values[start:start+count]
        record = {**record, 'sampleCount': count,
            'normalizedFloat64LESHA256': hashlib.sha256(struct.pack(f'<{count}d', *values)).hexdigest(),
            'sourceSupport': {'startSample': start, 'sampleCount': count}}
    return values, record


def encoded_pcm(case):
    if 'startSample' not in case['source']:
        return (ROOT/case['source']['path']).read_bytes()
    values, record = pcm(case)
    payload = struct.pack(f'<{len(values)}d', *values)
    rate = record['sampleRate']
    return struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', 36+len(payload), b'WAVE', b'fmt ',
                       16, 3, 1, rate, rate*8, 8, 64, b'data', len(payload)) + payload
