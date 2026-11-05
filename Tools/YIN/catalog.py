"""Bounded original signals and explicitly identified existing licensed speech."""
import math
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(1, str(ROOT / 'Tools/Reference'))
from common import read_pcm
from oracle import configuration, geometry


def cases():
    rows = []

    def add(name, kind='tone', frequency=137., duration=.12, group='characterization',
            rate=16000, floor=50., ceiling=700., hop=.01, **options):
        profile = configuration(rate, floor, ceiling, math.floor(rate * hop + .5),
                                integration=options.pop('integration', None),
                                precision=options.pop('precision', 'float64'),
                                threshold=options.pop('threshold', .1),
                                silence=options.pop('silence', 1e-7))
        rows.append({'name': name, 'profile': profile, 'acceptanceGroup': group,
                     'source': {'kind': kind, 'frequencyHz': frequency,
                                'sampleCount': math.floor(duration * rate + .5), **options}})

    for hz in (51., 80., 123.45, 440., 650.):
        add(f'tone-{hz:g}', frequency=hz, group='clean-tone')
    add('harmonic', kind='harmonic', frequency=123.45, group='clean-harmonic')
    add('missing-fundamental', kind='missing', frequency=123.45, group='clean-harmonic')
    add('dominant-second', kind='dominant', frequency=123.45)
    for hz in (49.9, 50., 50.1, 699.9, 700., 700.1):
        add(f'boundary-{hz:g}', frequency=hz)
    for kind in ('chirp', 'vibrato', 'octave-jump', 'irregular-pulses', 'breathy', 'fricative', 'noise'):
        add(kind, kind=kind, duration=.18)
    for snr in (20, 10, 0, -10):
        add(f'snr-{snr}', kind='snr', snrDB=snr)
    for kind in ('silence', 'constant'):
        add(kind, kind=kind, group='no-pitch')
    add('near-dc', dc=.5, amplitude=1e-12)
    # Review regression: absolute FFT cancellation cutoffs alone can miss these
    # intermediate AC/DC ratios, whose residual errors are amplified by CMND.
    for kind in ('offset-tone', 'offset-noise', 'offset-noisy-tone'):
        for amplitude in (1e-3, 1e-4, 1e-5, 1e-6):
            add(f'{kind}-{amplitude:g}', kind=kind, dc=.5, amplitude=amplitude)
        add(f'float32-{kind}', kind=kind, dc=-.5, amplitude=1e-4, precision='float32')
        add(f'48000-{kind}', kind=kind, dc=.5, amplitude=1e-5, rate=48000)
    add('offset-near-threshold', kind='offset-noisy-tone', dc=.5, amplitude=1e-5,
        threshold=.025731912, hop=.005)
    # Quantized nonadjacent global ties: the boundary candidate exists only
    # because the smaller integer lag wins. Perturb both sides of the tie too.
    for name, precision, perturbation in (
            ('quantized-global-tie', 'float64', 0.),
            ('float32-quantized-global-tie', 'float32', 0.),
            ('quantized-global-tie-plus', 'float64', 1e-6),
            ('quantized-global-tie-minus', 'float64', -1e-6)):
        add(name, kind='quantized-global-tie', rate=4000, floor=100., ceiling=1000.,
            integration=40, hop=.01, duration=81/4000, precision=precision,
            perturbation=perturbation)
    add('tiny-signal', amplitude=1e-100, silence=0, group='clean-tone')
    add('huge-signal', amplitude=1e300, group='clean-tone')
    add('below-silence-threshold', amplitude=1e-9, group='no-pitch')
    add('float32-tone', precision='float32', group='clean-tone')
    add('float32-breathy', precision='float32', kind='breathy')
    add('longer-integration', integration=640, duration=.14, group='clean-tone')
    add('strict-threshold', kind='snr', snrDB=10, threshold=.02)
    add('relaxed-threshold', kind='snr', snrDB=0, threshold=.3)
    for rate in (16000, 44100, 48000):
        for hop in (.005, .01):
            for floor, ceiling, hz in ((50., 700., 73.7), (25., 2000., 31.3)):
                add(f'grid-{rate}-{hop:g}-{floor:g}', rate=rate, floor=floor, ceiling=ceiling,
                    frequency=hz, hop=hop, duration=.1, group='clean-tone')
    add('wide-high', frequency=1777.7, floor=25., ceiling=2000., group='clean-tone')
    for count in (1, 640):
        add(f'insufficient-{count}', duration=count / 16000, group='insufficient')
    for name in ('bl01-vowel-a', 'bl02-consonant-rich', 'bl03-all-voiced'):
        path = f'Tests/HDXLVoiceProcessingTests/Fixtures/Corpus/samples/corpus-{name}.wav'
        _, metadata = read_pcm(ROOT / path)
        add('speech-' + name, kind='licensed-speech', duration=.12,
            rate=metadata['sampleRate'], path=path, startSample=0, group='unknown-speech-truth')
    return rows


def source_samples(case):
    source, profile = case['source'], case['profile']
    rate, count = profile['sampleRate'], source['sampleCount']
    if not 0 < count <= 48000:
        raise ValueError('Reference source exceeds sample budget')
    if source['kind'] == 'licensed-speech':
        path = (ROOT / source['path']).resolve()
        if not path.is_relative_to(ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/Corpus'):
            raise ValueError('Speech source leaves governed corpus')
        samples, metadata = read_pcm(path)
        start = source['startSample']
        if metadata['sampleRate'] != rate or not 0 <= start < start + count <= len(samples):
            raise ValueError('Invalid speech slice')
        samples = samples[start:start + count]
    else:
        state, previous_noise, phase = 38, 0., 0.
        next_pulse, pulse_times = 0., []
        while next_pulse < count / rate:
            pulse_times.append(next_pulse)
            next_pulse += (1 / 137) * (1.25 if len(pulse_times) % 3 == 0 else .85)
        samples = []
        for i in range(count):
            state = (1664525 * state + 1013904223) & 0xffffffff
            noise = (state - 2147483648) / 2147483648
            t, hz = i / rate, source['frequencyHz']
            kind = source['kind']
            if kind == 'chirp': phase = 120 * t + 60 * t * t / (count / rate)
            elif kind == 'vibrato': phase = hz * t + 20 / (math.tau * 5) * (1 - math.cos(math.tau * 5 * t))
            elif kind == 'octave-jump': phase = 120 * min(t, .09) + 240 * max(0, t - .09)
            else: phase = hz * t
            sine = math.sin(math.tau * phase)
            if kind in ('tone', 'chirp', 'vibrato', 'octave-jump'):
                value = source.get('dc', 0.) + source.get('amplitude', .4) * sine
            elif kind == 'harmonic': value = .3 * sine + .12 * math.sin(math.tau * 2 * phase) + .06 * math.sin(math.tau * 3 * phase)
            elif kind == 'missing': value = math.fsum(a * math.sin(math.tau * k * phase) for k, a in ((2, .3), (3, .2), (4, .1), (5, .05)))
            elif kind == 'dominant': value = .005 * sine + .4 * math.sin(math.tau * 2 * phase)
            elif kind == 'snr': value = .4 * sine + math.sqrt(3 / 2) * .4 * 10 ** (-source['snrDB'] / 20) * noise
            elif kind == 'breathy': value = .15 * sine + .25 * (noise - previous_noise)
            elif kind == 'fricative': value = .3 * (noise - previous_noise)
            elif kind == 'noise': value = .3 * noise
            elif kind == 'silence': value = 0.
            elif kind == 'constant': value = .25
            elif kind == 'quantized-global-tie':
                value = float(i in (2, 5, 6, 8, 10, 12, 13))
                if i == 2: value += source['perturbation']
            elif kind in ('offset-tone', 'offset-noise', 'offset-noisy-tone'):
                variation = sine if kind == 'offset-tone' else noise if kind == 'offset-noise' else sine + .2 * noise
                value = source['dc'] + source['amplitude'] * variation
            elif kind == 'irregular-pulses': value = .4 * math.fsum(math.exp(-((t - pulse) / .0004) ** 2) for pulse in pulse_times)
            else: raise ValueError('Unknown original signal')
            samples.append(value)
            previous_noise = noise
    if profile['inputPrecision'] == 'float32':
        samples = [struct.unpack('<f', struct.pack('<f', value))[0] for value in samples]
    if not all(math.isfinite(value) for value in samples):
        raise ValueError('Nonfinite source')
    return samples


def target_hz(case, start_sample, support):
    """Instantaneous source law at observed support midpoint; not a clinical label."""
    source, rate = case['source'], case['profile']['sampleRate']
    kind = source['kind']
    t = (start_sample + support / 2) / rate
    if kind in ('licensed-speech', 'irregular-pulses', 'silence', 'constant', 'noise', 'fricative', 'offset-noise', 'quantized-global-tie'):
        return None
    if kind == 'chirp': return 120 + 120 * t / (source['sampleCount'] / rate)
    if kind == 'vibrato': return source['frequencyHz'] + 20 * math.sin(math.tau * 5 * t)
    if kind == 'octave-jump': return 120. if t < .09 else 240.
    return source['frequencyHz']


def wave64(samples, rate):
    payload = struct.pack(f'<{len(samples)}d', *samples)
    fmt = struct.pack('<HHIIHH', 3, 1, rate, rate * 8, 8, 64)
    chunks = b'fmt ' + struct.pack('<I', 16) + fmt + b'fact' + struct.pack('<II', 4, len(samples))
    chunks += b'data' + struct.pack('<I', len(payload)) + payload
    return b'RIFF' + struct.pack('<I', len(chunks) + 4) + b'WAVE' + chunks
