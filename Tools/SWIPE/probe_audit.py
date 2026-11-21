#!/usr/bin/env python3
"""Check first/middle/last benchmark outputs against independent scalar oracles.

These probes run outside measurement. They do not replace the complete staged
SWIPE fixture suite or the full-input coverage/checksum/chunk checks.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

from workloads import (ALGORITHMS, ROOT, SHARDS, expected_cases, expected_geometry,
                       pcm_samples, swipe, validate_matrix, yin)

BUDGETS = {
    'SWIPEPrime': dict(frequencyHz=swipe.COMPARISON['frequencyHzAbsolute'],
                       strength=swipe.COMPARISON['strengthAbsolute']),
    'YINFFT': dict(frequencyHz=yin.COMPARISON['frequencyHzAbsolute'],
                   strength=yin.COMPARISON['cmndAbsolute']),
}
SOURCES = (
    'Tools/SWIPE/probe_audit.py', 'Tools/SWIPE/workloads.py',
    'Tools/SWIPE/swipe_oracle.py', 'Tools/SWIPE/swipe_math.py',
    'Tools/YIN/oracle.py', 'Tools/Reference/common.py',
)


def compare_probe(actual, expected, algorithm):
    for key in ('frameIndex', 'startSample', 'observedSamples', 'status'):
        if type(actual.get(key)) is not type(expected[key]) or actual.get(key) != expected[key]:
            raise ValueError(f'Oracle probe {key} differs')
    errors = {}
    for key, budget in BUDGETS[algorithm].items():
        value, reference = actual.get(key), expected[key]
        if reference is None:
            if value is not None:
                raise ValueError(f'Oracle probe fabricated {key}')
            errors[key] = None
        else:
            if type(reference) not in (int, float) or not math.isfinite(reference):
                raise ValueError(f'Oracle produced nonfinite {key}')
            if type(value) not in (int, float) or not math.isfinite(value):
                raise ValueError(f'Oracle probe missing finite {key}')
            error = abs(value - reference)
            if error > budget:
                raise ValueError(f'Oracle probe {key} error {error} exceeds frozen budget {budget}')
            errors[key] = error
    return errors


def audit_probes(matrix, shard=None, progress=None):
    source_hashes = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCES}
    validate_matrix(matrix, shard)
    cases = expected_cases(shard)
    native = {(r['workload']['name'], r['algorithm']): r for r in matrix}
    records = []
    for name, row in cases.items():
        samples = pcm_samples(row)
        prepared = swipe.PreparedOracle(row['workload']['configuration'])
        for algorithm in ALGORITHMS:
            geometry = expected_geometry(row, algorithm)
            support, hop = geometry['supportSamples'], geometry['hopSamples']
            full = (len(samples) - support) // hop + 1
            indices = sorted({0, (full - 1) // 2, full - 1})
            comparisons = []
            for index, actual in zip(indices, native[name, algorithm]['probes']):
                start = index * hop
                pcm = samples[start:start + support]
                if algorithm == 'SWIPEPrime':
                    result = prepared.frame(pcm)
                    frequency, strength = result['frequencyHz'], result['pitchStrength']
                else:
                    # The YIN oracle evaluates scalar differences even though
                    # the selected native baseline uses the FFT implementation.
                    result = yin.frame(pcm, row['workload']['baseline']['estimator'])
                    selected = result['selectedCandidateIndex']
                    candidate = result['candidates'][selected] if selected is not None else None
                    frequency = candidate['frequencyHz'] if candidate else None
                    strength = candidate['periodicity'] if candidate else None
                expected = dict(frameIndex=index, startSample=start, observedSamples=support,
                                status=result['status'], frequencyHz=frequency, strength=strength)
                errors = compare_probe(actual, expected, algorithm)
                comparisons.append(dict(expected=expected, actual=actual, absoluteErrors=errors))
            records.append(dict(name=name, algorithm=algorithm,
                                inputSHA256=native[name, algorithm]['inputSHA256'], probes=comparisons))
            if progress is not None:
                progress(f'Oracle verified {algorithm}.{name}')
    if source_hashes != {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCES}:
        raise ValueError('Oracle or workload audit source changed during the run')
    return dict(schemaVersion=1, status='passed', shard=shard,
                workloadRows=len(records), probes=sum(len(r['probes']) for r in records),
                budgets=BUDGETS, sourceSHA256=source_hashes, rows=records,
                scope='First/middle/last full-frame scalar estimates outside measurement; '
                      'all native coverage/checksum/chunk checks remain separate. '
                      'Pitch strengths are algorithm-specific and are not probabilities.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('matrix', type=Path)
    parser.add_argument('--shard', choices=SHARDS)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    matrix = json.loads(args.matrix.read_text())
    report = audit_probes(matrix, args.shard, lambda message: print(message, file=sys.stderr, flush=True))
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    print(json.dumps({k: report[k] for k in ('status', 'workloadRows', 'probes')}))


if __name__ == '__main__':
    main()
