"""Independent high-precision supplied-amplitude shimmer equations.

The public definitions provide the six statistics. Original black-box queries of
the pinned executable establish its normalization population and boundaries.
No external implementation source is used. Eligibility uses binary64 timestamps
and ratios; accepted algebra uses exact rationals, with 100-digit logarithms.
"""
from decimal import Decimal, localcontext
from fractions import Fraction
import math

INPUT_KEYS = {'schemaVersion', 'name', 'timesSeconds', 'amplitudes',
              'domainStartSeconds', 'domainEndSeconds', 'queryStartSeconds',
              'queryEndSeconds', 'minimumPeriodSeconds', 'maximumPeriodSeconds',
              'maximumAmplitudeFactor'}
MEASUREMENTS = ('local', 'db', 'apq3', 'apq5', 'apq11', 'dda')


def finite(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def validate(case):
    if not isinstance(case, dict) or set(case) != INPUT_KEYS:
        raise ValueError('Unexpected shimmer input schema')
    if type(case['schemaVersion']) is not int or case['schemaVersion'] != 1:
        raise ValueError('Unsupported shimmer schema version')
    name = case['name']
    if not isinstance(name, str) or not 1 <= len(name) <= 100 or any(
            c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in name):
        raise ValueError('Invalid shimmer case name')
    metadata = INPUT_KEYS - {'schemaVersion', 'name', 'timesSeconds', 'amplitudes'}
    if not all(finite(case[key]) for key in metadata):
        raise ValueError('Nonfinite shimmer metadata')
    a, b = case['domainStartSeconds'], case['domainEndSeconds']
    if not 0 <= a < b <= 60 or not a <= case['queryStartSeconds'] < case['queryEndSeconds'] <= b:
        raise ValueError('Invalid shimmer time bounds')
    lo, hi = case['minimumPeriodSeconds'], case['maximumPeriodSeconds']
    if not 0 < lo < hi <= .1 or not 1 <= case['maximumAmplitudeFactor'] <= 10:
        raise ValueError('Invalid shimmer period/amplitude settings')
    times, values = case['timesSeconds'], case['amplitudes']
    if not isinstance(times, list) or not isinstance(values, list) or len(times) != len(values) or len(times) > 30000:
        raise ValueError('Invalid shimmer amplitude records')
    if not all(finite(t) and a <= t <= b for t in times):
        raise ValueError('Invalid shimmer times')
    if any(float(y) - float(x) < 1e-12 for x, y in zip(times, times[1:])):
        raise ValueError('Shimmer times must increase by at least the fixture separation bound')
    # Development interchange bounds, not a declaration of runtime PCM range.
    if not all(finite(v) and (v == 0 or 1e-150 <= v <= 1e150) for v in values):
        raise ValueError('Invalid or unsupported shimmer amplitude')


def selected_indices(case):
    validate(case)
    return [i for i, t in enumerate(case['timesSeconds'])
            if case['queryStartSeconds'] <= t <= case['queryEndSeconds']]


def evaluate(case):
    indices = selected_indices(case)
    times = [float(case['timesSeconds'][i]) for i in indices]
    amplitudes = [float(case['amplitudes'][i]) for i in indices]
    edges = []
    lo, hi, factor = (case[k] for k in ('minimumPeriodSeconds', 'maximumPeriodSeconds',
                                       'maximumAmplitudeFactor'))
    for i in range(max(0, len(indices) - 1)):
        period = times[i + 1] - times[i]
        a, b = amplitudes[i:i + 2]
        ratio = max(a, b) / min(a, b) if a > 0 and b > 0 else None
        reasons = []
        if period < lo: reasons.append('periodBelowMinimum')
        if period > hi: reasons.append('periodAboveMaximum')
        if ratio is None: reasons.append('zeroAmplitude')
        elif ratio > factor: reasons.append('amplitudeRatio')
        edges.append(dict(leftIndex=indices[i], rightIndex=indices[i + 1],
            seconds=period, amplitudeRatio=ratio, eligible=not reasons, rejections=reasons))
    windows = {width: [i for i in range(max(0, len(indices) - width + 1))
                      if all(e['eligible'] for e in edges[i:i + width - 1])]
               for width in (2, 3, 5, 11)}
    with localcontext() as context:
        context.prec = 100
        values = [Fraction.from_float(v) for v in amplitudes]
        # The pinned tier queries normalize by all but the final selected value,
        # independently of edge rejection. This is intentionally not symmetric.
        population = values[:-1]
        mean = sum(population, Fraction(0)) / len(population) if population else None
        local_terms = [abs(values[i + 1] - values[i]) for i in windows[2]]
        db_terms = [20 * abs((Decimal.from_float(amplitudes[i + 1]) /
                             Decimal.from_float(amplitudes[i])).log10()) for i in windows[2]]
        def average(terms):
            return sum(terms) / len(terms) if terms else None
        def normalized(terms):
            value = average(terms)
            return value / mean if value is not None and mean else None
        results = dict(local=normalized(local_terms), db=average(db_terms))
        for width in (3, 5, 11):
            middle = width // 2
            # Weighted central difference is independent of the usual
            # center-minus-window-average implementation.
            terms = [abs((width - 1) * values[i + middle]
                         - sum(values[i:i + middle])
                         - sum(values[i + middle + 1:i + width])) / width
                     for i in windows[width]]
            results['apq' + str(width)] = normalized(terms)
        results['dda'] = 3 * results['apq3'] if results['apq3'] is not None else None
        converted = {key: float(results[key]) if results[key] is not None else None
                     for key in MEASUREMENTS}
        mean = float(mean) if mean is not None else None
    return dict(definition='hdxl-independent-shimmer-tier-rational-v1', values=converted,
        selectedAmplitudeIndices=indices, normalizationIndices=indices[:-1],
        selectedAmplitudeCount=len(indices), normalizationCount=max(0, len(indices) - 1),
        meanAmplitude=mean, zeroAmplitudeCount=sum(a == 0 for a in amplitudes),
        pairStartIndices=[indices[i] for i in windows[2]],
        apq3WindowStartIndices=[indices[i] for i in windows[3]],
        apq5WindowStartIndices=[indices[i] for i in windows[5]],
        apq11WindowStartIndices=[indices[i] for i in windows[11]], edges=edges)


def comparison_bounds(case, oracle):
    validate(case)
    n = oracle['selectedAmplitudeCount']
    g = 16 * math.ulp(1.) * (n + 64)
    maximum = max((case['amplitudes'][i] for i in oracle['selectedAmplitudeIndices']), default=0.)
    mean = oracle['meanAmplitude']
    relative = g * (1 + maximum / mean) if mean else g
    return {key: g * (1 + abs(oracle['values'][key] or 0.)) if key == 'db' else relative
            for key in MEASUREMENTS}
