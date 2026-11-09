#!/usr/bin/env python3
"""Generate explicit candidate fixtures, auditing all five queries before writing."""
import argparse
import math
from pathlib import Path
import time

import jitter_catalog
import jitter_oracle
import jitter_reference
from jitter_reference import ROOT, HERE, canonical, digest, load_json


def source_hashes():
    paths = [HERE / name for name in ('generate.py', 'jitter_catalog.py', 'jitter_oracle.py', 'jitter_reference.py', 'verify.py')]
    paths += [ROOT / 'Tools/Reference' / name for name in ('common.py', 'setup.py', 'toolchain.json')]
    return {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in sorted(paths)}


def audit(case, external, oracle):
    data = external['data']
    if data['periodCount'] != oracle['meanPeriodCount']:
        raise ValueError(f'{case["name"]}: mean-period membership count differs')
    # A conservative forward-error allowance for binary64 sums and up to five
    # terms per neighborhood, followed by mean/normalization divisions. Input
    # point subtraction and ratio eligibility are identical binary64 operations;
    # status and denominator count are exact, never tolerance-based.
    size = max(1, len(case['pointsSeconds']))
    maximum = max((p['seconds'] for p in oracle['periods'] if p['selected'] and p['withinBounds']), default=0.)
    gamma = 8 * math.ulp(1.) * (size + 32)
    mean = oracle['meanPeriodSeconds']
    bounds = {'seconds': gamma * maximum, 'fraction': gamma * (1 + maximum / mean) if mean else 0.}
    rows = []
    for key in ('meanPeriod', *jitter_oracle.MEASUREMENTS):
        a = mean if key == 'meanPeriod' else oracle['values'][key]
        b = data[key]
        if (a is None) != (b is None):
            raise ValueError(f'{case["name"]}: {key} availability differs')
        if a is None:
            rows.append({'measurement': key, 'status': 'unavailable'})
            continue
        bound = bounds['seconds' if key in ('meanPeriod', 'absolute') else 'fraction']
        error = abs(a - b)
        if not math.isfinite(error) or error > bound:
            raise ValueError(f'{case["name"]}: {key} error {error} exceeds {bound}')
        rows.append({'measurement': key, 'status': 'available', 'absoluteError': error,
                     'absoluteErrorBound': bound, 'budgetFraction': error / bound if bound else 0.})
    if data['rap'] is not None and data['ddp'] != 3 * data['rap']:
        raise ValueError('Pinned reference DDP is not exactly three times RAP')
    return {'status': 'passed', 'definition': 'binary64-forward-error-bound-v1',
            'meanPeriodCountMatches': True, 'bounds': bounds, 'comparisons': rows}


def assemble(case, oracle, external, comparison, sources):
    body = {'schemaVersion': 1, 'input': case, 'oracle': oracle, 'reference': external,
            'comparison': comparison, 'generatorSources': sources}
    return {'fixtureIdentity': digest(canonical(body)), **body}


def case_summary(case, oracle, comparison):
    return {'name': case['name'], 'meanPeriodCount': oracle['meanPeriodCount'],
            'pairCount': len(oracle['pairIndices']), 'rapCount': len(oracle['rapWindowStartIndices']),
            'ppq5Count': len(oracle['ppq5WindowStartIndices']),
            'maximumBudgetFraction': max((r.get('budgetFraction', 0.) for r in comparison['comparisons']), default=0.)}


def generate(output, selected=None):
    output = Path(output).resolve()
    if output.exists() or not output.is_relative_to((ROOT / '.build').resolve()):
        raise ValueError('Use an absent candidate directory under .build')
    cases = jitter_catalog.cases()
    if selected:
        if len(selected) != len(set(selected)) or not set(selected) <= {c['name'] for c in cases}:
            raise ValueError('Unknown or repeated jitter case')
        cases = [c for c in cases if c['name'] in selected]
    output.mkdir(parents=True)
    sources, files, results, trials = source_hashes(), {}, [], []
    for case in cases:
        start = time.perf_counter()
        oracle = jitter_oracle.evaluate(case)
        external, script, raw = jitter_reference.evaluate(case)
        comparison = audit(case, external, oracle)
        payload = assemble(case, oracle, external, comparison, sources)
        for suffix, data in [('.json', canonical(payload)), ('.praat', script.encode()), ('.raw.txt', raw.encode())]:
            name = case['name'] + suffix
            (output / name).write_bytes(data)
            files[name] = digest(data)
        results.append(case_summary(case, oracle, comparison))
        trials.append({'name': case['name'], 'seconds': time.perf_counter() - start})
        print(case['name'], 'passed', flush=True)
    manifest = {'schemaVersion': 1, 'catalog': cases, 'files': files, 'generatorSources': sources,
                'toolchain': load_json(ROOT / 'Tools/Reference/toolchain.json'),
                'partialCatalog': bool(selected), 'results': results}
    (output / 'manifest.json').write_bytes(canonical(manifest))
    (output / 'execution.json').write_bytes(canonical({'schemaVersion': 1, 'trials': trials,
        'scope': 'Development reference execution and independent equations; not native performance'}))
    print('JITTER_CANDIDATES_COMPLETE', len(cases), flush=True)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--case', action='append')
    args = parser.parse_args()
    generate(args.output, args.case)
