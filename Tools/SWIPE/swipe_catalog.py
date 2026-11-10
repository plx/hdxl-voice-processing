"""Bounded original SWIPE-prime inputs and existing governed corpus slices."""
import math
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(1, str(ROOT / 'Tools/Reference'))
from common import read_pcm
from swipe_oracle import configuration, geometry


def cases():
    rows = []

    def add(name, kind='tone', frequency=123.45, group='characterization', rate=16000,
            floor=50., ceiling=700., hop=.01, resolution=96, precision='float64',
            threshold=.2, silence=1e-7, full_frames=3, count=None, **source_options):
        profile = configuration(rate=rate, floor=floor, ceiling=ceiling,
                                hop=math.floor(rate * hop + .5), resolution=resolution,
                                precision=precision, threshold=threshold, silence=silence)
        support = geometry(profile)['requiredSampleCount']
        count = support + (full_frames - 1) * profile['hopLength'] if count is None else count
        rows.append({'name': name, 'profile': profile, 'acceptanceGroup': group,
                     'source': {'kind': kind, 'frequencyHz': frequency,
                                'sampleCount': count, **source_options}})

    for frequency in (80., 123.45, 190., 250., 440., 650.):
        add(f'tone-{frequency:g}', frequency=frequency, group='clean-tone')
    # Retain the unfavorable preflight examples, not only convenient clean tones.
    add('tone-bias-16000', frequency=106.9234599991188, floor=25., ceiling=2000., group='clean-tone')
    add('tone-bias-44100', frequency=165.05444239489884, rate=44100, group='clean-tone')
    for kind in ('harmonic', 'sawtooth', 'missing-fundamental'):
        add(kind, kind=kind, group='clean-harmonic')
    for kind in ('dominant-second', 'dominant-fifth', 'inharmonic', 'two-tone',
                 'breathy', 'fricative', 'noise'):
        add(kind, kind=kind)
    for snr in (20, 10, 0, -10):
        add(f'snr-{snr}', kind='snr', snrDB=snr)
    for kind in ('silence', 'constant'):
        add(kind, kind=kind, group='no-pitch')
    for kind in ('chirp', 'vibrato', 'octave-jump'):
        add(kind, kind=kind, full_frames=30)
    add('dc-offset', kind='offset-tone', amplitude=1e-4, dc=.5)
    add('tiny-signal', amplitude=1e-100, silence=0, group='clean-tone')
    add('huge-signal', amplitude=1e300, group='clean-tone')
    add('below-silence-threshold', amplitude=1e-9, group='no-pitch')
    add('strict-strength-threshold', threshold=.99)
    add('float32-tone', precision='float32', group='clean-tone')
    add('float32-missing', kind='missing-fundamental', precision='float32', group='clean-harmonic')
    add('float32-breathy', kind='breathy', precision='float32')
    for frequency in (49.9, 50., 50.1, 699.9, 700., 700.1):
        add(f'range-boundary-{frequency:g}', frequency=frequency)
    for floor in (249.999, 250., 250.001):
        add(f'window-boundary-{floor:g}', floor=floor, ceiling=500., frequency=330., group='clean-tone')
    for rate in (16000, 44100, 48000):
        for hop in (.005, .01, .02):
            for floor, ceiling, frequency in ((50., 700., 137.), (25., 2000., 73.7)):
                add(f'grid-{rate}-{hop:g}-{floor:g}', rate=rate, floor=floor,
                    ceiling=ceiling, frequency=frequency, hop=hop, group='clean-tone')
    for floor, ceiling in ((50., 700.), (25., 2000.)):
        add(f'float32-grid-{floor:g}', rate=48000, floor=floor, ceiling=ceiling,
            precision='float32', group='clean-tone')
    for resolution in (12, 192):
        add(f'resolution-{resolution}', resolution=resolution, group='clean-tone')
    add('insufficient-one', count=1, group='insufficient')
    add('insufficient-before-full', count=4095, group='insufficient')
    for name in ('bl01-vowel-a', 'bl02-consonant-rich', 'bl03-all-voiced'):
        path = f'Tests/HDXLVoiceProcessingTests/Fixtures/Corpus/samples/corpus-{name}.wav'
        _, metadata = read_pcm(ROOT / path)
        add('speech-' + name, kind='licensed-speech', rate=metadata['sampleRate'],
            path=path, startSample=0, group='unknown-speech-truth', full_frames=6)
    if len({case['name'] for case in rows}) != len(rows):
        raise ValueError('Duplicate case names')
    return rows


def source_samples(case):
    source, profile = case['source'], case['profile']
    rate, count, kind = profile['sampleRate'], source['sampleCount'], source['kind']
    if type(count) is not int or not 0 < count <= 131072:
        raise ValueError('Reference source exceeds bounded sample budget')
    if kind == 'licensed-speech':
        path = (ROOT / source['path']).resolve()
        if not path.is_relative_to((ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/Corpus').resolve()):
            raise ValueError('Speech source leaves governed corpus')
        samples, metadata = read_pcm(path)
        start = source['startSample']
        if metadata['sampleRate'] != rate or not 0 <= start < start + count <= len(samples):
            raise ValueError('Invalid governed speech slice')
        samples = samples[start:start + count]
    else:
        state, previous_noise, samples = 4408, 0., []
        duration, frequency = count / rate, source['frequencyHz']
        for j in range(count):
            state = (1664525 * state + 1013904223) & 0xffffffff
            noise = (state - 2147483648) / 2147483648
            time = j / rate
            if kind == 'chirp':
                phase = 120 * time + 60 * time * time / duration
            elif kind == 'vibrato':
                phase = frequency * time + 20 / (math.tau * 5) * (1 - math.cos(math.tau * 5 * time))
            elif kind == 'octave-jump':
                phase = 120 * min(time, duration / 2) + 240 * max(0, time - duration / 2)
            else:
                phase = frequency * time
            sine = math.sin(math.tau * phase)
            if kind in ('tone', 'chirp', 'vibrato', 'octave-jump', 'offset-tone'):
                value = source.get('dc', 0.) + source.get('amplitude', .4) * sine
            elif kind in ('harmonic', 'sawtooth', 'missing-fundamental'):
                first = 2 if kind == 'missing-fundamental' else 1
                last = 32 if kind == 'sawtooth' else 15
                harmonics = [h for h in range(first, last + 1) if h * frequency < rate / 2]
                value = .3 * math.fsum(math.sin(math.tau * h * phase) / h for h in harmonics)
            elif kind == 'dominant-second':
                value = .005 * sine + .4 * math.sin(math.tau * 2 * phase)
            elif kind == 'dominant-fifth':
                value = .01 * sine + .03 * math.sin(math.tau * 2 * phase) + .4 * math.sin(math.tau * 5 * phase)
            elif kind == 'inharmonic':
                value = math.fsum(.3 / h * math.sin(math.tau * phase * h * math.sqrt(1 + .015 * h * h))
                                  for h in range(1, 8))
            elif kind == 'two-tone':
                value = .3 * sine + .3 * math.sin(math.tau * frequency * math.sqrt(2) * time)
            elif kind == 'snr':
                value = .4 * sine + math.sqrt(3 / 2) * .4 * 10 ** (-source['snrDB'] / 20) * noise
            elif kind == 'breathy':
                value = .15 * sine + .25 * (noise - previous_noise)
            elif kind == 'fricative':
                value = .3 * (noise - previous_noise)
            elif kind == 'noise':
                value = .3 * noise
            elif kind == 'silence':
                value = 0.
            elif kind == 'constant':
                value = .25
            else:
                raise ValueError('Unknown original source kind')
            samples.append(value)
            previous_noise = noise
    if profile['inputPrecision'] == 'float32':
        samples = [struct.unpack('<f', struct.pack('<f', x))[0] for x in samples]
    if not all(math.isfinite(x) for x in samples):
        raise ValueError('Nonfinite source')
    return samples


def target_hz(case, start, support):
    """Known source law at observed midpoint; mixed jump support has no single truth."""
    source, rate = case['source'], case['profile']['sampleRate']
    kind = source['kind']
    if kind in ('licensed-speech', 'inharmonic', 'two-tone', 'silence', 'constant', 'noise', 'fricative'):
        return None
    midpoint = (start + support / 2) / rate
    duration = source['sampleCount'] / rate
    if kind == 'chirp':
        return 120 + 120 * midpoint / duration
    if kind == 'vibrato':
        return source['frequencyHz'] + 20 * math.sin(math.tau * 5 * midpoint)
    if kind == 'octave-jump':
        boundary = source['sampleCount'] / 2
        if start < boundary < start + support:
            return None
        return 120. if start + support <= boundary else 240.
    return source['frequencyHz']


def wave64(samples, rate):
    """Lossless original PCM container, including the floating-WAVE fact chunk."""
    payload = struct.pack(f'<{len(samples)}d', *samples)
    fmt = struct.pack('<HHIIHH', 3, 1, rate, rate * 8, 8, 64)
    chunks = b'fmt ' + struct.pack('<I', 16) + fmt + b'fact' + struct.pack('<II', 4, len(samples))
    chunks += b'data' + struct.pack('<I', len(payload)) + payload
    return b'RIFF' + struct.pack('<I', len(chunks) + 4) + b'WAVE' + chunks
