"""Original bounded scalar oracle for the fixed-time YIN profile.

Equations: de Cheveigne & Kawahara (2002), DOI 10.1121/1.1458024,
steps 2--5. Exact conventions are frozen in README.md. No Swift or
third-party implementation is imported or executed.
"""
import math

NAME = 'hdxl-yin-fixed-time-2002-steps2to5'
COMPARISON = {
    'differenceAbsolutePerIntegrationSample': 2e-10,
    'differenceRelative': 1e-12,
    'cmndAbsolute': 1e-9,
    'periodSamplesAbsolute': 2e-6,
    'frequencyHzAbsolute': .001,
    'toneMaximumCents': 10.,
    'harmonicMaximumCents': 20.,
    'cleanMinimumVoicedCoverage': .9,
    'grossRelativeHz': .2,
    'octaveRelativeHz': .2,
}


def configuration(rate=16000, floor=50., ceiling=700., hop=None,
                  integration=None, precision='float64', threshold=.1,
                  silence=1e-7, backend='scalar'):
    if type(rate) is not int or not 4000 <= rate <= 192000:
        raise ValueError('Unsupported sample rate')
    if not all(type(x) in (int, float) and math.isfinite(x)
               for x in (floor, ceiling, threshold, silence)):
        raise ValueError('Nonfinite or nonnumeric configuration')
    if not 20 <= floor < ceiling <= rate / 4 or not 0 < threshold < 1 or not 0 <= silence <= 1:
        raise ValueError('Invalid frequency or threshold range')
    lo, hi = math.floor(rate / ceiling), math.ceil(rate / floor)
    if math.ceil(rate / ceiling) > math.floor(rate / floor):
        raise ValueError('Search range contains no integer lag')
    integration = hi if integration is None else integration
    hop = round(rate / 100) if hop is None else hop
    if type(integration) is not int or not hi <= integration <= 16384 or hi < lo + 1:
        raise ValueError('Insufficient or excessive integration support')
    if type(hop) is not int or not 1 <= hop <= integration + hi + 1:
        raise ValueError('Invalid hop')
    if precision not in ('float32', 'float64') or backend not in ('scalar', 'fft'):
        raise ValueError('Unsupported precision/backend')
    return {
        'schemaVersion': 1, 'sampleRate': rate, 'inputPrecision': precision,
        'arithmeticPrecision': 'float64', 'pitchFloorHz': float(floor),
        'pitchCeilingHz': float(ceiling), 'integrationLength': integration,
        'hopLength': hop, 'threshold': float(threshold),
        'silenceRMSThreshold': 0. if silence == 0 else float(silence),
        'differenceBackend': backend, 'partialWindowPolicy': 'emitUnavailable',
        'definition': NAME, 'interpolation': 'cmndOrdinateRawDifferencePeriod',
        'supportPolicy': 'fixedIntegrationPlusMaximumLagAndNeighbor',
        'normalization': 'observedPeak', 'neighboringTimeRefinement': 'disabled',
        'rangeBoundaryToleranceSamples': 2e-6,
    }


def validate(profile):
    rebuilt = configuration(
        profile['sampleRate'], profile['pitchFloorHz'], profile['pitchCeilingHz'],
        profile['hopLength'], profile['integrationLength'], profile['inputPrecision'],
        profile['threshold'], profile['silenceRMSThreshold'], profile['differenceBackend'])
    if profile != rebuilt:
        raise ValueError('Unknown, missing or inconsistent profile fields')


def geometry(profile):
    validate(profile)
    rate = profile['sampleRate']
    lower = rate / profile['pitchCeilingHz']
    upper = rate / profile['pitchFloorHz']
    lo, hi = math.floor(lower), math.ceil(upper)
    return lower, upper, lo, hi, profile['integrationLength'] + hi + 1


def vertex(left, center, right):
    curvature = left - 2 * center + right
    if curvature > 0:
        offset = .5 * (left - right) / curvature
        if math.isfinite(offset) and abs(offset) <= 1:
            return offset, center - .25 * (left - right) * offset
    return 0., center


def canonical_period(period, lower, upper, tolerance):
    if abs(period - lower) <= tolerance:
        return lower
    if abs(period - upper) <= tolerance:
        return upper
    return period


def candidates(difference, cmnd, profile):
    lower, upper, lo, hi, _ = geometry(profile)
    local = [k for k in range(lo, hi + 1)
             if cmnd[k] < cmnd[k - 1] and cmnd[k] <= cmnd[k + 1]]
    global_lag = min(range(math.ceil(lower), math.floor(upper) + 1), key=lambda k: (cmnd[k], k))
    rows = []
    for lag in sorted(set(local + [global_lag])):
        _, error = vertex(*cmnd[lag - 1:lag + 2])
        offset, _ = vertex(*difference[lag - 1:lag + 2])
        unbounded = lag + offset
        period = canonical_period(unbounded, lower, upper, profile['rangeBoundaryToleranceSamples'])
        error = max(0., error)
        in_range = lower <= period <= upper
        is_local = lag in local
        rows.append({
            'integerLag': lag, 'periodSamples': period,
            'unboundedPeriodSamples': unbounded,
            'isBoundaryCanonicalized': min(abs(unbounded - lower), abs(unbounded - upper))
                <= profile['rangeBoundaryToleranceSamples'],
            'frequencyHz': profile['sampleRate'] / period,
            'normalizedError': error, 'periodicity': max(0., 1 - error),
            'isLocalMinimum': is_local, 'isGlobalMinimum': lag == global_lag,
            'isInRange': in_range,
            'isThresholdQualified': is_local and in_range and error < profile['threshold'],
        })
    eligible = [i for i, row in enumerate(rows) if row['isThresholdQualified']]
    in_range = [i for i, row in enumerate(rows) if row['isInRange']]
    selection = eligible[0] if eligible else min(
        in_range, key=lambda i: (rows[i]['normalizedError'], rows[i]['integerLag']), default=None)
    return rows, selection


def frame(samples, profile):
    """One full or explicitly partial frame; outputs include all intermediate cells."""
    _, _, _, hi, support = geometry(profile)
    if len(samples) > support or any(not math.isfinite(x) for x in samples):
        raise ValueError('Invalid frame PCM')
    row = {'observedSampleCount': len(samples), 'requiredSampleCount': support,
           'difference': [], 'cmnd': [], 'candidates': [], 'selectedCandidateIndex': None,
           'status': 'unavailable', 'reason': 'insufficientData',
           'normalizationPeak': None, 'rms': None}
    if len(samples) < support:
        return row
    peak = max(map(abs, samples))
    scaled = [x / peak for x in samples] if peak else [0.] * support
    rms = peak * math.sqrt(math.fsum(x * x for x in scaled) / support)
    integration = profile['integrationLength']
    reference = scaled[:integration]
    difference = [0.] + [math.fsum((a - b) ** 2 for a, b in
        zip(reference, scaled[lag:lag + integration])) for lag in range(1, hi + 2)]
    cmnd = [1.]
    for lag in range(1, len(difference)):
        total = math.fsum(difference[1:lag + 1])
        cmnd.append(lag * difference[lag] / total if total else 1.)
    rows, selection = candidates(difference, cmnd, profile)
    status, reason = 'uncertain', None
    if rms <= profile['silenceRMSThreshold']:
        status, reason, selection = 'unvoiced', 'silence', None
    elif max(difference) == 0:
        status, reason, selection = 'unvoiced', 'lowConfidence', None
    elif selection is None:
        status, reason = 'unavailable', 'unsupportedRange'
    elif rows[selection]['isThresholdQualified']:
        status = 'voiced'
    row.update(difference=difference, cmnd=cmnd, candidates=rows,
               selectedCandidateIndex=selection, status=status, reason=reason,
               normalizationPeak=peak, rms=rms)
    return row


def stream(samples, profile):
    """Integer grid, all full frames and at most the first nonempty partial tail."""
    support = geometry(profile)[-1]
    rows = []
    start = 0
    while start + support <= len(samples):
        rows.append({'frameIndex': len(rows), 'startSample': start,
                     **frame(samples[start:start + support], profile)})
        start += profile['hopLength']
    if start < len(samples):
        rows.append({'frameIndex': len(rows), 'startSample': start,
                     **frame(samples[start:], profile)})
    return rows


def track(frames, weight=.05):
    """Separate causal preference; exact hand-enumerated cases exercise this layer."""
    if not math.isfinite(weight) or not 0 <= weight <= 10:
        raise ValueError('Invalid tracker weight')
    previous = None
    run_start = None
    result = []
    for frame_row in frames:
        selected = frame_row['selectedCandidateIndex']
        raw = selected
        if frame_row['status'] == 'voiced':
            if previous is None:
                run_start = frame_row['startSample']
            else:
                eligible = [i for i, row in enumerate(frame_row['candidates'])
                            if row['isThresholdQualified']]
                selected = min(eligible, key=lambda i: (
                    frame_row['candidates'][i]['normalizedError'] + weight * abs(math.log2(
                        frame_row['candidates'][i]['frequencyHz'] / previous)),
                    frame_row['candidates'][i]['integerLag']))
            previous = frame_row['candidates'][selected]['frequencyHz']
        else:
            previous = None
            run_start = frame_row['startSample']
        result.append({'selectedCandidateIndex': selected, 'changedSelection': selected != raw,
                       'dependencyStartSample': run_start,
                       'dependencySampleCount': frame_row['startSample'] +
                           frame_row['observedSampleCount'] - run_start})
    return result
