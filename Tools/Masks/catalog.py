"""Original mask fixtures and frozen numerical budgets; no Swift-derived expected values."""
import math
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools/Reference'))
from common import read_pcm

COMPARISON = {
    'schemaVersion': 1,
    'spectrogramPower': {'absolute': 1e-16, 'relative': 1e-9},
    'temporalFlatness': {'absolute': 1e-8, 'relative': 1e-10},
    'referenceIntensityDB': {'absolute': 1e-7, 'relative': 0},
    'intervalBoundarySeconds': {'absolute': 1e-12, 'relative': 0},
    'sampleBoundaries': 'exact-nearest-source-boundary-ties-away-from-zero',
}


def cases():
    result = []
    def add(name, source, **settings):
        result.append({'name': name, 'source': source, 'profile': {
            'inputPrecision': 'float64', 'hopSeconds': .01, 'shortWindowSeconds': .1,
            'longWindowSeconds': .3, 'minimumFrequencyHz': 70., 'maximumFrequencyHz': 6000.,
            'flatnessThreshold': -10., 'relativeIntensityThresholdDB': -35.,
            'minimumSpeechSeconds': .1, 'minimumNonSpeechSeconds': .1, **settings}})
    for kind in ('tone-envelope', 'fricative-surrogate', 'quiet-vowel-surrogate', 'breathy-surrogate', 'irregular-surrogate'):
        add(kind, {'kind': kind, 'sampleRate': 16000, 'sampleCount': 16000})
    for name in ('silence', 'regular-pulses', 'harmonic-low', 'harmonic-high', 'missing-fundamental',
                 'vowel-low', 'vowel-high', 'noise-seed-zero', 'noise-mixture-0db'):
        add('synthetic-' + name, {'path': f'Tests/HDXLVoiceProcessingTests/Fixtures/Synthetic/{name}.wav'})
    for name in ('bl01-vowel-a', 'bl01-consonant-rich', 'bl02-vowel-i', 'bl02-consonant-rich',
                 'bl03-vowel-a', 'bl03-all-voiced', 'bl01-noisy', 'bl01-dropout'):
        add('speech-' + name, {'path': f'Tests/HDXLVoiceProcessingTests/Fixtures/Corpus/samples/corpus-{name}.wav'})
    for rate in (8000, 44100, 48000):
        add(f'grid-{rate}', {'kind': 'tone-envelope', 'sampleRate': rate, 'sampleCount': rate + 37})
    for hop in (.002, .005, .03):
        add(f'hop-{hop}', {'kind': 'tone-envelope', 'sampleRate': 16000, 'sampleCount': 16000}, hopSeconds=hop)
    add('no-relative-intensity', {'kind': 'tone-envelope', 'sampleRate': 16000, 'sampleCount': 16000}, relativeIntensityThresholdDB=None)
    add('murton-mask-settings', {'kind': 'breathy-surrogate', 'sampleRate': 16000, 'sampleCount': 16000},
        relativeIntensityThresholdDB=-15., minimumSpeechSeconds=.02, minimumNonSpeechSeconds=.02)
    add('fractional-short-window', {'kind': 'tone-envelope', 'sampleRate': 16000, 'sampleCount': 16000}, shortWindowSeconds=.073, longWindowSeconds=.275)
    add('one-frame', {'kind': 'noise', 'sampleRate': 16000, 'sampleCount': 321}, minimumSpeechSeconds=.001, minimumNonSpeechSeconds=.001)
    add('short-averaging-disabled', {'kind': 'tone-envelope', 'sampleRate': 16000, 'sampleCount': 16000}, shortWindowSeconds=.001)
    add('rolling-rebase', {'kind': 'dynamic-range', 'sampleRate': 16000, 'sampleCount': 192000}, shortWindowSeconds=.001, relativeIntensityThresholdDB=None)
    add('float32-input', {'kind': 'breathy-surrogate', 'sampleRate': 48000, 'sampleCount': 48000}, inputPrecision='float32')
    return result


def source_samples(case):
    source = case['source']
    if 'path' in source:
        path = (ROOT / source['path']).resolve()
        if not path.is_relative_to(ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures'):
            raise ValueError('Input path leaves fixture tree')
        values, record = read_pcm(path)
        rate = record['sampleRate']
    else:
        rate = source['sampleRate']
        kind = source['kind']
        values = []
        state = 34
        previous_noise = 0.
        phase = 0.
        for i in range(source['sampleCount']):
            state = (1664525 * state + 1013904223) & 0xffffffff
            noise = (state - 2147483648) / 2147483648
            t = i / rate
            envelope = .01 if t < .25 else (.3 if t < .65 else .001)
            if kind == 'tone-envelope':
                # Quantized original probe, with exact decoded values as input.
                value = round(32767 * envelope * (math.sin(math.tau*173*t) + .2*math.sin(math.tau*1231*t))) / 32768
            elif kind == 'noise': value = .1 * noise
            elif kind == 'fricative-surrogate': value = envelope * .5 * (noise - previous_noise)
            elif kind == 'quiet-vowel-surrogate':
                value = .001 * math.fsum(math.sin(math.tau*123*k*t)/k for k in range(1, 16)) / 4
            elif kind == 'breathy-surrogate':
                value = envelope * (.5 * noise + .2 * math.sin(math.tau*137*t))
            elif kind == 'irregular-surrogate':
                phase += (110 + 31 * math.sin(math.tau*7*t)) / rate
                value = envelope * (.5 * math.sin(math.tau*phase) + .2 * noise)
            elif kind == 'dynamic-range':
                block = (i // 1600) % 3
                value = (0 if block == 0 else (1e-100 if block == 1 else 1.)) * math.sin(math.tau*173*t)
            else: raise ValueError('Unknown original source equation')
            values.append(value)
            previous_noise = noise
    if case['profile']['inputPrecision'] == 'float32':
        values = [struct.unpack('<f', struct.pack('<f', value))[0] for value in values]
    if not values or not all(math.isfinite(value) for value in values):
        raise ValueError('Reference inputs must be nonempty finite mono PCM')
    return values, rate


def wave64(values, rate):
    if not 8000 <= rate <= 96000 or not 0 < len(values) <= 1_200_000:
        raise ValueError('Reference WAVE geometry exceeds budget')
    payload = struct.pack(f'<{len(values)}d', *values)
    fmt = struct.pack('<HHIIHH', 3, 1, rate, rate*8, 8, 64)
    chunks = b'fmt ' + struct.pack('<I', 16) + fmt + b'fact' + struct.pack('<II', 4, len(values))
    chunks += b'data' + struct.pack('<I', len(payload)) + payload
    return b'RIFF' + struct.pack('<I', len(chunks)+4) + b'WAVE' + chunks
