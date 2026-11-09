"""Original independent equations for supplied-period performance receipts.

Binary64 subtraction specifies period inputs and eligibility. Decimal averages
evaluate all numerators and the separate denominator; native outputs never become
expected numerical answers. Source flags are declared observations, not an
independent revalidation of a PCM tracker's reliability decisions.
"""
from decimal import Decimal, localcontext
import hashlib
import math
import struct

VARIANTS = ('local', 'absolute', 'rap', 'ppq5', 'ddp')
REASONS = ('excluded', 'discontinuity', 'unreliable', 'missingAcquisition', 'invalidInput', 'silence')


def generated_periods(row):
    n = row['durationMilliseconds'] * row['frequencyHz'] // 1000
    count = n * (2 if row['kind'] == 'rolling' else 1)
    hz = row['frequencyHz']
    def point(i):
        return i / hz + (.01 / hz if i % 2 else 0.)
    return [dict(startSeconds=point(i), endSeconds=point(i + 1), runID=0,
                 rejections=dict(rawValue=(1 if i % 2 == 0 else 4)
                     if row['denseRejections'] and i % 11 >= 6 else 0))
            for i in range(count)]


def period_hash(periods):
    return hashlib.sha256(b''.join(struct.pack('<ddQB', p['startSeconds'], p['endSeconds'],
        p['runID'], p['rejections']['rawValue']) for p in periods)).hexdigest()


def finite(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def evaluate(periods, configuration, query):
    if not isinstance(periods, list) or len(periods) > 30000:
        raise ValueError('Invalid performance period list')
    previous = -math.inf
    for p in periods:
        if (set(p) != {'startSeconds', 'endSeconds', 'runID', 'rejections'}
                or not finite(p['startSeconds']) or not finite(p['endSeconds'])
                or not previous <= p['startSeconds'] < p['endSeconds']
                or not math.isfinite(p['endSeconds'] - p['startSeconds'])
                or type(p['runID']) is not int or not 0 <= p['runID'] < 2**64
                or set(p['rejections']) != {'rawValue'}
                or type(p['rejections']['rawValue']) is not int
                or not 0 <= p['rejections']['rawValue'] <= 63):
            raise ValueError('Invalid performance period observation')
        previous = p['endSeconds']
    begin, end = query['startSeconds'], query['endSeconds']
    if not finite(begin) or not finite(end) or not 0 <= begin <= end:
        raise ValueError('Invalid performance query')
    durations = [float(p['endSeconds']) - float(p['startSeconds']) for p in periods]
    flags = [p['rejections']['rawValue'] for p in periods]
    selected = [begin <= p['startSeconds'] and p['endSeconds'] <= end for p in periods]
    lo, hi, factor = (configuration[k] for k in
        ('minimumPeriodSeconds', 'maximumPeriodSeconds', 'maximumAdjacentPeriodFactor'))
    bounded = [lo <= t <= hi for t in durations]
    accepted = [a and b and not f for a, b, f in zip(selected, bounded, flags)]
    connected = [not flags[i] and not flags[i+1]
        and periods[i]['runID'] == periods[i+1]['runID']
        and periods[i]['endSeconds'] == periods[i+1]['startSeconds']
        for i in range(max(0, len(periods)-1))]
    bad_ratio = [max(a,b) / min(a,b) > factor for a,b in zip(durations,durations[1:])]
    denominator = [i for i,a in enumerate(accepted) if a and not (
        i > 0 and i+1 < len(periods) and connected[i-1] and bad_ratio[i-1]
        and connected[i] and bad_ratio[i])]
    windows = {w: [i for i in range(max(0,len(periods)-w+1))
        if all(accepted[i:i+w]) and all(connected[i:i+w-1]) and not any(bad_ratio[i:i+w-1])]
        for w in (2,3,5)}
    candidates = {w: sum(all(selected[i:i+w]) for i in range(max(0,len(periods)-w+1))) for w in (2,3,5)}
    reasons = {key: sum(s and bool(f & (1 << bit)) for s,f in zip(selected,flags))
               for bit,key in enumerate(REASONS)}
    reasons.update(belowMinimum=sum(s and t < lo for s,t in zip(selected,durations)),
        aboveMaximum=sum(s and t > hi for s,t in zip(selected,durations)),
        bothAdjacentRatios=sum(accepted)-len(denominator),
        ratioPairs=sum(selected[i] and selected[i+1] and bad_ratio[i] for i in range(len(bad_ratio))),
        discontinuousPairs=sum(selected[i] and selected[i+1] and not connected[i] for i in range(len(connected))))
    with localcontext() as context:
        context.prec = 100
        t = [Decimal.from_float(d) for d in durations]
        def average(values):
            return sum(values, Decimal(0))/len(values) if values else None
        mean = average([t[i] for i in denominator])
        absolute = average([abs(t[i+1]-t[i]) for i in windows[2]])
        rap = average([abs(t[i+1]-sum(t[i:i+3])/3) for i in windows[3]])
        ppq = average([abs(t[i+2]-sum(t[i:i+5])/5) for i in windows[5]])
        ddp = average([abs(t[i]-2*t[i+1]+t[i+2]) for i in windows[3]])
        values = dict(local=absolute/mean if absolute is not None and mean else None,
            absolute=absolute, rap=rap/mean if rap is not None and mean else None,
            ppq5=ppq/mean if ppq is not None and mean else None,
            ddp=ddp/mean if ddp is not None and mean else None)
        coverage = dict(selectedPeriodCount=sum(selected), acceptedPeriodCount=sum(accepted),
            meanPeriodCount=len(denominator), acceptedPairCount=len(windows[2]),
            acceptedRAPNeighborhoodCount=len(windows[3]), acceptedPPQ5NeighborhoodCount=len(windows[5]),
            candidatePairCount=candidates[2], candidateRAPNeighborhoodCount=candidates[3],
            candidatePPQ5NeighborhoodCount=candidates[5], rejections=reasons,
            acceptedPeriodDurationSeconds=float(sum((t[i] for i,a in enumerate(accepted) if a),Decimal(0))),
            meanPeriodSeconds=float(mean) if mean is not None else None)
        values = {k: float(v) if v is not None else None for k,v in values.items()}
    # Conservative forward bound for sums, divisions and fixed-width neighborhoods.
    # Discrete membership, counts, units and status are always compared exactly.
    gamma = 8 * math.ulp(1.) * (len(periods)+32)
    maximum = max((d for d,a in zip(durations,accepted) if a),default=0.)
    bounds = dict(seconds=gamma*maximum,
        totalSeconds=gamma*max(1.,coverage['acceptedPeriodDurationSeconds']),
        fraction=gamma*(1+maximum/float(mean)) if mean else 0.)
    return dict(coverage=coverage, values=values, bounds=bounds, selected=selected)
