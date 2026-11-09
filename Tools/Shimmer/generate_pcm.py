#!/usr/bin/env python3
"""Generate separate PCM extraction and formula evidence using existing waveforms."""
import argparse
from pathlib import Path
import time

import pcm_catalog
import pcm_oracle
import pcm_reference
from shimmer_reference import ROOT, HERE, canonical, digest, load_json


def source_hashes():
    paths = [HERE / n for n in ('generate_pcm.py', 'verify_pcm.py', 'pcm_catalog.py', 'pcm_oracle.py',
             'pcm_reference.py', 'pcm_probe.praat', 'generate.py', 'shimmer_oracle.py',
             'shimmer_reference.py', 'shimmer_catalog.py')]
    paths += [ROOT / 'Tools/Reference' / n for n in ('common.py', 'setup.py', 'toolchain.json')]
    paths += [pcm_catalog.PULSES / 'manifest.json']
    return {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in sorted(paths)}


def assemble(case, source, reference, audit, sources):
    body = dict(schemaVersion=1, case=case, reference=reference, audit=audit, generatorSources=sources,
                inputPCM=source['pcm'], f0Contour=source['fixture']['reference']['pitch'],
                scope='Raw pinned waveform/tier statistics; explicit native source/run eligibility is additional')
    return {'fixtureIdentity': digest(canonical(body)), **body}


def case_summary(case, reference, audit):
    return dict(name=case['name'], pulseCount=reference['data']['pulseCount'],
        selectedPulseCount=len(reference['data']['selectedPulseIndices']),
        amplitudeCount=len(reference['data']['amplitudes']), queryState=reference['data']['amplitudeState'],
        maximumExtractionBudgetFraction=audit['amplitudeExtraction']['maximumBudgetFraction'],
        maximumStatisticsBudgetFraction=max((r.get('budgetFraction', 0.)
            for r in audit['statisticalComparison']['comparisons']), default=0.))


def generate(output, selected=None):
    output = Path(output).resolve()
    if output.exists() or not output.is_relative_to((ROOT / '.build').resolve()):
        raise ValueError('Use an absent PCM candidate directory under .build')
    cases = pcm_catalog.cases()
    if selected:
        if len(selected) != len(set(selected)) or not set(selected) <= {c['name'] for c in cases}:
            raise ValueError('Unknown or repeated shimmer PCM case')
        cases = [c for c in cases if c['name'] in selected]
    sources = source_hashes()
    output.mkdir(parents=True)
    files, rows, trials = {}, [], []
    for case in cases:
        started = time.perf_counter()
        source = pcm_catalog.source(case)
        external, raw = pcm_reference.evaluate(case, source)
        audit = pcm_oracle.audit(case, source, external)
        payload = assemble(case, source, external, audit, sources)
        for suffix, encoded in (('.json', canonical(payload)), ('.raw.txt', raw.encode())):
            name = case['name'] + suffix
            (output / name).write_bytes(encoded)
            files[name] = digest(encoded)
        rows.append(case_summary(case, external, audit))
        trials.append(dict(name=case['name'], seconds=time.perf_counter() - started))
        print(case['name'], 'passed', external['data']['amplitudeState'], flush=True)
    manifest = dict(schemaVersion=1, catalog=cases, files=files, generatorSources=sources,
        toolchain=load_json(ROOT / 'Tools/Reference/toolchain.json'), partialCatalog=bool(selected), results=rows)
    (output / 'manifest.json').write_bytes(canonical(manifest))
    (output / 'execution.json').write_bytes(canonical(dict(schemaVersion=1, trials=trials,
        scope='Development reference execution and independent RMS/statistics; not native performance')))
    print('SHIMMER_PCM_CANDIDATES_COMPLETE', len(cases), flush=True)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--case', action='append')
    args = parser.parse_args()
    generate(args.output, args.case)
