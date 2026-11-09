#!/usr/bin/env python3
"""Generate auditable shimmer candidates without replacing canonical fixtures."""
import argparse
import math
from pathlib import Path
import time

import shimmer_catalog
import shimmer_oracle
import shimmer_reference
from shimmer_reference import ROOT, HERE, canonical, digest, load_json


def source_hashes():
    paths = [HERE / name for name in ('generate.py', 'shimmer_catalog.py', 'shimmer_oracle.py',
                                      'shimmer_reference.py', 'verify.py')]
    paths += [ROOT / 'Tools/Reference' / name for name in ('common.py', 'setup.py', 'toolchain.json')]
    return {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in sorted(paths)}


def audit(case, external, oracle):
    # Eligibility/availability are exact decisions. Arithmetic bounds cover
    # binary64 accumulation, at most eleven terms per neighborhood, division,
    # and logarithms; the independent oracle uses exact rational algebra.
    bounds = shimmer_oracle.comparison_bounds(case, oracle)
    rows = []
    for key in shimmer_oracle.MEASUREMENTS:
        a, b = oracle['values'][key], external['data'][key]
        if (a is None) != (b is None):
            raise ValueError(f'{case["name"]}: {key} availability differs')
        if a is None:
            rows.append(dict(measurement=key, status='unavailable'))
            continue
        error, bound = abs(a - b), bounds[key]
        if not math.isfinite(error) or error > bound:
            raise ValueError(f'{case["name"]}: {key} error {error} exceeds {bound}')
        rows.append(dict(measurement=key, status='available', absoluteError=error,
                         absoluteErrorBound=bound, budgetFraction=error / bound))
    return dict(status='passed', definition='binary64-forward-error-bound-v1',
                bounds=bounds, comparisons=rows)


def assemble(case, oracle, external, comparison, sources):
    body = dict(schemaVersion=1, input=case, oracle=oracle, reference=external,
                comparison=comparison, generatorSources=sources)
    return {'fixtureIdentity': digest(canonical(body)), **body}


def case_summary(case, oracle, comparison):
    return dict(name=case['name'], selectedAmplitudeCount=oracle['selectedAmplitudeCount'],
        normalizationCount=oracle['normalizationCount'], pairCount=len(oracle['pairStartIndices']),
        apq3Count=len(oracle['apq3WindowStartIndices']), apq5Count=len(oracle['apq5WindowStartIndices']),
        apq11Count=len(oracle['apq11WindowStartIndices']),
        maximumBudgetFraction=max((r.get('budgetFraction', 0.) for r in comparison['comparisons']), default=0.))


def generate(output, selected=None):
    output = Path(output).resolve()
    if output.exists() or not output.is_relative_to((ROOT / '.build').resolve()):
        raise ValueError('Use an absent candidate directory under .build')
    cases = shimmer_catalog.cases()
    if selected:
        if len(selected) != len(set(selected)) or not set(selected) <= {c['name'] for c in cases}:
            raise ValueError('Unknown or repeated shimmer case')
        cases = [c for c in cases if c['name'] in selected]
    output.mkdir(parents=True)
    sources, files, results, trials = source_hashes(), {}, [], []
    for case in cases:
        start = time.perf_counter()
        oracle = shimmer_oracle.evaluate(case)
        external, script, raw = shimmer_reference.evaluate(case)
        comparison = audit(case, external, oracle)
        payload = assemble(case, oracle, external, comparison, sources)
        for suffix, data in [('.json', canonical(payload)), ('.praat', script.encode()), ('.raw.txt', raw.encode())]:
            name = case['name'] + suffix
            (output / name).write_bytes(data)
            files[name] = digest(data)
        results.append(case_summary(case, oracle, comparison))
        trials.append(dict(name=case['name'], seconds=time.perf_counter() - start))
        print(case['name'], 'passed', flush=True)
    manifest = dict(schemaVersion=1, catalog=cases, files=files, generatorSources=sources,
        toolchain=load_json(ROOT / 'Tools/Reference/toolchain.json'), partialCatalog=bool(selected), results=results)
    (output / 'manifest.json').write_bytes(canonical(manifest))
    (output / 'execution.json').write_bytes(canonical(dict(schemaVersion=1, trials=trials,
        scope='Development reference execution and independent equations; not native performance')))
    print('SHIMMER_CANDIDATES_COMPLETE', len(cases), flush=True)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--case', action='append')
    args = parser.parse_args()
    generate(args.output, args.case)
