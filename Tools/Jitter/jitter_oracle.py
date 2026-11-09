"""Original high-precision jitter equations, independent of native tracking/statistics.

Public definitions supply the formulas; bounded black-box PointProcess probes pin
edge behavior. No Praat implementation source is used. Binary64 point subtraction
and ratio comparisons specify the input/eligibility boundary. Decimal arithmetic
then evaluates the accepted sums and divisions with 100 significant digits.
"""
from decimal import Decimal, localcontext
import math

INPUT_KEYS = {'schemaVersion', 'name', 'pointsSeconds', 'domainStartSeconds',
              'domainEndSeconds', 'queryStartSeconds', 'queryEndSeconds',
              'minimumPeriodSeconds', 'maximumPeriodSeconds', 'maximumAdjacentFactor'}
MEASUREMENTS = ('local', 'absolute', 'rap', 'ppq5', 'ddp')


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate(case):
    if not isinstance(case, dict) or set(case) != INPUT_KEYS:
        raise ValueError('Unexpected jitter input schema')
    if type(case['schemaVersion']) is not int or case['schemaVersion'] != 1:
        raise ValueError('Unsupported jitter schema version')
    name = case['name']
    if not isinstance(name, str) or not 1 <= len(name) <= 100 or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in name):
        raise ValueError('Invalid jitter case name')
    fields = INPUT_KEYS - {'schemaVersion', 'name', 'pointsSeconds'}
    if not all(finite(case[k]) for k in fields):
        raise ValueError('Nonfinite jitter metadata')
    a, b = case['domainStartSeconds'], case['domainEndSeconds']
    lo, hi = case['minimumPeriodSeconds'], case['maximumPeriodSeconds']
    if not 0 <= a < b <= 60 or not a <= case['queryStartSeconds'] < case['queryEndSeconds'] <= b:
        raise ValueError('Invalid jitter time bounds')
    if not 0 < lo < hi <= .1 or not 1 <= case['maximumAdjacentFactor'] <= 10:
        raise ValueError('Invalid jitter period settings')
    points = case['pointsSeconds']
    if not isinstance(points, list) or len(points) > 30000 or not all(finite(p) and a <= p <= b for p in points):
        raise ValueError('Invalid jitter points')
    if any(p >= q for p, q in zip(points, points[1:])):
        raise ValueError('Jitter points must be strictly increasing')
    if any(float(q) - float(p) < 1e-12 for p, q in zip(points, points[1:])):
        raise ValueError('Reference fixture point separation is below its declared bound')


def evaluate(case):
    validate(case)
    points = case['pointsSeconds']
    periods = [float(b) - float(a) for a, b in zip(points, points[1:])]
    lo, hi, factor = (case[k] for k in ('minimumPeriodSeconds', 'maximumPeriodSeconds', 'maximumAdjacentFactor'))
    begin, end = case['queryStartSeconds'], case['queryEndSeconds']
    selected = [begin <= a and b <= end for a, b in zip(points, points[1:])]
    bounded = [lo <= t <= hi for t in periods]
    ratios = [max(a, b) / min(a, b) for a, b in zip(periods, periods[1:])]
    bad_edges = [r > factor for r in ratios]
    denominator = [i for i, t in enumerate(periods) if selected[i] and bounded[i]
                   and not (i > 0 and i + 1 < len(periods) and bad_edges[i - 1] and bad_edges[i])]
    windows = {}
    for width in (2, 3, 5):
        windows[width] = [i for i in range(max(0, len(periods) - width + 1))
                          if all(selected[i:i + width]) and all(bounded[i:i + width])
                          and not any(bad_edges[i:i + width - 1])]
    with localcontext() as context:
        context.prec = 100
        values = [Decimal.from_float(t) for t in periods]
        mean = sum((values[i] for i in denominator), Decimal(0)) / len(denominator) if denominator else None
        absolute_terms = [abs(values[i + 1] - values[i]) for i in windows[2]]
        # Second differences give the RAP/DDP relationship independently of a
        # center-minus-three-point-average implementation.
        ddp_terms = [abs(values[i] - 2 * values[i + 1] + values[i + 2]) for i in windows[3]]
        ppq_terms = [abs(4 * values[i + 2] - sum(values[i:i + 2]) - sum(values[i + 3:i + 5])) / 5
                    for i in windows[5]]
        def average(terms):
            return sum(terms, Decimal(0)) / len(terms) if terms else None
        absolute, ddp, ppq = average(absolute_terms), average(ddp_terms), average(ppq_terms)
        result = {'local': absolute / mean if absolute is not None and mean else None,
                  'absolute': absolute, 'rap': ddp / (3 * mean) if ddp is not None and mean else None,
                  'ppq5': ppq / mean if ppq is not None and mean else None,
                  'ddp': ddp / mean if ddp is not None and mean else None}
        result = {k: float(v) if v is not None else None for k, v in result.items()}
        mean = float(mean) if mean is not None else None
    denominator_set = set(denominator)
    rows = []
    for i, t in enumerate(periods):
        reasons = []
        if not selected[i]: reasons.append('outsideQuery')
        if t < lo: reasons.append('periodBelowMinimum')
        if t > hi: reasons.append('periodAboveMaximum')
        if i > 0 and i + 1 < len(periods) and bad_edges[i - 1] and bad_edges[i]:
            reasons.append('bothAdjacentRatiosRejected')
        rows.append({'index': i, 'seconds': t, 'selected': selected[i], 'withinBounds': bounded[i],
                     'inMeanPeriod': i in denominator_set, 'meanPeriodRejections': reasons})
    return {'definition': 'hdxl-independent-jitter-decimal-v1', 'values': result,
            'meanPeriodSeconds': mean, 'meanPeriodIndices': denominator,
            'selectedPointCount': sum(begin <= p <= end for p in points),
            'selectedPeriodCount': sum(selected),
            'boundedPeriodCount': sum(a and b for a, b in zip(selected, bounded)),
            'meanPeriodCount': len(denominator), 'pairIndices': windows[2],
            'rapWindowStartIndices': windows[3], 'ppq5WindowStartIndices': windows[5],
            'periods': rows, 'adjacentRatios': ratios}
