"""Exact equations for explicit native source masks, without importing Swift results.

Unlike a compact AmplitudeTier, records retain missing cycles, sequence indices,
run identities and source flags. Windows are enumerated directly, independently
of the native kernel's eligible-run accumulator.
"""
from decimal import Decimal, localcontext
from fractions import Fraction
import math

from shimmer_oracle import MEASUREMENTS, finite

SOURCE_FLAGS = ('excluded', 'discontinuity', 'unreliable', 'missingAcquisition',
                'invalidInput', 'silence', 'insufficientSupport', 'periodExclusion')


def evaluate(records, query, configuration):
    if not isinstance(records, list) or len(records) > 30000:
        raise ValueError('Invalid native amplitude record count')
    if not isinstance(query, dict) or set(query) != {'startSeconds', 'endSeconds'}:
        raise ValueError('Invalid native amplitude query')
    start, end = query['startSeconds'], query['endSeconds']
    if not all(finite(v) for v in (start, end)) or not 0 <= start <= end <= 60:
        raise ValueError('Invalid native amplitude query bounds')
    lo, hi, factor = (configuration[k] for k in ('minimumPeriodSeconds', 'maximumPeriodSeconds', 'maximumAmplitudeFactor'))
    if not all(finite(v) for v in (lo, hi, factor)) or not 0 < lo < hi <= .1 or not 1 <= factor <= 10:
        raise ValueError('Invalid native statistical settings')
    for i, record in enumerate(records):
        keys = {'timeSeconds', 'sequenceIndex', 'runID', 'rejections'}
        if not isinstance(record, dict) or set(record) not in (keys, keys | {'amplitude'}):
            raise ValueError('Unexpected native amplitude fields')
        if not finite(record['timeSeconds']) or not -.1 <= record['timeSeconds'] <= 60.1:
            raise ValueError('Invalid native amplitude time')
        if i and records[i - 1]['timeSeconds'] >= record['timeSeconds']:
            raise ValueError('Reordered native amplitudes')
        if any(type(record[k]) is not int or not 0 <= record[k] < 2 ** 64 for k in ('sequenceIndex', 'runID')):
            raise ValueError('Invalid native sequence/run identity')
        flags = record['rejections']
        if not isinstance(flags, dict) or set(flags) != {'rawValue'} or type(flags['rawValue']) is not int or not 0 <= flags['rawValue'] <= 255:
            raise ValueError('Invalid native source rejection flags')
        amplitude = record.get('amplitude')
        if amplitude is None:
            if not flags['rawValue']: raise ValueError('Missing amplitude without source rejection')
        elif not finite(amplitude) or amplitude < 0:
            raise ValueError('Invalid native amplitude value')
    selected = [start <= r['timeSeconds'] <= end for r in records]
    reliable = [r.get('amplitude') is not None and r['rejections']['rawValue'] == 0 for r in records]
    selected_indices = [i for i, s in enumerate(selected) if s]
    accepted = [i for i in selected_indices if reliable[i]]
    population = accepted[:-1]
    values = [Fraction.from_float(float(r.get('amplitude') or 0)) for r in records]
    mean = sum((values[i] for i in population), Fraction(0)) / len(population) if population else None
    peak = max((values[i] for i in population), default=Fraction(0))
    rejections = {name: sum(bool(records[i]['rejections']['rawValue'] & (1 << bit)) for i in selected_indices)
                  for bit, name in enumerate(SOURCE_FLAGS)}
    rejections.update({k: 0 for k in ('belowMinimumPairs', 'aboveMaximumPairs', 'amplitudeRatioPairs',
                                     'zeroAmplitudePairs', 'discontinuousPairs')})
    edges = []
    for i, (a, b) in enumerate(zip(records, records[1:])):
        seconds = b['timeSeconds'] - a['timeSeconds']
        connected = reliable[i] and reliable[i + 1] and a['runID'] == b['runID'] and a['sequenceIndex'] + 1 == b['sequenceIndex']
        positive = values[i] > 0 and values[i + 1] > 0
        ratio_bad = positive and max(float(values[i]), float(values[i + 1])) / min(float(values[i]), float(values[i + 1])) > factor
        below, above = seconds < lo, seconds > hi
        if selected[i] and selected[i + 1]:
            rejections['discontinuousPairs'] += not connected
            rejections['belowMinimumPairs'] += below
            rejections['aboveMaximumPairs'] += above
            rejections['amplitudeRatioPairs'] += bool(ratio_bad)
            rejections['zeroAmplitudePairs'] += (reliable[i] and values[i] == 0) or (reliable[i + 1] and values[i + 1] == 0)
        edges.append(selected[i] and selected[i + 1] and connected and positive and not below and not above and not ratio_bad)
    windows = {width: [i for i in range(max(0, len(records) - width + 1))
                       if all(edges[i:i + width - 1])]
               for width in (2, 3, 5, 11)}
    candidates = {width: sum(all(selected[i:i + width]) for i in range(max(0, len(records) - width + 1)))
                  for width in windows}
    def normalized(terms):
        return sum(terms, Fraction(0)) / len(terms) / mean if terms and mean else None
    results = {'local': normalized([abs(values[i + 1] - values[i]) for i in windows[2]])}
    with localcontext() as context:
        context.prec = 100
        terms = [20 * abs((Decimal.from_float(float(values[i + 1])) /
                           Decimal.from_float(float(values[i]))).log10()) for i in windows[2]]
        results['db'] = sum(terms) / len(terms) if terms else None
    for width in (3, 5, 11):
        terms = [abs(values[i + width // 2] - sum(values[i:i + width], Fraction(0)) / width)
                 for i in windows[width]]
        results['apq' + str(width)] = normalized(terms)
    results['dda'] = 3 * results['apq3'] if results['apq3'] is not None else None
    converted = {k: float(results[k]) if results[k] is not None else None for k in MEASUREMENTS}
    coverage = dict(inputAmplitudeCount=len(records), selectedAmplitudeCount=len(selected_indices),
        acceptedAmplitudeCount=len(accepted), positiveAmplitudeCount=sum(values[i] > 0 for i in accepted),
        zeroAmplitudeCount=sum(values[i] == 0 for i in accepted), normalizationAmplitudeCount=len(population),
        normalizationScale=float(peak), scaledMeanAmplitude=float(mean / peak) if peak else 0.,
        acceptedPairCount=len(windows[2]), acceptedAPQ3NeighborhoodCount=len(windows[3]),
        acceptedAPQ5NeighborhoodCount=len(windows[5]), acceptedAPQ11NeighborhoodCount=len(windows[11]),
        candidatePairCount=candidates[2], candidateAPQ3NeighborhoodCount=candidates[3],
        candidateAPQ5NeighborhoodCount=candidates[5], candidateAPQ11NeighborhoodCount=candidates[11],
        analyzedDurationSeconds=end - start,
        acceptedPairDurationSeconds=math.fsum(records[i + 1]['timeSeconds'] - records[i]['timeSeconds'] for i in windows[2]),
        rejections=rejections)
    if mean is not None and (float(mean) > 0 or peak == 0): coverage['meanAmplitude'] = float(mean)
    g = 16 * math.ulp(1.) * (len(records) + 64)
    maximum = max((values[i] for i in accepted), default=Fraction(0))
    fraction_bound = g * (1 + float(maximum / mean)) if mean else g
    bounds = {k: g * (1 + abs(converted[k] or 0.)) if k == 'db' else fraction_bound for k in MEASUREMENTS}
    return dict(values=converted, coverage=coverage, normalizationIndices=population,
        acceptedIndices=accepted, windows={str(k): v for k, v in windows.items()}, comparisonBounds=bounds)
