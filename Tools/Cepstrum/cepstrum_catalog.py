"""Original cepstral reference cases and explicit numerical stage definitions."""
import math
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools/Reference'))
from common import read_pcm


STAGES = {
    'windowed': {'xUnit': 'seconds', 'yUnit': 'normalizedAmplitude',
                 'definition': 'Whole-interval resample; fused raw one-zero pre-emphasis; observed frame mean removal; unnormalized Gaussian2; explicit transform padding.'},
    'spectrumReal': {'xUnit': 'hertz', 'yUnit': 'normalizedAmplitudeSeconds',
                     'definition': 'dt times the unnormalized negative-exponent DFT, real component; one-sided including DC/Nyquist.'},
    'spectrumImaginary': {'xUnit': 'hertz', 'yUnit': 'normalizedAmplitudeSeconds',
                          'definition': 'dt times the unnormalized negative-exponent DFT, imaginary component; endpoint imaginary values zero.'},
    'powerSpectrum': {'xUnit': 'hertz', 'yUnit': 'normalizedSquaredAmplitudeSecondsSquared',
                      'definition': '2 * (real^2 + imaginary^2), including both endpoints; no window gain correction.'},
    'logPowerSpectrum': {'xUnit': 'hertz', 'yUnit': 'dimensionless',
                         'definition': 'Natural log relative to one normalized-amplitude-squared second-squared; additive 1e-300 except no additive term at Nyquist.'},
    'signedCepstrum': {'xUnit': 'seconds', 'yUnit': 'inverseSeconds',
                       'definition': 'fs times the 1/N inverse real DFT of the even real log-power spectrum; first N/2+1 samples.'},
    'powerCepstrum': {'xUnit': 'seconds', 'yUnit': 'inverseSecondsSquared',
                      'definition': 'Square signed cepstrum; linear power, not dB. q[k]=k/fs including q=0.'},
}

# Calibrated numerical verification budgets, not clinical acceptability thresholds.
# Classify conditioning using only the independent reference log range. Thirty-two
# natural-log units are about 139 dB of power range; FFT/resampler roundoff near these
# minima is amplified by the logarithm. Ordinary speech keeps separate tight bounds.
# Power-cepstrum limits are derived from the signed limit: e*(2*sqrt(expected)+e),
# with eight binary64 ulps of relative squared-output allowance.
COMPARISON = {
    'schemaVersion': 1, 'arithmeticPrecision': 'float64',
    'deepMinimumLogRange': 32.0,
    'normalization': 'Frame route uses max(abs(reference conditioned frame)); interval route uses max(that, whole-source PCM peak), because whole-input filtering can carry roundoff into a quiet frame. Window/spectrum divide once; power divides twice; zero scale uses one.',
    'frame': {'windowed': 2e-14, 'spectrum': 2e-16, 'powerSpectrum': 2e-18,
              'ordinaryLog': 2e-8, 'ordinarySigned': 2e-6,
              'deepLog': .02, 'deepSigned': .002},
    'interval': {'windowed': 2e-11, 'spectrum': 2e-13, 'powerSpectrum': 2e-15,
                 'ordinaryLog': 2e-7, 'ordinarySigned': 2e-5,
                 'deepLog': .02, 'deepSigned': .5},
    'powerRoundingRelative': 8 * 2.220446049250313e-16,
}


def cases():
    result = []
    def add(name, source, **changes):
        result.append({'name': name, 'source': source, 'inputPrecision': 'float64',
                       'pitchFloorHz': 60.0, 'hopSeconds': .002,
                       'maximumFrequencyHz': 5000.0, 'preEmphasisFromHz': 50.0,
                       **changes})
    for name in ('silence', 'regular-pulses', 'harmonic-low', 'harmonic-high',
                 'missing-fundamental', 'dominant-upper', 'inharmonic',
                 'vowel-low', 'vowel-high', 'noise-seed-zero', 'noise-seed-seven',
                 'noise-mixture-0db', 'noise-mixture-20db'):
        add('synthetic-' + name, {'path': f'Tests/HDXLVoiceProcessingTests/Fixtures/Synthetic/{name}.wav'})
    for name in ('bl01-vowel-a', 'bl01-consonant-rich', 'bl02-vowel-i',
                 'bl02-consonant-rich', 'bl03-vowel-a', 'bl03-all-voiced',
                 'bl01-noisy', 'bl01-dropout'):
        add('speech-' + name, {'path': f'Tests/HDXLVoiceProcessingTests/Fixtures/Corpus/samples/corpus-{name}.wav'})
    for rate in (10000, 16000, 44100, 48000):
        add(f'equivalent-harmonics-{rate}', {'kind': 'harmonics', 'rate': rate,
            'count': rate * 3 // 25, 'fundamentalHz': 125.0, 'gain': 1.0})
    for count in (1000, 1001, 1100, 1101):
        add(f'grid-{count}', {'kind': 'noise', 'rate': 10000, 'count': count, 'gain': 1.0})
    add('impulse', {'kind': 'impulse', 'rate': 10000, 'count': 1200, 'gain': 1.0})
    add('dc', {'kind': 'dc', 'rate': 10000, 'count': 1200, 'gain': 1.0})
    for gain in (.5, 2., 1e-140, 1e-160):
        add(f'noise-gain-{gain}', {'kind': 'noise', 'rate': 16000, 'count': 1920, 'gain': gain})
    for hop in (.005, .010):
        add(f'reference-hop-{hop}', {'kind': 'noise', 'rate': 16000, 'count': 3200, 'gain': 1.0}, hopSeconds=hop)
    add('floor-40', {'kind': 'noise', 'rate': 16000, 'count': 3200, 'gain': 1.0}, pitchFloorHz=40.0)
    add('floor-100', {'kind': 'noise', 'rate': 16000, 'count': 3200, 'gain': 1.0}, pitchFloorHz=100.0)
    for kind in ('noise', 'harmonics'):
        add(f'float32-input-{kind}', {'kind': kind, 'rate': 16000, 'count': 1920,
            'gain': 1.0, **({'fundamentalHz': 125.0} if kind == 'harmonics' else {})}, inputPrecision='float32')
    return result


def source_samples(case):
    recipe = case['source']
    if 'path' in recipe:
        path = (ROOT / recipe['path']).resolve()
        if not path.is_relative_to(ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures'):
            raise ValueError('Reference input outside committed fixture tree')
        values, record = read_pcm(path)
        rate = record['sampleRate']
    else:
        rate, count, kind = recipe['rate'], recipe['count'], recipe['kind']
        values = []
        state = 33
        for i in range(count):
            if kind == 'noise':
                state = (1664525 * state + 1013904223) & 0xffffffff
                value = (state - 2147483648) / 8589934592
            elif kind == 'harmonics':
                value = math.fsum(.1 / k * math.sin(math.tau * recipe['fundamentalHz'] * k * i / rate + .13)
                                  for k in range(1, 16))
            elif kind == 'impulse': value = .5 if i == count // 2 else 0.
            elif kind == 'dc': value = .25
            else: raise ValueError('Unknown original source equation')
            values.append(value * recipe['gain'])
    if case['inputPrecision'] == 'float32':
        values = [struct.unpack('<f', struct.pack('<f', x))[0] for x in values]
    elif case['inputPrecision'] != 'float64':
        raise ValueError('Unknown input precision')
    if not values or not all(math.isfinite(x) for x in values):
        raise ValueError('Expected nonempty finite reference input')
    return values, rate


def float64_wave(values, rate):
    """Lossless finite Float64 RIFF, allowing conditioned samples beyond full scale."""
    if type(rate) is not int or not 1000 <= rate <= 192000 or not values or len(values) > 2_880_000:
        raise ValueError('Invalid WAVE geometry')
    if not all(math.isfinite(v) for v in values):
        raise ValueError('Nonfinite WAVE sample')
    payload = struct.pack(f'<{len(values)}d', *values)
    fmt = struct.pack('<HHIIHH', 3, 1, rate, rate * 8, 8, 64)
    chunks = b'fmt ' + struct.pack('<I', len(fmt)) + fmt
    chunks += b'fact' + struct.pack('<II', 4, len(values))
    chunks += b'data' + struct.pack('<I', len(payload)) + payload
    return b'RIFF' + struct.pack('<I', len(chunks) + 4) + b'WAVE' + chunks


def prepared_frame(resampled, first_center, case, center):
    rate = int(2 * case['maximumFrequencyHz'])
    dt = 1 / rate
    width = 2 * (3 / case['pitchFloorHz'])
    count = math.floor(width / dt + .5)
    first = math.floor(((center - width / 2) - first_center) / dt + 1 + .5) - 1
    a = math.exp(-math.tau * case['preEmphasisFromHz'] * dt)
    values = []
    for i in range(first, first + count):
        value = (math.fma(-a, resampled[i - 1], resampled[i]) if i else resampled[i]) if 0 <= i < len(resampled) else 0.
        values.append(value)
    mean = math.fsum(values) / count
    window = [(math.exp(-12 * ((2 * i + 1 - count) / count)**2) - math.exp(-12))
              / (1 - math.exp(-12)) for i in range(count)]
    windowed = [(value - mean) * coefficient for value, coefficient in zip(values, window)]
    fft_count = max(2, 1 << (count - 1).bit_length())
    return {'firstResampledIndex': first, 'observedFrameCount': count,
            'transformLength': fft_count, 'frameMean': mean,
            'conditioned': values, 'windowed': windowed + [0.] * (fft_count - count)}
