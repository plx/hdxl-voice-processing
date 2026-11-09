#!/usr/bin/env python3
"""Reconstruct shimmer equations, transcripts and identities without running Praat."""
import argparse
import importlib.util
from pathlib import Path

import shimmer_catalog
import shimmer_oracle
import shimmer_reference
from shimmer_reference import ROOT, canonical, digest, load_json

_spec = importlib.util.spec_from_file_location('shimmer_fixture_generation', Path(__file__).with_name('generate.py'))
generate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(generate)


def verify(directory):
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('Expected a real shimmer fixture directory')
    manifest_path = directory / 'manifest.json'
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError('Missing shimmer manifest')
    manifest = load_json(manifest_path)
    cases = shimmer_catalog.cases()
    if manifest.get('catalog') != cases or manifest.get('partialCatalog') is not False:
        raise ValueError('Shimmer verification requires the complete canonical catalog')
    sources = generate.source_hashes()
    lock = load_json(ROOT / 'Tools/Reference/toolchain.json')
    names = {c['name'] + suffix for c in cases for suffix in ('.json', '.praat', '.raw.txt')}
    actual = {p.name for p in directory.iterdir()}
    if actual not in (names | {'manifest.json'}, names | {'manifest.json', 'execution.json'}):
        raise ValueError('Missing or extra shimmer artifacts')
    if any(p.is_symlink() or not p.is_file() for p in directory.iterdir()):
        raise ValueError('Shimmer artifacts must be ordinary files')
    if set(manifest.get('files', {})) != names:
        raise ValueError('Shimmer manifest file inventory differs')
    files, results = {}, []
    for case in cases:
        def read(suffix):
            path = directory / (case['name'] + suffix)
            raw = path.read_bytes()
            files[path.name] = digest(raw)
            if files[path.name] != manifest['files'][path.name]:
                raise ValueError(f'Shimmer artifact hash differs: {path.name}')
            return raw
        encoded = read('.praat').decode('utf-8')
        raw = read('.raw.txt').decode('utf-8')
        external = shimmer_reference.make_record(case, encoded, raw, lock)
        oracle = shimmer_oracle.evaluate(case)
        comparison = generate.audit(case, external, oracle)
        expected = generate.assemble(case, oracle, external, comparison, sources)
        if read('.json') != canonical(expected):
            raise ValueError(f'Shimmer fixture cannot be independently reconstructed: {case["name"]}')
        results.append(generate.case_summary(case, oracle, comparison))
    expected = dict(schemaVersion=1, catalog=cases, files=files, generatorSources=sources,
                    toolchain=lock, partialCatalog=False, results=results)
    if manifest_path.read_bytes() != canonical(expected):
        raise ValueError('Shimmer manifest differs from reconstructed catalog/provenance/results')
    return dict(status='passed', cases=len(cases), canonicalFiles=len(files) + 1,
        manifestSHA256=digest(manifest_path.read_bytes()), files=files,
        amplitudes=sum(r['selectedAmplitudeCount'] for r in results),
        normalizationAmplitudes=sum(r['normalizationCount'] for r in results),
        pairs=sum(r['pairCount'] for r in results), apq3Windows=sum(r['apq3Count'] for r in results),
        apq5Windows=sum(r['apq5Count'] for r in results), apq11Windows=sum(r['apq11Count'] for r in results),
        maximumBudgetFraction=max(r['maximumBudgetFraction'] for r in results))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--canonical', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    result = verify(args.directory)
    if args.canonical:
        expected = verify(args.canonical)
        if result != expected:
            raise ValueError('Candidate shimmer outputs differ from canonical fixtures')
        result['canonicalComparison'] = 'identical'
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_bytes(canonical(result))
    print('SHIMMER_VERIFICATION_PASSED', result['cases'], result['canonicalFiles'], flush=True)
