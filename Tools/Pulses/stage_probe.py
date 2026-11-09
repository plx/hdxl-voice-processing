#!/usr/bin/env python3
"""Explicit, unpromoted pulse-stage evidence from equations and pinned transcripts."""
import argparse
import math
from pathlib import Path
import time

import catalog
import f0_probe
import stages
import verify
from reference import ROOT, HERE, canonical, digest, encode_pitch, load_json

F0_BUDGET_HZ = 1e-10
MATCHING_BUDGET_SAMPLES = 2e-10


def sources():
    names = ('stages.py', 'stage_probe.py', 'f0_probe.py', 'f0_probe.praat',
             'catalog.py', 'reference.py', 'verify.py', 'generate.py', 'sequences.py')
    paths = [*[HERE / name for name in names], ROOT / 'Tools/Reference/common.py',
             ROOT / 'Tools/Reference/setup.py', ROOT / 'Tools/Reference/toolchain.json']
    return {str(path.relative_to(ROOT)): digest(path.read_bytes()) for path in paths}


def f0_cases():
    for grid, end, first, step, count in [('binary', .125, .03125, .03125, 500), ('decimal', .1, .025, .025, 400)]:
        for frequencies in ([100., 200., 300.], [100., 0., 300.], [0., 200., 300.], [100., 200., 0.], [0., 0., 0.]):
            pitch = dict(domainEndSeconds=end, firstCenterSeconds=first, stepSeconds=step,
                         ceilingHz=900., frequenciesHz=frequencies)
            values = {-.001, 0., end, end + .001}
            for i in range(3):
                center = math.fma(float(i), step, first)
                values.update([center, center - .25 * step, center + .25 * step])
                for boundary in (center - .5 * step, center + .5 * step):
                    values.update([math.nextafter(boundary, -math.inf), boundary, math.nextafter(boundary, math.inf)])
            yield {'name': grid + '-' + '-'.join(str(int(x)) for x in frequencies),
                   'pitch': pitch, 'sampleRate': 4000, 'sampleCount': count, 'queriesSeconds': sorted(values)}


def probe_f0(output):
    results = []
    for case in f0_cases():
        name, pitch, rate, count, queries = (case[k] for k in ('name', 'pitch', 'sampleRate', 'sampleCount', 'queriesSeconds'))
        record, raw = f0_probe.evaluate(pitch, rate, count, queries)
        expected = [stages.sampled_f0(pitch, t, rate, count) for t in queries]
        rows = []
        for query, a, b in zip(queries, expected, record['frequenciesHz']):
            error = abs(a - b) if a is not None and b is not None else None
            passed = (a is None and b is None) or (error is not None and error <= F0_BUDGET_HZ)
            rows.append(dict(time=query, oracle=a, external=b, absoluteErrorHz=error, passed=passed))
        payload = dict(schemaVersion=1, case=case, reference=record, oracle=rows, maximumErrorHz=F0_BUDGET_HZ)
        (output / (name + '.json')).write_bytes(canonical(payload))
        (output / (name + '.raw.txt')).write_text(raw)
        (output / (name + '.Pitch')).write_bytes(encode_pitch(pitch, rate, count))
        (output / (name + '.queries.txt')).write_bytes(f0_probe.encode_queries(queries))
        results.append(dict(name=name, comparisons=len(rows),
                            maximumErrorHz=max((r['absoluteErrorHz'] or 0 for r in rows), default=0),
                            failed=[r for r in rows if not r['passed']]))
        print(name, len(rows), len(results[-1]['failed']), flush=True)
    return results, None


def probe_matching(output, reference_directory):
    reference_directory = Path(reference_directory)
    reference_audit = verify.verify(reference_directory)
    results = []
    for case in catalog.cases():
        if not case['name'].startswith('gaussian-'):
            continue
        record = load_json(reference_directory / (case['name'] + '.json'))
        pcm, _ = catalog.source(case)
        pulses = record['reference']['data']['pulseTimesSeconds']
        rate = case['sampleRate']
        step, first, period = 1 / rate, .5 / rate, 1 / case['source']['frequencyHz']
        for index, direction in [(1, -1), (len(pulses) // 4, -1), (3 * len(pulses) // 4, 1), (len(pulses) - 2, 1)]:
            anchor = pulses[index]
            bounds = sorted([anchor + direction * .8 * period, anchor + direction * 1.25 * period])
            a = stages.sampled_indices(anchor - .5 * period, first, step)['nearest']
            b = stages.sampled_indices(anchor + .5 * period, first, step)['nearest']
            low = stages.sampled_indices(bounds[0] - .5 * period, first, step)['low']
            high = stages.sampled_indices(bounds[1] - .5 * period, first, step)['high']
            start = max(0, min(a, low))
            end = min(len(pcm), max(b, high + b - a) + 1)
            curve = stages.correlation_curve(pcm[start:end], a - start, b - start, low - start, high - start,
                                             precision=case['inputPrecision'])
            peak = stages.select_correlation_peak(curve)
            if peak['status'] != 'selected':
                raise ValueError('Known train has no matching peak')
            predicted = math.fma(peak['fractionalCandidateFirstIndex'] + start - a, step, anchor)
            if not bounds[0] <= predicted <= bounds[1]:
                raise ValueError('Known train required a fallback')
            external = pulses[index + direction]
            error = abs(predicted - external) * rate
            name = case['name'] + f'-anchor{index}-direction{direction}'
            payload = dict(schemaVersion=1, name=name, caseName=case['name'], inputPrecision=case['inputPrecision'],
                sampleRate=rate, sourceReferenceIdentity=record['reference']['referenceIdentity'],
                cropFirstSampleIndex=start, inputSamples=pcm[start:end], anchorFirstIndex=a - start,
                anchorLastIndex=b - start, candidateFirstIndex=low - start, candidateLastIndex=high - start,
                anchorSeconds=anchor, searchBoundsSeconds=bounds, curve=curve, selected=peak,
                predictedTimeSeconds=predicted, referenceTimeSeconds=external, absoluteErrorSamples=error,
                maximumErrorSamples=MATCHING_BUDGET_SAMPLES)
            (output / (name + '.json')).write_bytes(canonical(payload))
            results.append(dict(name=name, comparisons=1, maximumErrorSamples=error,
                                failed=[] if error <= MATCHING_BUDGET_SAMPLES else [dict(errorSamples=error)]))
            print(name, error, flush=True)
    return results, reference_audit


def generate(output, mode, reference_directory=None):
    if mode not in ('f0', 'matching') or (mode == 'matching') != (reference_directory is not None):
        raise ValueError('Matching mode requires reference-directory; F0 mode does not use one')
    output = Path(output).resolve()
    if output.exists() or not output.is_relative_to((ROOT / '.build').resolve()):
        raise ValueError('Use an absent output directory under .build')
    output.mkdir(parents=True)
    started = time.perf_counter()
    results, audit = probe_f0(output) if mode == 'f0' else probe_matching(output, reference_directory)
    files = {p.name: digest(p.read_bytes()) for p in sorted(output.iterdir())}
    summary = dict(schemaVersion=1, mode=mode, cases=len(results), comparisons=sum(r['comparisons'] for r in results),
                   results=results, generatorSources=sources(), files=files, inputReferenceAudit=audit,
                   comparisonBudgets=dict(frequencyHz=F0_BUDGET_HZ, matchingSamples=MATCHING_BUDGET_SAMPLES),
                   scope='Independent isolated stages versus pinned transcripts; no native/full-tracker validation')
    (output / 'summary.json').write_bytes(canonical(summary))
    (output / 'execution.json').write_bytes(canonical(dict(seconds=time.perf_counter() - started,
        scope='Developer stage generation/replay; not native timing')))
    if any(r['failed'] for r in results):
        raise ValueError('Stage comparison failed; retained evidence in output directory')
    print('PULSE_STAGE_PROBES_PASSED', mode, summary['comparisons'], flush=True)
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', required=True, choices=('f0', 'matching'))
    parser.add_argument('--output', required=True)
    parser.add_argument('--reference-directory')
    args = parser.parse_args()
    generate(args.output, args.mode, args.reference_directory)
