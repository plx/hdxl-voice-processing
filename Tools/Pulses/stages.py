"""Original 80-digit equations for bounded pulse-search stages, not a tracker.

The oracle forms complete observed sample pairs and fits an explicit quadratic.
It neither runs the native implementation nor reproduces its optimized loops.
"""
from decimal import Decimal, localcontext
import math
import struct

from reference import finite, validate_pitch

DECIMAL_PRECISION = 80
MAX_STAGE_SAMPLES = 4096


def rounded_pcm(samples, precision):
    if precision not in ('float32', 'float64') or not isinstance(samples, list):
        raise ValueError('Unknown stage input precision/shape')
    if not 1 <= len(samples) <= MAX_STAGE_SAMPLES or not all(finite(x) and abs(x) <= 1 for x in samples):
        raise ValueError('Stage PCM must be bounded finite normalized samples')
    values = list(map(float, samples))
    if precision == 'float32':
        values = list(struct.unpack(f'<{len(values)}f', struct.pack(f'<{len(values)}f', *values)))
    return values


def observed_correlation(samples, anchor_first, anchor_last, candidate_first, *, precision='float64'):
    """Cosine of two observed vectors; missing pairs are absent, never zero padded."""
    values = rounded_pcm(samples, precision)
    indices = (anchor_first, anchor_last, candidate_first)
    if any(type(i) is not int or abs(i) > 2 * MAX_STAGE_SAMPLES for i in indices):
        raise ValueError('Unbounded/noninteger stage indices')
    if not 1 <= anchor_last - anchor_first + 1 <= MAX_STAGE_SAMPLES:
        raise ValueError('Invalid stage window')
    shift = candidate_first - anchor_first
    observed = range(max(anchor_first, 0, -shift), min(anchor_last + 1, len(values), len(values) - shift))
    pairs = [(Decimal.from_float(values[i]), Decimal.from_float(values[i + shift])) for i in observed]
    with localcontext() as context:
        context.prec = DECIMAL_PRECISION
        aa = sum((a * a for a, _ in pairs), Decimal(0))
        bb = sum((b * b for _, b in pairs), Decimal(0))
        ab = sum((a * b for a, b in pairs), Decimal(0))
        silent = aa == 0 or bb == 0
        correlation = Decimal(0) if silent else ab / (aa * bb).sqrt()
        varying_a = len({a for a, _ in pairs}) > 1
        varying_b = len({b for _, b in pairs}) > 1
        status = ('noObservedPairs' if not pairs else 'silent' if silent else
                  'tooFewPairs' if len(pairs) < 3 else 'constantSupport' if not (varying_a and varying_b)
                  else 'varyingSupport')
        return {'correlation': float(correlation), 'observedPairCount': len(pairs),
                'anchorFirstObservedIndex': observed.start if pairs else None,
                'anchorLastObservedIndex': observed.stop - 1 if pairs else None,
                'candidatePeak': max((abs(float(b)) for _, b in pairs), default=0.),
                'supportStatus': status,
                'exactInputEnergyDecimal': {'anchor': str(aa), 'candidate': str(bb), 'dot': str(ab)}}


def quadratic_vertex(left, middle, right):
    """Interpolate a local extremum with Lagrange coefficients at x=-1,0,1."""
    if not all(finite(x) for x in (left, middle, right)):
        raise ValueError('Nonfinite quadratic values')
    with localcontext() as context:
        context.prec = DECIMAL_PRECISION
        values = tuple(Decimal.from_float(float(x)) for x in (left, middle, right))
        return _decimal_vertex(*values)


def _decimal_vertex(left, middle, right):
    a = (left + right) / 2 - middle
    b = (right - left) / 2
    if not math.isfinite(float(-2 * a)):
        raise ValueError('Quadratic curvature exceeds finite binary64 output')
    if a == 0:
        return {'status': 'flat' if b == 0 else 'notLocalExtremum',
                'offsetSamples': None, 'value': None, 'curvature': float(-2 * a)}
    if not (middle >= max(left, right) or middle <= min(left, right)):
        return {'status': 'notLocalExtremum', 'offsetSamples': None, 'value': None, 'curvature': float(-2 * a)}
    offset, value = -b / (2 * a), middle - b * b / (4 * a)
    if not all(math.isfinite(float(x)) for x in (offset, value, -2 * a)):
        raise ValueError('Quadratic result exceeds finite binary64 output')
    return {'status': 'maximum' if a < 0 else 'minimum', 'offsetSamples': float(offset),
            'value': float(value), 'curvature': float(-2 * a)}


def correlation_curve(samples, anchor_first, anchor_last, candidate_first, candidate_last, *, precision='float64'):
    """Materialize an independent lag table instead of sharing tracker state."""
    if type(candidate_first) is not int or type(candidate_last) is not int or not 1 <= candidate_last - candidate_first + 1 <= 1024:
        raise ValueError('Invalid candidate-lag budget')
    return [{'candidateFirstIndex': first,
             **observed_correlation(samples, anchor_first, anchor_last, first, precision=precision)}
            for first in range(candidate_first, candidate_last + 1)]


def select_correlation_peak(curve):
    """Pinned finite-table policy, expressed as a set of eligible local maxima.

    Two preceding correlation sentinels are zero. The last evaluated lag is
    only a right neighbor. The amplitude gate uses that right neighbor's peak.
    These are reference conventions, not zero padding of missing PCM samples.
    """
    if not isinstance(curve, list) or not 1 <= len(curve) <= 1024:
        raise ValueError('Invalid correlation curve')
    for i, row in enumerate(curve):
        if not isinstance(row, dict) or type(row.get('candidateFirstIndex')) is not int:
            raise ValueError('Missing candidate lag identity')
        if i and row['candidateFirstIndex'] != curve[i - 1]['candidateFirstIndex'] + 1:
            raise ValueError('Missing/reordered candidate lag')
        if not finite(row.get('correlation')) or abs(row['correlation']) > 1 + 1e-12:
            raise ValueError('Invalid normalized correlation')
        if not finite(row.get('candidatePeak')) or not 0 <= row['candidatePeak'] <= 1:
            raise ValueError('Invalid candidate amplitude')
    first = curve[0]['candidateFirstIndex']
    values = [0., 0.] + [row['correlation'] for row in curve]
    candidates = [(values[i + 1], first + i - 1, i)
                  for i in range(len(curve))
                  if values[i + 1] > -1 and values[i + 1] >= max(values[i], values[i + 2])]
    if not candidates:
        return {'status': 'noLocalMaximum', 'candidateFirstIndex': None}
    height, index, i = max(candidates, key=lambda candidate: (candidate[0], -candidate[1]))
    vertex = quadratic_vertex(values[i], values[i + 1], values[i + 2])
    offset = vertex['offsetSamples'] if vertex['status'] == 'maximum' else 0.
    return {'status': 'selected', 'candidateFirstIndex': index,
            'fractionalCandidateFirstIndex': index + offset, 'offsetSamples': offset,
            'sampledCorrelation': height,
            'interpolatedCorrelation': vertex['value'] if vertex['status'] == 'maximum' else height,
            'curvature': vertex['curvature'], 'leftCorrelation': values[i],
            'rightCorrelation': values[i + 2], 'amplitudeGatePeak': curve[i]['candidatePeak'],
            'amplitudeGateCandidateFirstIndex': curve[i]['candidateFirstIndex'],
            'syntheticPrecedingCandidate': index < first}


def sampled_indices(time, first, step):
    """Pinned binary64 axis operation order; return zero-based floor/ceil/nearest."""
    if not all(finite(x) for x in (time, first, step)) or step <= 0:
        raise ValueError('Invalid sampled axis')
    # The one-based coordinate is part of the reference interchange convention.
    coordinate = (time - first) / step + 1
    if not math.isfinite(coordinate) or abs(coordinate) > 1_000_000_000:
        raise ValueError('Unbounded sampled coordinate')
    return {'low': math.floor(coordinate) - 1, 'high': math.ceil(coordinate) - 1,
            'nearest': math.floor(coordinate + .5) - 1, 'coordinateOneBased': coordinate}


def sampled_f0(pitch, time, rate, count):
    """Nearest voiced support plus linear frequency weights; no gap interpolation."""
    validate_pitch(pitch, rate, count)
    if not finite(time):
        raise ValueError('Nonfinite F0 query')
    if not 0 <= time <= pitch['domainEndSeconds']:
        return None
    axis = sampled_indices(time, pitch['firstCenterSeconds'], pitch['stepSeconds'])
    values = pitch['frequenciesHz']
    # Interpolated F0 compares the fractional part before integer conversion;
    # adding 0.5 first can round a value immediately below a boundary onto it.
    fraction = axis['coordinateOneBased'] - math.floor(axis['coordinateOneBased'])
    nearest = axis['low'] + int(fraction >= .5)
    if not 0 <= nearest < len(values) or values[nearest] == 0:
        return None
    position = axis['coordinateOneBased'] - 1
    neighbor = nearest + (1 if position >= nearest else -1)
    if not 0 <= neighbor < len(values) or values[neighbor] == 0:
        return values[nearest]
    with localcontext() as context:
        context.prec = DECIMAL_PRECISION
        weight = Decimal.from_float(abs(position - nearest))
        near = Decimal.from_float(float(values[nearest]))
        far = Decimal.from_float(float(values[neighbor]))
        return float((1 - weight) * near + weight * far)


def gaussian_parabolic_bias(sigma_samples, fractional_offset, *, correlation=True):
    """Closed-form continuous Gaussian peak/correlation; finite sampling is separate."""
    if not finite(sigma_samples) or not .5 <= sigma_samples <= 256:
        raise ValueError('Unsupported Gaussian width')
    if not finite(fractional_offset) or not -.5 <= fractional_offset <= .5 or type(correlation) is not bool:
        raise ValueError('Invalid fractional delay/route')
    with localcontext() as context:
        context.prec = DECIMAL_PRECISION
        sigma, fraction = (Decimal.from_float(float(x)) for x in (sigma_samples, fractional_offset))
        divisor = (4 if correlation else 2) * sigma * sigma
        y = [(-((Decimal(i) - fraction) ** 2) / divisor).exp() for i in (-1, 0, 1)]
        fit = _decimal_vertex(*y)
        # Keep subtraction at high precision rather than subtracting rounded outputs.
        a, b = (y[0] + y[2]) / 2 - y[1], (y[2] - y[0]) / 2
        bias = -b / (2 * a) - fraction
        return {'definition': 'continuousGaussianCorrelation' if correlation else 'continuousGaussianPeak',
                'sigmaSamples': sigma_samples, 'fractionalOffsetSamples': fractional_offset,
                'interpolatedOffsetSamples': fit['offsetSamples'], 'signedBiasSamples': float(bias),
                'curvature': fit['curvature']}
