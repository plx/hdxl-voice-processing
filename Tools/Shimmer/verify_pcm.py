#!/usr/bin/env python3
"""Offline reconstruction of PCM query evidence and inherited input identities."""
import argparse
import importlib.util
from pathlib import Path

import pcm_catalog
import pcm_oracle
import pcm_reference
from shimmer_reference import ROOT, canonical, digest, load_json

_spec = importlib.util.spec_from_file_location('shimmer_pcm_generation', Path(__file__).with_name('generate_pcm.py'))
generate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(generate)


def verify(directory):
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir(): raise ValueError('Missing or unsafe PCM directory')
    cases = pcm_catalog.cases()
    names = {c['name'] + suffix for c in cases for suffix in ('.json', '.raw.txt')}
    actual = {p.name for p in directory.iterdir()}
    if actual not in (names | {'manifest.json'}, names | {'manifest.json', 'execution.json'}):
        raise ValueError('Missing or extra shimmer PCM artifacts')
    if any(p.is_symlink() or not p.is_file() or p.stat().st_size > 16 * 1024 * 1024 for p in directory.iterdir()):
        raise ValueError('Unsafe shimmer PCM artifacts')
    manifest_path = directory / 'manifest.json'
    manifest = load_json(manifest_path)
    if manifest.get('catalog') != cases or manifest.get('partialCatalog') is not False:
        raise ValueError('Shimmer PCM verification requires the complete canonical catalog')
    if set(manifest.get('files', {})) != names: raise ValueError('PCM manifest inventory differs')
    files, results = {}, []
    sources = generate.source_hashes()
    for case in cases:
        def read(suffix):
            path = directory / (case['name'] + suffix)
            raw = path.read_bytes()
            files[path.name] = digest(raw)
            if files[path.name] != manifest['files'][path.name]: raise ValueError('PCM artifact hash differs: ' + path.name)
            return raw
        source = pcm_catalog.source(case)
        raw = read('.raw.txt').decode('utf-8')
        external = pcm_reference.make_record(case, source, raw)
        audit = pcm_oracle.audit(case, source, external)
        expected = generate.assemble(case, source, external, audit, sources)
        if read('.json') != canonical(expected): raise ValueError('PCM fixture cannot be independently reconstructed: ' + case['name'])
        results.append(generate.case_summary(case, external, audit))
    expected = dict(schemaVersion=1, catalog=cases, files=files, generatorSources=sources,
        toolchain=load_json(ROOT / 'Tools/Reference/toolchain.json'), partialCatalog=False, results=results)
    if manifest_path.read_bytes() != canonical(expected): raise ValueError('Reconstructed PCM manifest differs')
    return dict(status='passed', cases=len(cases), canonicalFiles=len(files) + 1,
        manifestSHA256=digest(manifest_path.read_bytes()), files=files,
        amplitudes=sum(r['amplitudeCount'] for r in results),
        executedQueries=sum(r['queryState'] == 'complete' for r in results),
        skippedInsufficientPulses=sum(r['queryState'] == 'insufficientPulses' for r in results),
        maximumExtractionBudgetFraction=max(r['maximumExtractionBudgetFraction'] for r in results),
        maximumStatisticsBudgetFraction=max(r['maximumStatisticsBudgetFraction'] for r in results))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--canonical', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = verify(args.directory)
    if args.canonical:
        if report != verify(args.canonical): raise ValueError('PCM candidates differ from canonical evidence')
        report['canonicalComparison'] = 'identical'
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_bytes(canonical(report))
    print('SHIMMER_PCM_VERIFICATION_PASSED', report['cases'], report['canonicalFiles'], flush=True)
