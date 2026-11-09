"""Original pulse sources and explicit sampled F0; never uses native analysis."""
import math
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(1, str(ROOT / 'Tools/Reference'))
from common import read_pcm

KINDS = ('gaussian', 'sine', 'harmonic', 'filtered', 'noise', 'silence', 'constant', 'impulse', 'splice', 'licensedSpeech')


def make_case(name, kind='gaussian', *, rate=16000, precision='float64', count=None,
              hz=150., end_hz=None, gain=1., offset=0., noise=0., jitter=0.,
              modulation=0., alternating=False, missing_every=0, gap=False,
              unvoiced=False, pitch_scale=1., path=None):
    return {'name': name, 'sampleRate': rate, 'sampleCount': count if count is not None else rate // 2,
            'inputPrecision': precision, 'pitchSource': 'praatRawCC' if kind == 'licensedSpeech' else 'suppliedContour',
            'source': {'kind': kind, 'frequencyHz': float(hz),
                       'endFrequencyHz': float(hz if end_hz is None else end_hz),
                       'gain': float(gain), 'offset': float(offset), 'noiseAmplitude': float(noise),
                       'jitterFraction': float(jitter), 'amplitudeModulation': float(modulation),
                       'alternatingStrength': alternating, 'missingEvery': missing_every,
                       'unvoicedGap': gap, 'allUnvoiced': unvoiced, 'pitchScale': float(pitch_scale),
                       'seed': 42001, 'corpusPath': path}}


def cases():
    result = []
    for precision in ('float32', 'float64'):
        def add(name, **kwargs):
            result.append(make_case(f'{name}-{precision}', precision=precision, **kwargs))
        for rate in (16000, 44100, 48000):
            for hz in (80, 150, 300, 600):
                add(f'gaussian-{rate}-{hz}', rate=rate, hz=hz)
        for hz in (80, 150, 300, 600):
            add(f'sine-{hz}', kind='sine', hz=hz)
        for name, settings in [
            ('inverted', {'gain': -1.}), ('sine-inverted', {'kind': 'sine', 'gain': -1.}),
            ('jitter-1pct', {'jitter': .01}), ('jitter-12pct', {'jitter': .12}),
            ('modulated', {'modulation': .4}), ('alternating', {'alternating': True}),
            ('missing-cycles', {'missing_every': 7}), ('unvoiced-gap', {'gap': True}),
            ('all-unvoiced', {'unvoiced': True}), ('wrong-double-f0', {'pitch_scale': 2.}),
            ('wrong-half-f0', {'pitch_scale': .5}), ('rising-f0', {'hz': 80., 'end_hz': 600.}),
            ('falling-f0', {'hz': 600., 'end_hz': 80.}), ('quiet', {'gain': .001}),
            ('offset', {'gain': .7, 'offset': .2}), ('filtered', {'kind': 'filtered'}),
            ('harmonic', {'kind': 'harmonic'}), ('noise', {'kind': 'noise'}),
            ('silence', {'kind': 'silence'}), ('constant', {'kind': 'constant'}),
            ('impulse', {'kind': 'impulse'}), ('splice', {'kind': 'splice'}),
            ('noisy-low', {'noise': .02}), ('noisy-high', {'noise': .3})]:
            add(name, **settings)
        for count in (1, 2, 3, 80, 160, 240, 321):
            add(f'short-{count}', count=count)
        for name in ('bl01-vowel-a', 'bl02-vowel-a', 'bl03-vowel-a', 'bl01-all-voiced',
                     'bl02-consonant-rich', 'bl01-noisy', 'bl01-low-level', 'bl01-dropout'):
            add('speech-' + name, kind='licensedSpeech', rate=44100,
                path=f'Tests/HDXLVoiceProcessingTests/Fixtures/Corpus/samples/corpus-{name}.wav')
    assert len(result) == len({c['name'] for c in result})
    return result


def source(case):
    """Return actual rounded PCM and known source landmarks (not tracker answers)."""
    rate, count, s = case['sampleRate'], case['sampleCount'], case['source']
    if type(rate) is not int or rate not in (16000, 44100, 48000) or type(count) is not int or not 1 <= count <= rate * 5:
        raise ValueError('Unsupported catalog geometry')
    if s['kind'] not in KINDS or case['inputPrecision'] not in ('float32', 'float64'):
        raise ValueError('Unknown source/precision')
    duration = count * (1 / rate)
    hz, end_hz = s['frequencyHz'], s['endFrequencyHz']
    slope = (end_hz - hz) / duration
    landmarks = []
    if s['kind'] == 'licensedSpeech':
        path = (ROOT / s['corpusPath']).resolve()
        if not path.is_relative_to((ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/Corpus/samples').resolve()):
            raise ValueError('Unapproved corpus path')
        samples, info = read_pcm(path)
        if info['sampleRate'] != rate or len(samples) < count:
            raise ValueError('Corpus geometry differs')
        samples = samples[:count]
    else:
        samples = [0.] * count
        if s['kind'] in ('gaussian', 'filtered', 'splice'):
            cycle = 0
            position = .37 / hz
            while position < duration:
                if slope:
                    phase = cycle + .37
                    position = 2 * phase / (hz + math.sqrt(hz * hz + 2 * slope * phase))
                    if position >= duration:
                        break
                local_hz = hz + slope * position
                amplitude = .6 * (1 + s['amplitudeModulation'] * math.sin(math.pi * cycle / 2)) / (1 + s['amplitudeModulation'])
                if s['alternatingStrength'] and cycle % 2:
                    amplitude *= .2
                present = not s['missingEvery'] or (cycle + 1) % s['missingEvery'] != 0
                landmarks.append({'timeSeconds': position, 'amplitude': amplitude, 'rendered': present})
                if present:
                    width = .06 / local_hz
                    start = max(0, math.ceil((position - 8 * width) * rate - .5))
                    stop = min(count, math.floor((position + 8 * width) * rate - .5) + 1)
                    for i in range(start, stop):
                        t = (i + .5) / rate
                        samples[i] += amplitude * math.exp(-.5 * ((t - position) / width) ** 2)
                period = (1 + s['jitterFraction'] * (-1., .5, 1., -.5, 0.)[cycle % 5]) / local_hz
                position += period
                cycle += 1
        state = s['seed']
        for i in range(count):
            state = (1664525 * state + 1013904223) & 0xffffffff
            noise = 2 * state / 4294967296 - 1
            t = (i + .5) / rate
            phase = hz * t + .5 * slope * t * t
            kind = s['kind']
            if kind == 'sine': samples[i] = .7 * math.sin(2 * math.pi * phase)
            elif kind == 'harmonic': samples[i] = .18 * math.fsum(math.sin(2 * math.pi * k * phase) / k for k in range(1, 9))
            elif kind == 'noise': samples[i] = .5 * noise
            elif kind == 'constant': samples[i] = .3
            elif kind == 'impulse': samples[i] = .7 if i == count // 2 else 0.
            if kind == 'splice' and count * .4 <= i < count * .6:
                samples[i] = .5 * noise
            samples[i] = (samples[i] + s['noiseAmplitude'] * noise) / max(1., .7 + s['noiseAmplitude'])
        if s['kind'] == 'filtered':
            for frequency, bandwidth in ((650., 100.), (1200., 150.), (2500., 200.)):
                radius = math.exp(-math.pi * bandwidth / rate)
                a, b = 2 * radius * math.cos(2 * math.pi * frequency / rate), radius * radius
                previous = older = 0.
                for i, value in enumerate(samples):
                    new = value + a * previous - b * older
                    samples[i] = new
                    older, previous = previous, new
            peak = max(map(abs, samples), default=0.)
            if peak: samples = [v * .7 / peak for v in samples]
        samples = [s['gain'] * v + s['offset'] for v in samples]
    if case['inputPrecision'] == 'float32':
        samples = list(struct.unpack(f'<{count}f', struct.pack(f'<{count}f', *samples)))
    if not all(math.isfinite(v) and abs(v) <= 1 for v in samples):
        raise ValueError('Source exceeds finite normalized PCM')
    return samples, landmarks


def supplied_pitch(case):
    if case['pitchSource'] != 'suppliedContour':
        raise ValueError('This source requires a separately retained reference F0 contour')
    duration = case['sampleCount'] * (1 / case['sampleRate'])
    n = max(1, math.floor(duration / .005))
    step = min(.005, duration)
    first = duration / 2 - (n - 1) * step / 2
    s = case['source']
    slope = (s['endFrequencyHz'] - s['frequencyHz']) / duration
    frequencies = []
    for i in range(n):
        t = math.fma(float(i), step, first)
        hz = (s['frequencyHz'] + slope * t) * s['pitchScale']
        frequencies.append(0. if s['allUnvoiced'] or (s['unvoicedGap'] and .4 * duration <= t < .6 * duration) else hz)
    return {'domainEndSeconds': duration, 'firstCenterSeconds': first, 'stepSeconds': step,
            'ceilingHz': 1500., 'frequenciesHz': frequencies}
