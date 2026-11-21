#!/usr/bin/env python3
"""Audit complete native SWIPE-prime evidence against independently pinned coverage."""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FRACTIONS = tuple('maximum' + stage + 'BudgetFraction' for stage in
                  ('Frequency', 'Kernel', 'Loudness', 'Magnitude', 'Strength'))
COUNTS = ('frameCount', 'kernelCells', 'loudnessCells', 'magnitudeCells', 'strengthCells',
          'streamDeliveryVariants', 'streamFramesCompared')


def expected_rows(directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    if len(manifest['cases']) != 74 or len(set(manifest['cases'])) != 74:
        raise ValueError('Incomplete independent SWIPE catalog')
    expected = {}
    for name in manifest['cases']:
        raw = (directory / (name + '.json')).read_bytes()
        if hashlib.sha256(raw).hexdigest() != manifest['files'][name + '.json']:
            raise ValueError('Independent SWIPE fixture hash mismatch')
        fixture = json.loads(raw)
        frames = fixture['frames']
        full = [f for f in frames if f['observedSampleCount'] == f['requiredSampleCount']]
        windows = [w for f in frames for w in f['windows']]
        expected[name] = dict(
            name=name, profileSHA256=fixture['profileSHA256'],
            inputSHA256=fixture['input']['normalizedFloat64LESHA256'],
            precision=fixture['profile']['inputPrecision'], frameCount=len(frames),
            kernelCells=len(full) * sum(len(p['coefficients']) for p in fixture['kernelProbes']),
            loudnessCells=sum(len(w['loudness']) for w in windows),
            magnitudeCells=sum(len(w['magnitude']) for w in windows),
            strengthCells=sum(len(f['candidateStrengths']) for f in frames)
                + sum(len(w['strengths']) for w in windows),
            streamDeliveryVariants=2, streamFramesCompared=2 * len(frames))
    return expected


def audit(rows, expected):
    if not isinstance(rows, list) or len(rows) != len(expected):
        raise ValueError('Missing or extra native SWIPE cases')
    seen = set()
    maxima = dict.fromkeys(FRACTIONS, 0.0)
    for row in rows:
        if not isinstance(row, dict) or row.get('name') not in expected or row['name'] in seen:
            raise ValueError('Unknown or duplicate native SWIPE case')
        name = row['name']
        seen.add(name)
        reference = expected[name]
        if set(row) != set(reference) | set(FRACTIONS) | {'preparedBufferBytes'}:
            raise ValueError('Missing or unexpected native SWIPE evidence fields')
        if any(type(row[k]) is not int or row[k] < 0 for k in COUNTS):
            raise ValueError('Invalid native SWIPE coverage counts')
        if any(row[k] != value for k, value in reference.items()):
            raise ValueError('Native SWIPE identity or coverage differs from independent reference')
        if type(row['preparedBufferBytes']) is not int or not 0 < row['preparedBufferBytes'] < 64 * 1024 * 1024:
            raise ValueError('Missing or unbounded prepared native SWIPE storage')
        for key in FRACTIONS:
            value = row[key]
            if type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1:
                raise ValueError('Native SWIPE mismatch exceeds its frozen numerical budget')
            maxima[key] = max(maxima[key], value)
    if seen != set(expected):
        raise ValueError('Missing native SWIPE case')
    return dict(status='passed', cases=len(rows),
                directFrames=sum(r['frameCount'] for r in rows),
                streamedFrames=sum(r['streamFramesCompared'] for r in rows),
                intermediateCells={k: sum(r[k] for r in rows) for k in COUNTS if k.endswith('Cells')},
                maximumBudgetFractions=maxima,
                interpretation='Complete native test evidence; not device or performance evidence')


def corruption_controls(rows, expected):
    variants = [rows[:-1], rows + [rows[0]]]
    duplicate = copy.deepcopy(rows)
    duplicate[-1] = copy.deepcopy(rows[0])
    variants.append(duplicate)
    for key in ('profileSHA256', 'inputSHA256', 'precision'):
        changed = copy.deepcopy(rows)
        changed[0][key] = 'wrong'
        variants.append(changed)
    for key in COUNTS:
        changed = copy.deepcopy(rows)
        changed[0][key] += 1
        variants.append(changed)
    for key in FRACTIONS:
        for value in (1.01, -1, float('nan'), float('inf'), True):
            changed = copy.deepcopy(rows)
            changed[0][key] = value
            variants.append(changed)
    for key, value in [('preparedBufferBytes', 0), ('preparedBufferBytes', 64 * 1024 * 1024),
                       ('frameCount', True), ('streamDeliveryVariants', False)]:
        changed = copy.deepcopy(rows)
        changed[0][key] = value
        variants.append(changed)
    for changed in variants:
        try:
            audit(changed, expected)
        except ValueError:
            continue
        raise ValueError('Corrupted native SWIPE evidence was accepted')
    return len(variants)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native', type=Path)
    parser.add_argument('--fixtures', type=Path, default=ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/SWIPE')
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--corruption-controls', action='store_true')
    args = parser.parse_args()
    rows, expected = json.loads(args.native.read_text()), expected_rows(args.fixtures)
    result = audit(rows, expected)
    result['nativeReportSHA256'] = hashlib.sha256(args.native.read_bytes()).hexdigest()
    if args.corruption_controls:
        result['rejectedCorruptionControls'] = corruption_controls(rows, expected)
    args.report.write_text(json.dumps(result, sort_keys=True, indent=2, allow_nan=False) + '\n')
    print(json.dumps(result, sort_keys=True, allow_nan=False))
