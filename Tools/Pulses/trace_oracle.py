"""Original bounded pulse-history oracle: Decimal lag tables and a path graph.

No native code or outputs are used. SEARCH.md defines raw reference conventions;
native qualification adds explicit support and graph-edge requirements. Source
cases use exact binary sample templates so complete trajectories have independent
closed-form timing anchors as well as the external reference route.
"""
import itertools
import math
import struct

import sequences
import stages
from reference import finite, validate_pitch, validate_period_settings

MAX_SAMPLES = 12000
MAX_ATTEMPTS = 4096
CURVATURE_FLOOR = 128 * math.ulp(1.)
VARIATION_FLOOR = 64 * math.ulp(1.)
COMPARISON = {'timeSamples': 2e-10, 'correlation': 2e-12,
              'amplitudeAbsolute': 2e-12, 'amplitudeRelative': 1e-10,
              'countsIndicesEligibilityReasons': 'exact',
              'sourceTimingScope': 'exact binary pulse template; interior seeds refined, endpoint seeds retain declared phase bias'}


def cases():
    specifications = [
        ('regular', {}), ('inverted', {'gain': -1.}),
        ('fractional-seeds', {'fractional': True, 'sampleCount': 404}),
        ('endpoint-seed', {'fractional': True, 'knownSeedBiasSamples': -.25}),
        ('alternating-strength', {'alternating': True}),
        ('one-missing-cycle', {'zeroRanges': [[160, 168]]}),
        ('long-zero-gap', {'zeroRanges': [[160, 240]]}),
        ('unvoiced-gap', {'unvoicedFrames': [8, 9, 10, 11]}),
        ('all-unvoiced', {'allUnvoiced': True}),
        ('silence', {'gain': 0.}),
        ('excluded-cycle', {'excludedSamples': [[148, 152]]}),
        ('adjacent-exclusions', {'excludedSamples': [[40, 44], [44, 48], [200, 204]]}),
        ('period-too-short', {'minimumSeconds': .0021}),
        ('period-too-long', {'maximumSeconds': .0019}),
        ('alternating-periods', {'alternatingPeriods': True}),
        ('alternating-periods-strict', {'alternatingPeriods': True, 'maximumAdjacentFactor': 1.1}),
    ]
    specifications += [(f'short-{n}', {'sampleCount': n}) for n in (8, 16, 24, 32, 40)]
    specifications += [(f'exact-48000-{hz}', {'sampleRate': 48000, 'periodSamples': 48000 // hz,
        'sampleCount': 8 * (48000 // hz), 'fractional': True}) for hz in (80, 150, 300, 600)]
    result = []
    for precision in ('float32', 'float64'):
        for name, changes in specifications:
            spec = dict(name=f'{name}-{precision}', inputPrecision=precision, sampleRate=4000,
                sampleCount=400, periodSamples=8, fractional=False, gain=1., alternating=False,
                alternatingPeriods=False, zeroRanges=[], excludedSamples=[], unvoicedFrames=[],
                allUnvoiced=False, knownSeedBiasSamples=0., minimumSeconds=.0001,
                maximumSeconds=.02, maximumAdjacentFactor=1.3)
            result.append(dict(spec, **changes))
    return result


def inputs(case):
    rate, count, period = (case[k] for k in ('sampleRate', 'sampleCount', 'periodSamples'))
    if not (type(rate) is int and type(count) is int and 1 <= count <= MAX_SAMPLES
            and type(period) is int and period >= 8 and case['inputPrecision'] in ('float32', 'float64')):
        raise ValueError('Invalid trace case geometry')
    pcm, known = [0.] * count, []
    center = 3
    ordinal = 0
    while center + 1 < count:
        scale = case['gain'] * (.125 if case['alternating'] and ordinal % 2 else 1.)
        lobe = (.25, 1., .75) if case['fractional'] else (.5, 1., .5)
        for index, value in zip(range(center - 1, center + 2), lobe):
            pcm[index] = value * scale
        known.append(dict(timeSeconds=math.fma(center + (.25 if case['fractional'] else 0.),
                                               1 / rate, .5 / rate), amplitude=abs(scale)))
        center += period + (2 if case['alternatingPeriods'] and ordinal % 2 else 0)
        ordinal += 1
    for low, high in case['zeroRanges']:
        pcm[low:high] = [0.] * (high - low)
    if case['inputPrecision'] == 'float32':
        pcm = list(struct.unpack(f'<{count}f', struct.pack(f'<{count}f', *pcm)))
    duration = count * (1 / rate)
    frames = max(1, math.floor(duration / .005))
    step = min(.005, duration)
    frequency = rate / (period + (1 if case['alternatingPeriods'] else 0))
    frequencies = [0. if case['allUnvoiced'] or i in case['unvoicedFrames'] else frequency for i in range(frames)]
    pitch = dict(domainEndSeconds=duration, firstCenterSeconds=duration / 2 - (frames - 1) * step / 2,
                 stepSeconds=step, ceilingHz=min(1500., rate / 4), frequenciesHz=frequencies)
    validate_pitch(pitch, rate, count)
    return pcm, pitch, known


def sample_index(time, rate, selection):
    return stages.sampled_indices(time, .5 / rate, 1 / rate)[selection]


def varying(values):
    if not values:
        return False
    low, high = min(values), max(values)
    peak = max(abs(low), abs(high))
    return peak > 0 and (high - low) / peak > VARIATION_FLOOR


def seed(pcm, rate, midpoint, frequency):
    required = (sample_index(midpoint - .5 / frequency, rate, 'low'),
                sample_index(midpoint + .5 / frequency, rate, 'high'))
    observed = range(max(0, required[0]), min(len(pcm), required[1] + 1))
    values = [pcm[i] for i in observed]
    if not values:
        return dict(timeSeconds=midpoint, required=list(required), observedCount=0, peak=0., varying=False)
    peak = max(map(abs, values))
    if len(values) == 1:
        position = float(observed.start)
    elif min(values) == max(values) or (len(values) == 2 and abs(values[0]) == abs(values[1])):
        position = (observed.start + observed.stop - 1) / 2
    else:
        # Lexicographic maximization encodes absolute magnitude, positive tie,
        # and earliest sample. The quadratic is independently fit by Lagrange.
        index = max(observed, key=lambda i: (abs(pcm[i]), pcm[i], -i))
        position = float(index)
        if index not in (observed.start, observed.stop - 1):
            vertex = stages.quadratic_vertex(*pcm[index - 1:index + 2])
            if vertex['status'] in ('maximum', 'minimum'):
                position += vertex['offsetSamples']
    return dict(timeSeconds=math.fma(position, 1 / rate, .5 / rate), required=list(required),
                observedCount=len(values), peak=peak, varying=varying(values))


def match(pcm, rate, anchor, frequency, direction, precision):
    period = 1 / frequency
    bounds = sorted([anchor + direction * .8 / frequency, anchor + direction * 1.25 / frequency])
    a, b = [sample_index(anchor + sign * .5 * period, rate, 'nearest') for sign in (-1, 1)]
    low = sample_index(bounds[0] - .5 * period, rate, 'low')
    high = sample_index(bounds[1] - .5 * period, rate, 'high')
    crop_start = max(0, min(a, low))
    crop_end = min(len(pcm), max(b, high + b - a) + 1)
    # Crop only outside the union of all possible observed pairs. The original
    # high-precision stages retain exact observed support and never zero-pad it.
    cropped = pcm[crop_start:crop_end]
    if not cropped:
        raise ValueError('Trace source did not supply any anchor support')
    curve = stages.correlation_curve(cropped, a - crop_start, b - crop_start,
        low - crop_start, high - crop_start, precision=precision)
    chosen = stages.select_correlation_peak(curve)
    common = dict(anchorFirst=a, anchorLast=b, firstCandidate=low, lastCandidate=high,
                  cropFirst=crop_start, curve=curve, selected=chosen)
    if chosen['status'] != 'selected':
        return dict(common, timeSeconds=anchor + direction * period, correlation=None, peak=0.,
                    curvature=0., observedCount=0, varying=False, support='noObservedPairs',
                    fallback=False, synthetic=False, required=[min(a, low), max(b, high + b - a)])
    chosen_start = chosen['candidateFirstIndex'] + crop_start
    # The one-based fractional coordinate is an explicit interchange rounding
    # convention, distinct from the high-precision coefficient/vertex equations.
    fractional = float(chosen_start + 1) + chosen['offsetSamples']
    proposed = math.fma(fractional - (a + 1), 1 / rate, anchor)
    fallback = not bounds[0] <= proposed <= bounds[1]
    time = anchor + direction * math.sqrt((bounds[0] - anchor) * (bounds[1] - anchor)) if fallback else proposed
    coefficient = max(chosen['sampledCorrelation'], curve[-1]['correlation']) if fallback else chosen['interpolatedCorrelation']
    selected = next((row for row in curve if row['candidateFirstIndex'] + crop_start == chosen_start), None)
    shift = chosen_start - a
    pairs = [(pcm[i], pcm[i + shift]) for i in range(max(a, 0, -shift), min(b + 1, len(pcm), len(pcm) - shift))]
    return dict(common, timeSeconds=time, correlation=coefficient, peak=chosen['amplitudeGatePeak'],
        curvature=chosen['curvature'], observedCount=selected['observedPairCount'] if selected else 0,
        varying=bool(selected) and varying([v[0] for v in pairs]) and varying([v[1] for v in pairs]),
        support=selected['supportStatus'] if selected else 'noObservedPairs', fallback=fallback,
        synthetic=chosen['syntheticPrecedingCandidate'], required=[min(a, chosen_start - 1), max(b, chosen_start + 1 + b - a)])


def intersects(first, end, ranges):
    return any(max(first, low) < min(end, high) for low, high in ranges)


def location_reasons(time, interval, domain_end):
    return {name for name, passed in (
        ('outsideAcquisition', 0 <= time < domain_end),
        ('outsideVoicedInterval', interval[0] <= time < interval[1])) if not passed}


def voiced_intervals(pitch):
    values = pitch['frequenciesHz']
    end, step, first = (pitch[k] for k in ('domainEndSeconds', 'stepSeconds', 'firstCenterSeconds'))
    for voiced, group in itertools.groupby(range(len(values)), key=lambda i: values[i] > 0):
        members = list(group)
        if not voiced:
            continue
        left = math.fma(members[0], step, first) - .5 * step
        if left >= end - .5 * step:
            break
        right = math.fma(members[-1], step, first) + .5 * step
        if max(0., left) < min(end, right):
            yield (max(0., left), min(end, right))


def trace(case):
    pcm, pitch, known = inputs(case)
    rate, end = case['sampleRate'], pitch['domainEndSeconds']
    exclusions = case['excludedSamples']
    settings = {k: case[k] for k in ('minimumSeconds', 'maximumSeconds', 'maximumAdjacentFactor')}
    validate_period_settings(settings)
    global_peak = max(map(abs, pcm))
    attempts, nodes, raw_edges = [], [], set()
    previous_right = None
    intervals = list(voiced_intervals(pitch))

    def node(time, interval, direction, ordinal, attempt, reasons):
        identifier = len(nodes)
        nodes.append(dict(nodeID=identifier, timeSeconds=time, voicedIntervalID=interval,
            direction=direction, stepIndex=ordinal, attemptIndex=attempt, rejections=sorted(reasons)))
        return identifier

    for interval_id, interval in enumerate(intervals):
        middle = sum(interval) / 2
        frequency = stages.sampled_f0(pitch, middle, rate, len(pcm))
        if frequency is None:
            raise ValueError('Voiced interval midpoint has no F0')
        initial = seed(pcm, rate, middle, frequency)
        reasons = location_reasons(initial['timeSeconds'], interval, end)
        if initial['peak'] == 0:
            reasons.add('silence')
        elif not initial['varying']:
            reasons.add('degenerateWaveform')
        first, last = initial['required']
        if initial['observedCount'] < 3 or first < 0 or last >= len(pcm):
            reasons.add('insufficientSupport')
        if intersects(first, last + 1, exclusions):
            reasons.add('excludedSupport')
        seed_id = node(initial['timeSeconds'], interval_id, 'seed', 0, None, reasons)
        nodes[seed_id]['seedSupport'] = initial
        for sign, direction in ((-1, 'backward'), (1, 'forward')):
            anchor, previous_node = initial['timeSeconds'], seed_id
            for ordinal in range(1, MAX_ATTEMPTS + 1):
                frequency = stages.sampled_f0(pitch, anchor, rate, len(pcm))
                if frequency is None:
                    break
                if len(attempts) >= MAX_ATTEMPTS:
                    raise ValueError('Oracle trace attempt capacity exceeded')
                search = match(pcm, rate, anchor, frequency, sign, case['inputPrecision'])
                target = search['timeSeconds']
                if not finite(target) or sign * (target - anchor) <= 0:
                    raise ValueError('Oracle trace failed to progress')
                beyond = target < interval[0] if sign == -1 else target > interval[1]
                correlation_pass = search['correlation'] is not None and search['correlation'] > (.7 if beyond else .3)
                amplitude_pass = search['peak'] > .023333 * global_peak if beyond else (
                    search['peak'] == 0 or search['peak'] > .01 * global_peak)
                collision = sign == -1 and previous_right is not None and target - previous_right <= .8 / frequency
                accepted = correlation_pass and amplitude_pass and not collision
                reasons = location_reasons(target, interval, end)
                reasons.update(name for name, failed in (
                    ('lowCorrelation', not correlation_pass), ('lowAmplitude', not amplitude_pass),
                    ('priorIntervalCollision', collision), ('silence', search['support'] == 'silent'),
                    ('degenerateWaveform', search['support'] in ('varyingSupport', 'constantSupport', 'tooFewPairs') and not search['varying']),
                    ('illConditionedPeak', search['curvature'] < CURVATURE_FLOOR),
                    ('rangeFallback', search['fallback'])) if failed)
                first, last = search['required']
                if search['observedCount'] < 3 or first < 0 or last >= len(pcm):
                    reasons.add('insufficientSupport')
                if intersects(first, last + 1, exclusions):
                    reasons.add('excludedSupport')
                attempt_id = len(attempts)
                attempts.append(dict(index=attempt_id, voicedIntervalID=interval_id, direction=direction,
                    stepIndex=ordinal, fromSeconds=anchor, proposedSeconds=target, frequencyHz=frequency,
                    correlation=search['correlation'], amplitudeGatePeak=search['peak'],
                    curvature=search['curvature'], observedPairCount=search['observedCount'],
                    firstRequiredSampleIndex=first, lastRequiredSampleIndex=last,
                    selectedSyntheticCandidate=search['synthetic'], acceptedByReferenceGates=accepted,
                    usedRangeFallback=search['fallback'], rejections=sorted(reasons), mathematics=search))
                if accepted:
                    current = node(target, interval_id, direction, ordinal, attempt_id, reasons)
                    if previous_node is not None:
                        raw_edges.add(frozenset((previous_node, current)))
                    previous_node = current
                    if sign == 1:
                        previous_right = target
                else:
                    previous_node = None  # A future success cannot jump this failed edge.
                anchor = target
                if beyond:
                    break
            else:
                raise ValueError('Oracle trace failed to terminate')

    points = sorted(nodes, key=lambda p: (p['timeSeconds'], p['nodeID']))
    if any(a['timeSeconds'] == b['timeSeconds'] for a, b in zip(points, points[1:])):
        raise ValueError('Ambiguous duplicate raw points are outside this oracle catalog')
    for index, point in enumerate(points):
        point.update(index=index, runID=None)
    graph = {p['nodeID']: set() for p in points if not p['rejections']}
    for a, b in zip(points, points[1:]):
        duration = b['timeSeconds'] - a['timeSeconds']
        crossed = intersects(a['timeSeconds'], b['timeSeconds'], [(low / rate, high / rate) for low, high in exclusions])
        if (a['nodeID'] in graph and b['nodeID'] in graph and frozenset((a['nodeID'], b['nodeID'])) in raw_edges
                and not crossed and settings['minimumSeconds'] <= duration <= settings['maximumSeconds']):
            graph[a['nodeID']].add(b['nodeID'])
            graph[b['nodeID']].add(a['nodeID'])
    # Connected components, independent of the native temporal run scan.
    membership = {}
    run_count = 0
    for point in points:
        root = point['nodeID']
        if root not in graph or root in membership:
            continue
        frontier = {root}
        while frontier:
            member = frontier.pop()
            if member in membership:
                continue
            membership[member] = run_count
            frontier.update(graph[member] - membership.keys())
        run_count += 1
    for point in points:
        point['runID'] = membership.get(point['nodeID'])

    periods = []
    for index, (a, b) in enumerate(zip(points, points[1:])):
        duration = b['timeSeconds'] - a['timeSeconds']
        reasons = set(a['rejections']) | set(b['rejections'])
        if frozenset((a['nodeID'], b['nodeID'])) not in raw_edges:
            reasons.add('trackingFailure')
        if a['runID'] is None or a['runID'] != b['runID']:
            reasons.add('differentRun')
        if intersects(a['timeSeconds'], b['timeSeconds'], [(low / rate, high / rate) for low, high in exclusions]):
            reasons.add('excludedSupport')
        if duration < settings['minimumSeconds']:
            reasons.add('periodBelowMinimum')
        if duration > settings['maximumSeconds']:
            reasons.add('periodAboveMaximum')
        periods.append(dict(index=index, leftPulseIndex=index, rightPulseIndex=index + 1,
            durationSeconds=duration, runID=a['runID'] if not reasons else None, rejections=sorted(reasons)))
    pairs = []
    for index, (a, b) in enumerate(zip(periods, periods[1:])):
        ratio = max(a['durationSeconds'], b['durationSeconds']) / min(a['durationSeconds'], b['durationSeconds'])
        reasons = set(a['rejections']) | set(b['rejections'])
        if ratio > settings['maximumAdjacentFactor']:
            reasons.add('adjacentPeriodFactor')
        pairs.append(dict(index=index, leftPeriodIndex=index, rightPeriodIndex=index + 1,
                          ratio=ratio, rejections=sorted(reasons)))
    amplitudes = []
    for index, point in enumerate(points):
        value = dict(pulseIndex=index, rmsAmplitude=None, supportStartSeconds=None,
                     supportEndSeconds=None, observedSampleCount=0, rejections=[])
        if index in (0, len(points) - 1):
            value['rejections'] = ['insufficientCycles']
        elif pairs[index - 1]['rejections']:
            value['rejections'] = pairs[index - 1]['rejections']
        else:
            left, right = periods[index - 1]['durationSeconds'], periods[index]['durationSeconds']
            value.update(supportStartSeconds=point['timeSeconds'] - .2 * left,
                         supportEndSeconds=point['timeSeconds'] + .2 * right)
            amplitude = sequences.hann_rms(pcm, rate, point['timeSeconds'], left, right)
            value['observedSampleCount'] = amplitude['sampleCount']
            if amplitude['status'] == 'available':
                value['rmsAmplitude'] = amplitude['rmsAmplitude']
            else:
                reason = amplitude['reason']
                value['rejections'] = ['insufficientSupport' if reason == 'insufficientData' else reason]
        amplitudes.append(value)
    return dict(definition='decimalPulseHistoryConnectedComponents-v1', case=case, inputSamples=pcm,
        pitch=pitch, knownSourceLandmarks=known, comparison=COMPARISON,
        voicedIntervals=[list(interval) for interval in intervals], landmarks=points, attempts=attempts,
        rawTrackingEdges=sorted(sorted(edge) for edge in raw_edges), periods=periods,
        periodPairs=pairs, amplitudes=amplitudes, runCount=run_count)
