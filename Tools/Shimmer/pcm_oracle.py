"""Independent cropped-neighbor RMS extraction and supplied-tier formula audits."""
import importlib.util
import math
from pathlib import Path

import shimmer_oracle

_spec = importlib.util.spec_from_file_location('shimmer_sequence_generation', Path(__file__).with_name('generate.py'))
sequence_generation = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sequence_generation)

AMPLITUDE_BUDGET = dict(absoluteAmplitude=2e-12, relativeAmplitude=1e-10,
                       pulseIndicesAndTimes='exact-for-identical-external-landmarks')


def amplitudes(case, source):
    samples, rate = source['samples'], case['sampleRate']
    times = source['fixture']['reference']['data']['pulseTimesSeconds']
    indices = [i for i, t in enumerate(times) if case['queryStartSeconds'] <= t <= case['queryEndSeconds']]
    result = []
    for li, i, ri in zip(indices, indices[1:], indices[2:]):
        p, q = times[i] - times[li], times[ri] - times[i]
        if not case['minimumPeriodSeconds'] <= p <= case['maximumPeriodSeconds']: continue
        if not case['minimumPeriodSeconds'] <= q <= case['maximumPeriodSeconds']: continue
        if max(p, q) / min(p, q) > case['maximumAdjacentPeriodFactor']: continue
        left, right = .2 * p, .2 * q
        start, end = times[i] - left, times[i] + right
        if start < 0 or end > len(samples) * (1 / rate): continue
        support = range(max(0, math.ceil(start * rate - .5)), min(len(samples), math.floor(end * rate - .5) + 1))
        if len(support) < 3: continue
        peak = max(abs(samples[j]) for j in support)
        if peak == 0: continue
        weights, energy = [], []
        for j in support:
            offset = math.fma(float(j), 1 / rate, .5 / rate) - times[i]
            width = left if offset < 0 else right
            weight = math.cos(.5 * math.pi * offset / width) ** 4
            weights.append(weight)
            energy.append((samples[j] / peak) ** 2 * weight)
        value = peak * math.sqrt(math.fsum(energy) / math.fsum(weights))
        if not math.isfinite(value) or value <= 0: raise ValueError('Independent shimmer RMS is invalid')
        result.append(dict(pulseIndex=i, timeSeconds=times[i], rmsAmplitude=value,
            supportStartSeconds=start, supportEndSeconds=end, sampleCount=len(support)))
    return result


def tier_input(case, external):
    points = external['data']['amplitudes']
    return dict(schemaVersion=1, name=case['name'],
        timesSeconds=[p['timeSeconds'] for p in points], amplitudes=[p['rmsAmplitude'] for p in points],
        domainStartSeconds=0., domainEndSeconds=case['sampleCount'] * (1 / case['sampleRate']),
        queryStartSeconds=case['queryStartSeconds'], queryEndSeconds=case['queryEndSeconds'],
        minimumPeriodSeconds=case['minimumPeriodSeconds'], maximumPeriodSeconds=case['maximumPeriodSeconds'],
        maximumAmplitudeFactor=case['maximumAmplitudeFactor'])


def audit(case, source, external):
    expected, actual = amplitudes(case, source), external['data']['amplitudes']
    if len(expected) != len(actual): raise ValueError('Independent cropped amplitude count differs')
    rows = []
    for a, b in zip(expected, actual):
        if (a['pulseIndex'], a['timeSeconds']) != (b['pulseIndex'], b['timeSeconds']):
            raise ValueError('Independent cropped amplitude identity differs')
        bound = AMPLITUDE_BUDGET['absoluteAmplitude'] + AMPLITUDE_BUDGET['relativeAmplitude'] * abs(b['rmsAmplitude'])
        error = abs(a['rmsAmplitude'] - b['rmsAmplitude'])
        if not math.isfinite(error) or error > bound: raise ValueError('Independent cropped RMS differs')
        rows.append({**a, 'referenceRMSAmplitude': b['rmsAmplitude'], 'absoluteError': error,
                     'absoluteErrorBound': bound, 'budgetFraction': error / bound})
    extraction = dict(status='passed', comparison=AMPLITUDE_BUDGET, comparisons=len(rows), rows=rows,
        maximumBudgetFraction=max((r['budgetFraction'] for r in rows), default=0.))
    tier = tier_input(case, external)
    equations = shimmer_oracle.evaluate(tier)
    if external['data']['tierValues'] is None:
        if len(external['data']['selectedPulseIndices']) >= 3 or actual:
            raise ValueError('Unjustified skipped shimmer PCM query')
        comparison = dict(status='notExecutedInsufficientPulses', comparisons=[])
    else:
        comparison = sequence_generation.audit(tier, {'data': external['data']['tierValues']}, equations)
    return dict(amplitudeExtraction=extraction, statisticalInput=tier, equations=equations, statisticalComparison=comparison)
