#!/usr/bin/env python3
"""Recompute every retained SWIPE/YIN reference cell and audit the closed inventory."""
import argparse
from pathlib import Path

from swipe_catalog import ROOT, cases
from common import canonical, load_json
from swipe_reference import evaluate, reference_identity, sha
from swipe_oracle import COMPARISON


def verify_record(record, case, identity=None):
    expected, encoded = evaluate(case, reference_identity() if identity is None else identity)
    if canonical(record) != canonical(expected):
        raise ValueError(f'Independent SWIPE-prime oracle/provenance/comparison mismatch: {case["name"]}')
    return encoded


def verify(directory):
    directory = directory.resolve()
    manifest_path = directory / 'manifest.json'
    if manifest_path.is_symlink() or manifest_path.stat().st_size > 1024 * 1024:
        raise ValueError('Invalid or oversized SWIPE manifest')
    manifest, identity, catalog = load_json(manifest_path), reference_identity(), cases()
    if (set(manifest) != {'schemaVersion', 'reference', 'comparisonPolicy', 'cases', 'files', 'metrics'}
            or type(manifest['schemaVersion']) is not int or manifest['schemaVersion'] != 1
            or canonical(manifest['reference']) != canonical(identity)
            or canonical(manifest['comparisonPolicy']) != canonical(COMPARISON)
            or manifest['cases'] != [case['name'] for case in catalog]):
        raise ValueError('Invalid SWIPE manifest identity/catalog')
    expected_files = {'manifest.json'} | {case['name'] + '.json' for case in catalog}
    expected_files |= {'inputs/' + case['name'] + '.wav' for case in catalog if 'path' not in case['source']}
    if (set(manifest['files']) != expected_files - {'manifest.json'}
            or {str(path.relative_to(directory)) for path in directory.rglob('*') if path.is_file()} != expected_files
            or any(path.is_symlink() for path in directory.rglob('*'))):
        raise ValueError('Incomplete or unexpected SWIPE inventory')
    summaries, frame_count, yin_count, matched_count = [], 0, 0, 0
    for case in catalog:
        filename = case['name'] + '.json'
        path = directory / filename
        if path.stat().st_size > 16 * 1024 * 1024:
            raise ValueError('Oversized SWIPE fixture')
        raw = path.read_bytes()
        if manifest['files'][filename] != sha(raw):
            raise ValueError('SWIPE fixture hash mismatch')
        record = load_json(path)
        if raw != canonical(record) + b'\n':
            raise ValueError('Noncanonical SWIPE fixture')
        encoded = verify_record(record, case, identity)
        local = record['input']['localPath']
        if local and ((directory / local).read_bytes() != encoded or manifest['files'][local] != sha(encoded)):
            raise ValueError('SWIPE input provenance mismatch')
        comparison = record['yinComparison']
        summaries.append({'name': case['name'], 'swipe': record['metrics'],
                          'yin': comparison['metrics'], 'matchedFrameCount': comparison['alignment']['matchedFrameCount']})
        frame_count += len(record['frames'])
        yin_count += len(comparison['frames'])
        matched_count += comparison['alignment']['matchedFrameCount']
        print(f'{case["name"]}: all stages, support, comparison and denominators verified', flush=True)
    if canonical(manifest['metrics']) != canonical(summaries):
        raise ValueError('SWIPE summary metrics mismatch')
    print(f'{len(catalog)} cases / {frame_count} SWIPE frames / {yin_count} YIN frames / '
          f'{matched_count} aligned pairs: all independent cells and inventories verified')
    return len(catalog)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', nargs='?', type=Path,
                        default=ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/SWIPE')
    verify(parser.parse_args().directory)
