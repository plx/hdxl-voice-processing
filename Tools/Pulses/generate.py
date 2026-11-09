#!/usr/bin/env python3
"""Explicit candidate generation; original sources, external pulses, independent RMS."""
import argparse
import math
from pathlib import Path
import time

import catalog
import pitch_reference
import reference
import sequences
from reference import ROOT, HERE, canonical, digest, load_json

AMPLITUDE_BUDGET = {'absoluteAmplitude': 2e-12, 'relativeAmplitude': 1e-10,
                    'pulseIndicesAndTimes': 'exact-for-identical-external-landmarks'}


def generator_sources():
    paths = sorted([*[HERE / name for name in (
                       'catalog.py', 'generate.py', 'pitch_reference.py', 'reference.py',
                       'sequences.py', 'probe.praat', 'pitch.praat')],
                    ROOT / 'Tools/Reference/common.py', ROOT / 'Tools/Reference/setup.py',
                    ROOT / 'Tools/Reference/toolchain.json'])
    return {str(path.relative_to(ROOT)): digest(path.read_bytes()) for path in paths}


def case_result(case, record, audit):
    return {'name': case['name'], 'pulses': record['data']['pulseCount'],
            'amplitudes': audit['comparisons'], 'amplitudeMaximumBudgetFraction': audit['maximumBudgetFraction'],
            'outsideDomainPoints': len(record['data']['outsideDomainIndices'])}


def amplitude_audit(samples, rate, record):
    expected = sequences.reference_amplitudes(samples, rate, record['data']['pulseTimesSeconds'], record['periodSettings'])
    external = record['data']['amplitudes']
    if len(expected) != len(external):
        raise ValueError(f'Independent amplitude count differs: {len(expected)} vs {len(external)}')
    rows = []
    for a, b in zip(expected, external):
        if (a['pulseIndex'], a['timeSeconds']) != (b['pulseIndex'], b['timeSeconds']):
            raise ValueError('Independent amplitude pulse identity differs')
        tolerance = AMPLITUDE_BUDGET['absoluteAmplitude'] + AMPLITUDE_BUDGET['relativeAmplitude'] * abs(b['rmsAmplitude'])
        error = abs(a['rmsAmplitude'] - b['rmsAmplitude'])
        if not math.isfinite(error) or error > tolerance:
            raise ValueError(f'Independent amplitude differs at pulse {a["pulseIndex"]}: {error} > {tolerance}')
        rows.append({**a, 'referenceRMSAmplitude': b['rmsAmplitude'], 'absoluteError': error,
                     'budgetFraction': error / tolerance})
    return {'status': 'passed', 'comparison': AMPLITUDE_BUDGET, 'comparisons': len(rows),
            'maximumBudgetFraction': max((r['budgetFraction'] for r in rows), default=0.), 'rows': rows}


def assemble(case, known, record, f0_record, audit, sources):
    body = {'schemaVersion': 1, 'case': case, 'knownSourceLandmarks': known,
            'reference': record, 'f0Reference': f0_record, 'amplitudeAudit': audit,
            'generatorSources': sources,
            'scope': 'Raw reference pulse/amplitude conformance; native run/selection eligibility is separate'}
    if case['source']['kind'] == 'licensedSpeech':
        path = case['source']['corpusPath']
        body['licensedSource'] = {'path': path, 'sha256': digest((ROOT / path).read_bytes()),
                                  'terms': 'CC-BY-4.0; inherited approved corpus source and transformations'}
    return {'fixtureIdentity': digest(canonical(body)), **body}


def generate(output, selected=None):
    output = Path(output).resolve()
    if output.exists() or not output.is_relative_to((ROOT / '.build').resolve()):
        raise ValueError('Use an absent candidate directory under .build')
    all_cases = catalog.cases()
    if selected:
        if len(selected) != len(set(selected)) or not set(selected) <= {c['name'] for c in all_cases}:
            raise ValueError('Unknown/repeated case selection')
        all_cases = [c for c in all_cases if c['name'] in selected]
    output.mkdir(parents=True)
    sources, files, trials, results = generator_sources(), {}, [], []
    for case in all_cases:
        started = time.perf_counter()
        samples, known = catalog.source(case)
        f0_record, f0_raw = None, None
        if case['pitchSource'] == 'suppliedContour':
            pitch = catalog.supplied_pitch(case)
        else:
            f0_record, f0_raw = pitch_reference.evaluate(samples, case['sampleRate'])
            pitch = f0_record['pitch']
        record, wave, encoded_pitch, raw = reference.evaluate(
            samples, case['sampleRate'], pitch, precision=case['inputPrecision'])
        if f0_record and f0_record['directPulseTimesSeconds'] != record['data']['pulseTimesSeconds']:
            raise ValueError('Injecting the same reference F0 changed pulse locations')
        audit = amplitude_audit(samples, case['sampleRate'], record)
        payload = assemble(case, known, record, f0_record, audit, sources)
        artifacts = {'.json': canonical(payload), '.wav': wave, '.Pitch': encoded_pitch, '.raw.txt': raw.encode()}
        if f0_raw is not None:
            artifacts['.f0.raw.txt'] = f0_raw.encode()
        for suffix, data in artifacts.items():
            path = output / (case['name'] + suffix)
            path.write_bytes(data)
            files[path.name] = digest(data)
        trials.append({'name': case['name'], 'seconds': time.perf_counter() - started})
        result = case_result(case, record, audit)
        results.append(result)
        print(case['name'], result['pulses'], result['amplitudes'], flush=True)
    manifest = {'schemaVersion': 1, 'catalog': all_cases, 'files': files, 'generatorSources': sources,
                'toolchain': load_json(ROOT / 'Tools/Reference/toolchain.json'),
                'amplitudeComparison': AMPLITUDE_BUDGET, 'partialCatalog': bool(selected), 'results': results}
    (output / 'manifest.json').write_bytes(canonical(manifest))
    (output / 'execution.json').write_bytes(canonical({'schemaVersion': 1, 'trials': trials,
        'scope': 'Source generation, external reference processes and independent audit; not native timing'}))
    print('PULSE_CANDIDATES_COMPLETE', len(all_cases), flush=True)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--case', action='append')
    args = parser.parse_args()
    generate(args.output, args.case)
