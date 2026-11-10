"""Original independent oracle for hdxl-swipe-prime-centered-2008 v1.

The discrete contract was committed before this implementation. Uses only
Python's standard library and original scalar equations; never imports Swift,
vDSP, or a third-party SWIPE implementation. See README.md for exact scope.
"""
import cmath
import math

from swipe_math import erb_frequency, erb_rate, harmonic_lobe, is_prime, window_pair

NAME = 'hdxl-swipe-prime-centered-2008'
COMPARISON = {
    'magnitudeAbsolutePerWindowSample': 2e-11,
    'magnitudeRelative': 2e-12,
    'loudnessAbsolute': 2e-7,
    'loudnessRelative': 2e-12,
    'kernelAbsolute': 2e-11,
    'strengthAbsolute': 2e-7,
    'frequencyHzAbsolute': .01,
    'toneMaximumCents': 50.,
    'toneQualityGoalCents': 10.,
    'harmonicMaximumCents': 20.,
    'cleanMinimumVoicedCoverage': .9,
    'grossRelativeHz': .2,
    'octaveRelativeHz': .2,
}


def candidate_grid(floor, ceiling, resolution):
    count = math.ceil(math.log2(ceiling / floor) * resolution)
    interior = [floor * 2. ** (j / resolution) for j in range(count)]
    return [f for f in interior if ceiling - f > 1e-12 * ceiling] + [ceiling]


def configuration(rate=16000, floor=50., ceiling=700., hop=None,
                  resolution=96, precision='float64', threshold=.2, silence=1e-7,
                  partial='emitUnavailable'):
    if type(rate) is not int or not 4000 <= rate <= 192000:
        raise ValueError('Unsupported sample rate')
    if not all(type(x) in (int, float) and math.isfinite(x)
               for x in (floor, ceiling, threshold, silence)):
        raise ValueError('Nonfinite or nonnumeric configuration')
    if not 20 <= floor < ceiling <= rate / 4 or not 0 < threshold < 1 or not 0 <= silence <= 1:
        raise ValueError('Invalid frequency or threshold range')
    if type(resolution) is not int or not 12 <= resolution <= 192:
        raise ValueError('Unsupported candidate resolution')
    grid = candidate_grid(floor, ceiling, resolution)
    if not 3 <= len(grid) <= 2304:
        raise ValueError('Unsupported candidate count')
    lower, upper, fraction = window_pair(rate, grid[0])
    support = upper if fraction else lower
    hop = round(rate / 100) if hop is None else hop
    if support > 131072 or type(hop) is not int or not 1 <= hop <= support:
        raise ValueError('Invalid support or hop')
    if precision not in ('float32', 'float64') or partial not in ('emitUnavailable', 'discard'):
        raise ValueError('Unsupported precision or partial-window policy')
    return {
        'schemaVersion': 1, 'definition': NAME, 'sampleRate': rate,
        'inputPrecision': precision, 'arithmeticPrecision': 'float64',
        'pitchFloorHz': float(floor), 'pitchCeilingHz': float(ceiling),
        'hopLength': hop, 'candidatesPerOctave': resolution,
        'strengthThreshold': float(threshold),
        'silenceRMSThreshold': 0. if silence == 0 else float(silence),
        'partialWindowPolicy': partial,
        'candidateGrid': 'logarithmicWithExactEndpoints',
        'gridEndpointRelativeTolerance': 1e-12,
        'windowPolicy': 'centeredPeriodicHannEightPeriodsLogBlend',
        'erbStep': .1, 'erbMapping': 'glasbergMoore229Hz21Point4',
        'spectrumInterpolation': 'linearMagnitudeThenSquareRoot',
        'kernel': 'firstAndPrimeHarmonicsPositivePartNorm',
        'bandPolicy': 'wholeERBGridThroughNyquistIncludingPartialLobes',
        'normalization': 'observedPeakAndWholeBandLoudnessL2',
        'refinement': 'concavePeriodVertexWithinNeighbors',
        'supportPolicy': 'longestRequiredObservedWindow',
        'selection': 'maximumStrengthLowestFrequencyTie',
    }


def validate(profile):
    if type(profile) is not dict:
        raise ValueError('Expected profile object')
    try:
        rebuilt = configuration(
            rate=profile['sampleRate'], floor=profile['pitchFloorHz'],
            ceiling=profile['pitchCeilingHz'], hop=profile['hopLength'],
            resolution=profile['candidatesPerOctave'], precision=profile['inputPrecision'],
            threshold=profile['strengthThreshold'], silence=profile['silenceRMSThreshold'],
            partial=profile['partialWindowPolicy'])
    except (KeyError, TypeError) as error:
        raise ValueError('Missing or invalid profile fields') from error
    if profile != rebuilt or type(profile.get('schemaVersion')) is not int:
        raise ValueError('Unknown, missing or inconsistent profile fields')


def geometry(profile):
    validate(profile)
    rate = profile['sampleRate']
    frequencies = candidate_grid(profile['pitchFloorHz'], profile['pitchCeilingHz'],
                                 profile['candidatesPerOctave'])
    pairs = [window_pair(rate, frequency) for frequency in frequencies]
    lengths = sorted({length for low, high, weight in pairs
                      for length in ([low, high] if weight else [low])})
    step = profile['erbStep']
    auditory = [erb_frequency(m * step) for m in range(math.floor(erb_rate(rate / 2) / step) + 1)]
    return {'candidateFrequenciesHz': frequencies, 'windowLengths': lengths,
            'requiredSampleCount': lengths[-1], 'erbFrequenciesHz': auditory,
            'candidateWindows': [{'lowerLength': low, 'upperLength': high,
                                  'upperWeight': weight} for low, high, weight in pairs]}


def fft(samples):
    """Original recursive even/odd complex DFT decomposition, unnormalized.

    Independent from the native real-transform backend. Direct DFT and analytic
    spectrum tests anchor exponent sign, scale, endpoint and phase conventions.
    """
    count = len(samples)
    if count == 0 or count & (count - 1):
        raise ValueError('FFT length must be a positive power of two')
    if count == 1:
        return [complex(samples[0])]
    even, odd = fft(samples[::2]), fft(samples[1::2])
    rotated = [cmath.exp(-2j * math.pi * k / count) * odd[k] for k in range(count // 2)]
    return [a + b for a, b in zip(even, rotated)] + [a - b for a, b in zip(even, rotated)]


def linear_magnitude_loudness(magnitude, frequencies, rate, length):
    result = []
    for frequency in frequencies:
        position = frequency * length / rate
        low = min(math.floor(position), len(magnitude) - 1)
        high = min(low + 1, len(magnitude) - 1)
        weight = position - low
        interpolated = (1 - weight) * magnitude[low] + weight * magnitude[high]
        result.append(math.sqrt(interpolated))
    return result


def normalized_kernel(candidate, frequencies):
    # At most two adjacent integer-centered lobes can cover any frequency.
    # Enumerate their first/prime membership independently of native tables.
    harmonics = {1} | {h for h in range(2, math.floor(frequencies[-1] / candidate + .75) + 1)
                      if is_prime(h)}
    values = []
    for frequency in frequencies:
        if frequency == 0:
            values.append(0.)
            continue
        ratio = frequency / candidate
        lower = math.floor(ratio)
        value = math.fsum(harmonic_lobe(ratio, h) for h in (lower, lower + 1)
                          if h in harmonics)
        values.append(value / math.sqrt(frequency))
    norm = math.sqrt(math.fsum(max(0., value) ** 2 for value in values))
    if norm == 0:
        raise ValueError('Candidate kernel has no positive support')
    return [value / norm for value in values]


def refine(frequencies, strengths, index):
    """Three-node Newton polynomial on the period axis; no uniform-grid assumption."""
    frequency, strength = frequencies[index], strengths[index]
    if index == 0 or index + 1 == len(frequencies):
        return frequency, strength, False
    left, right = strengths[index - 1], strengths[index + 1]
    if left is None or right is None or not strength > max(left, right):
        return frequency, strength, False
    # Normalize periods by the center period to avoid poor conditioning from
    # milliseconds; the parabola's vertex is unchanged by this affine scale.
    x0, x1, x2 = frequency / frequencies[index - 1], 1., frequency / frequencies[index + 1]
    first = (strength - left) / (x1 - x0)
    second = ((right - strength) / (x2 - x1) - first) / (x2 - x0)
    if not second < 0:
        return frequency, strength, False
    vertex = (x0 + x1 - first / second) / 2
    if not math.isfinite(vertex) or not x2 <= vertex <= x0:
        return frequency, strength, False
    refined = left + (vertex - x0) * (first + (vertex - x1) * second)
    if not math.isfinite(refined):
        return frequency, strength, False
    return frequency / vertex, refined, True


class PreparedOracle:
    """Cached mathematical geometry, independent of frame count or native output."""

    def __init__(self, profile):
        self.layout = geometry(profile)
        self.profile = dict(profile)
        self.kernels = [normalized_kernel(f, self.layout['erbFrequenciesHz'])
                        for f in self.layout['candidateFrequenciesHz']]

    def frame(self, samples):
        support = self.layout['requiredSampleCount']
        if len(samples) > support or any(type(x) not in (int, float) or not math.isfinite(x)
                                         for x in samples):
            raise ValueError('Invalid frame PCM')
        row = {'observedSampleCount': len(samples), 'requiredSampleCount': support,
               'windows': [], 'candidateStrengths': [], 'selectedCandidateIndex': None,
               'frequencyHz': None, 'pitchStrength': None, 'discretePitchStrength': None,
               'isRefined': False, 'status': 'unavailable', 'reason': 'insufficientData',
               'normalizationPeak': None, 'rms': None}
        if len(samples) < support:
            return row
        peak = max(map(abs, samples))
        scaled = [x / peak for x in samples] if peak else [0.] * support
        rms = peak * min(1., math.sqrt(math.fsum(x * x for x in scaled) / support))
        loudness_by_length = {}
        for length in self.layout['windowLengths']:
            start = (support - length) // 2
            windowed = [scaled[start + j] * (.5 - .5 * math.cos(2 * math.pi * j / length))
                        for j in range(length)]
            magnitude = [abs(z) for z in fft(windowed)[:length // 2 + 1]]
            loudness = linear_magnitude_loudness(
                magnitude, self.layout['erbFrequenciesHz'], self.profile['sampleRate'], length)
            norm = math.sqrt(math.fsum(x * x for x in loudness))
            loudness_by_length[length] = [x / norm for x in loudness] if norm else None
            row['windows'].append({'length': length, 'offset': start,
                                   'magnitude': magnitude, 'loudness': loudness})
        strengths, window_strengths = [], {n: [] for n in self.layout['windowLengths']}
        for index, (kernel, pair) in enumerate(zip(self.kernels, self.layout['candidateWindows'])):
            def score(length):
                normalized = loudness_by_length[length]
                value = (math.fsum(x * y for x, y in zip(kernel, normalized))
                         if normalized is not None else None)
                window_strengths[length].append({'candidateIndex': index, 'strength': value})
                return value
            low = score(pair['lowerLength'])
            weight = pair['upperWeight']
            if weight:
                high = score(pair['upperLength'])
                combined = (1 - weight) * low + weight * high if low is not None and high is not None else None
            else:
                combined = low
            strengths.append(combined)
        for window in row['windows']:
            window['strengths'] = window_strengths[window['length']]
        selected = max((i for i, x in enumerate(strengths) if x is not None),
                       key=lambda i: (strengths[i], -i), default=None)
        frequency = strength = discrete = None
        refined = False
        status, reason = 'unavailable', 'numericalFailure'
        if rms <= self.profile['silenceRMSThreshold']:
            status, reason, selected = 'unvoiced', 'silence', None
        elif max(samples) == min(samples):
            status, reason, selected = 'unvoiced', 'lowConfidence', None
        elif selected is not None:
            frequency, strength, refined = refine(self.layout['candidateFrequenciesHz'], strengths, selected)
            discrete = strengths[selected]
            status = 'voiced' if strength >= self.profile['strengthThreshold'] else 'uncertain'
            reason = None if status == 'voiced' else 'lowConfidence'
        row.update(candidateStrengths=strengths, selectedCandidateIndex=selected,
                   frequencyHz=frequency, pitchStrength=strength, discretePitchStrength=discrete,
                   isRefined=refined, status=status, reason=reason,
                   normalizationPeak=peak, rms=rms)
        return row

    def stream(self, samples):
        if any(type(x) not in (int, float) or not math.isfinite(x) for x in samples):
            raise ValueError('Invalid stream PCM, including discarded tails')
        support = self.layout['requiredSampleCount']
        rows, start = [], 0
        while start + support <= len(samples):
            rows.append({'frameIndex': len(rows), 'startSample': start,
                         **self.frame(samples[start:start + support])})
            start += self.profile['hopLength']
        if start < len(samples) and self.profile['partialWindowPolicy'] == 'emitUnavailable':
            rows.append({'frameIndex': len(rows), 'startSample': start, **self.frame(samples[start:])})
        return rows
