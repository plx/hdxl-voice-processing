"""Original period-eligibility algebra and independently formulated RMS anchors.

Run membership and tracking breaks are explicit inputs, never inferred by dropping
unwanted timestamps and reconnecting the remaining neighbors.
"""
import math

from reference import PERIOD_DEFAULTS, finite, validate_period_settings


def eligibility(times, run_ids, domain_end, *, broken_intervals=(), settings=None):
    settings = PERIOD_DEFAULTS if settings is None else settings
    validate_period_settings(settings)
    if not isinstance(times, list) or len(times) > 30000 or not all(finite(t) for t in times):
        raise ValueError('Invalid pulse sequence')
    if not finite(domain_end) or domain_end <= 0 or any(a >= b for a, b in zip(times, times[1:])):
        raise ValueError('Invalid domain/order')
    if not isinstance(run_ids, list) or len(run_ids) != len(times):
        raise ValueError('Missing explicit run membership')
    if any(r is not None and (type(r) is not int or r < 0) for r in run_ids):
        raise ValueError('Invalid run identity')
    breaks = set(broken_intervals)
    if len(breaks) != len(broken_intervals) or any(type(i) is not int or not 0 <= i < len(times) - 1 for i in breaks):
        raise ValueError('Invalid tracking-break interval')
    periods = []
    for i, (left, right) in enumerate(zip(times, times[1:])):
        duration = right - left
        reasons = []
        if not 0 <= left < right < domain_end: reasons.append('outsideAcquisition')
        if run_ids[i] is None or run_ids[i + 1] is None: reasons.append('unassignedRun')
        elif run_ids[i] != run_ids[i + 1]: reasons.append('differentRun')
        if i in breaks: reasons.append('trackingFailure')
        if duration < settings['minimumSeconds']: reasons.append('periodBelowMinimum')
        if duration > settings['maximumSeconds']: reasons.append('periodAboveMaximum')
        periods.append({'index': i, 'leftPulseIndex': i, 'rightPulseIndex': i + 1,
                        'durationSeconds': duration, 'eligible': not reasons, 'reasons': reasons,
                        'runID': run_ids[i] if not reasons else None})
    pairs = []
    for i, (left, right) in enumerate(zip(periods, periods[1:])):
        a, b = left['durationSeconds'], right['durationSeconds']
        ratio = max(a, b) / min(a, b)
        reasons = []
        if not left['eligible']: reasons.append('leftPeriodIneligible')
        if not right['eligible']: reasons.append('rightPeriodIneligible')
        if ratio > settings['maximumAdjacentFactor']: reasons.append('adjacentPeriodFactor')
        pairs.append({'index': i, 'leftPeriodIndex': i, 'rightPeriodIndex': i + 1,
                      'ratio': ratio, 'eligible': not reasons, 'reasons': reasons})
    return {'definition': 'explicit-pulse-period-eligibility-v1', 'periods': periods, 'pairs': pairs,
            'rawPulseCount': len(times), 'rawPeriodCount': len(periods),
            'eligiblePeriodCount': sum(p['eligible'] for p in periods),
            'eligiblePairCount': sum(p['eligible'] for p in pairs)}


def hann_rms(samples, rate, time, left_period, right_period):
    """Cosine-squared taper and compensated energy sums; no peak-picking shortcut."""
    if type(rate) is not int or rate <= 0 or not samples or not all(finite(s) for s in samples):
        raise ValueError('Invalid amplitude PCM')
    if not all(finite(v) and v > 0 for v in (left_period, right_period)) or not finite(time):
        raise ValueError('Invalid amplitude support')
    left, right = .2 * left_period, .2 * right_period
    start, end = time - left, time + right
    if start < 0 or end > len(samples) * (1 / rate):
        return {'status': 'unavailable', 'reason': 'insufficientSupport', 'sampleCount': 0}
    indices = range(max(0, math.ceil(start * rate - .5)), min(len(samples), math.floor(end * rate - .5) + 1))
    if len(indices) < 3:
        return {'status': 'unavailable', 'reason': 'insufficientData', 'sampleCount': len(indices)}
    peak = max(abs(samples[i]) for i in indices)
    if peak == 0:
        return {'status': 'unavailable', 'reason': 'silence', 'sampleCount': len(indices)}
    weights, energy = [], []
    for i in indices:
        offset = math.fma(float(i), 1 / rate, .5 / rate) - time
        width = left if offset < 0 else right
        # cos(theta/2)^2 is the Hann amplitude taper; its square weights energy.
        weight = math.cos(.5 * math.pi * offset / width) ** 4
        weights.append(weight)
        energy.append((samples[i] / peak) ** 2 * weight)
    normalization = math.fsum(weights)
    value = peak * math.sqrt(math.fsum(energy) / normalization)
    if not math.isfinite(value) or value <= 0:
        return {'status': 'unavailable', 'reason': 'numericalFailure', 'sampleCount': len(indices)}
    return {'status': 'available', 'rmsAmplitude': value, 'sampleCount': len(indices),
            'supportStartSeconds': start, 'supportEndSeconds': end,
            'firstSampleIndex': indices.start, 'lastSampleIndex': indices.stop - 1}


def reference_amplitudes(samples, rate, times, settings=None):
    """Independent expected RMS values for the external tier's closed-domain query.

    This preserves the external query definition. Native run/gap/selection
    eligibility is additional and is explicitly evaluated by eligibility().
    """
    settings = PERIOD_DEFAULTS if settings is None else settings
    validate_period_settings(settings)
    end = len(samples) * (1 / rate)
    observed = [(i, t) for i, t in enumerate(times) if 0 <= t <= end]
    result = []
    for (li, left), (index, time), (ri, right) in zip(observed, observed[1:], observed[2:]):
        p, q = time - left, right - time
        if not settings['minimumSeconds'] <= p <= settings['maximumSeconds']: continue
        if not settings['minimumSeconds'] <= q <= settings['maximumSeconds']: continue
        if max(p, q) / min(p, q) > settings['maximumAdjacentFactor']: continue
        estimate = hann_rms(samples, rate, time, p, q)
        if estimate['status'] == 'available':
            result.append({'pulseIndex': index, 'timeSeconds': time,
                           'rmsAmplitude': estimate['rmsAmplitude'], 'support': estimate})
    return result
