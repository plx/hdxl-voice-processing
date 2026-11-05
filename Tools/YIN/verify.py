#!/usr/bin/env python3
"""Check identities and independently recompute every retained scalar/candidate."""
import argparse
from pathlib import Path

from catalog import ROOT, cases
from common import canonical, load_json
from reference import evaluate, reference_identity, sha
import oracle


def verify_record(record, case):
    expected, encoded = evaluate(case)
    if canonical(record) != canonical(expected):
        raise ValueError(f'Independent YIN oracle or provenance mismatch: {case["name"]}')
    return encoded


def verify(directory):
    directory = directory.resolve()
    manifest = load_json(directory / 'manifest.json')
    catalog = cases()
    if (set(manifest) != {'schemaVersion', 'reference', 'comparisonPolicy', 'cases', 'files', 'metrics'}
            or type(manifest['schemaVersion']) is not int or manifest['schemaVersion'] != 1
            or canonical(manifest['reference']) != canonical(reference_identity())
            or canonical(manifest['comparisonPolicy']) != canonical(oracle.COMPARISON)
            or manifest['cases'] != [case['name'] for case in catalog]):
        raise ValueError('Invalid YIN manifest identity/catalog')
    files = {'manifest.json'}
    metrics = []
    total_frames = 0
    for case in catalog:
        filename = case['name'] + '.json'
        path = directory / filename
        if path.is_symlink() or path.stat().st_size > 8 * 1024 * 1024:
            raise ValueError('Invalid or oversized YIN fixture')
        raw = path.read_bytes()
        if manifest['files'].get(filename) != sha(raw):
            raise ValueError('YIN fixture hash mismatch')
        record = load_json(path)
        encoded = verify_record(record, case)
        files.add(filename)
        local = record['input']['localPath']
        if local:
            input_path = directory / local
            if (input_path.is_symlink() or input_path.parent.is_symlink()
                    or input_path.read_bytes() != encoded or manifest['files'].get(local) != sha(encoded)):
                raise ValueError('YIN input provenance mismatch')
            files.add(local)
        metrics.append({'name': case['name'], 'raw': record['rawMetrics'], 'tracked': record['trackedMetrics']})
        total_frames += len(record['frames'])
    if (set(manifest['files']) != files - {'manifest.json'}
            or {str(path.relative_to(directory)) for path in directory.rglob('*') if path.is_file()} != files
            or canonical(manifest['metrics']) != canonical(metrics)):
        raise ValueError('Incomplete YIN inventory or metrics')
    print(f'{len(catalog)} YIN cases / {total_frames} frames: all oracle cells and metrics verified')
    return len(catalog)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', nargs='?', type=Path,
                        default=ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/YIN')
    verify(parser.parse_args().directory)
