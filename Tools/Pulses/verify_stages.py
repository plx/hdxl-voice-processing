#!/usr/bin/env python3
"""Offline stage replay from original equations and retained external transcripts."""
import argparse
import contextlib
import io
from pathlib import Path
import tempfile

import f0_probe
import stage_probe
import stages
import verify
from reference import ROOT, HERE, canonical, digest, encode_pitch, finite, load_json


def verify_directory(directory, mode):
    directory = Path(directory)
    verify.check(directory.is_dir() and not directory.is_symlink(), 'Unsafe/missing stage directory')
    summary = verify.read_json(directory / 'summary.json')
    verify.check(set(summary) == {'schemaVersion', 'mode', 'cases', 'comparisons', 'results',
        'generatorSources', 'files', 'inputReferenceAudit', 'comparisonBudgets', 'scope'}, 'Unknown stage summary fields')
    verify.same(summary['schemaVersion'], 1, 'Unknown stage schema')
    verify.same(summary['mode'], mode, 'Wrong stage mode')
    verify.same(summary['generatorSources'], stage_probe.sources(), 'Stale stage sources')
    verify.same(summary['comparisonBudgets'], dict(frequencyHz=stage_probe.F0_BUDGET_HZ,
        matchingSamples=stage_probe.MATCHING_BUDGET_SAMPLES), 'Stage tolerance changed')
    verify.same(summary['scope'],
        'Independent isolated stages versus pinned transcripts; no native/full-tracker validation',
        'Stage scope changed')
    verify.check(isinstance(summary['files'], dict) and summary['files'], 'Missing stage file coverage')
    verify.check(all(type(name) is str and Path(name).name == name for name in summary['files']), 'Unsafe stage path')
    verify.check({p.name for p in directory.iterdir()} == set(summary['files']) | {'summary.json', 'execution.json'},
                 'Stage directory coverage differs')
    for name, expected in summary['files'].items():
        verify.check(digest(verify.read_bytes(directory / name)) == expected, 'Stage artifact hash differs')
    execution = verify.read_json(directory / 'execution.json')
    verify.check(set(execution) == {'seconds', 'scope'} and finite(execution['seconds']) and execution['seconds'] > 0,
                 'Invalid stage execution timing')
    verify.same(execution['scope'], 'Developer stage generation/replay; not native timing', 'Stage timing scope changed')
    return directory, summary


def verify_f0(directory):
    directory, summary = verify_directory(directory, 'f0')
    results, files = [], set()
    lock = load_json(ROOT / 'Tools/Reference/toolchain.json')
    paths = (HERE / 'f0_probe.py', HERE / 'f0_probe.praat', HERE / 'reference.py',
             ROOT / 'Tools/Reference/common.py', ROOT / 'Tools/Reference/setup.py')
    for case in stage_probe.f0_cases():
        name, pitch, rate, count, queries = (case[k] for k in
            ('name', 'pitch', 'sampleRate', 'sampleCount', 'queriesSeconds'))
        pitch_bytes = encode_pitch(pitch, rate, count)
        query_bytes = f0_probe.encode_queries(queries)
        verify.check(verify.read_bytes(directory / (name + '.Pitch')) == pitch_bytes, 'F0 input contour changed')
        verify.check(verify.read_bytes(directory / (name + '.queries.txt')) == query_bytes, 'F0 requested queries changed')
        raw = verify.read_bytes(directory / (name + '.raw.txt'))
        values = f0_probe.parse(raw.decode('utf-8'), queries)
        identity = dict(schemaVersion=1, toolchain=lock, pitch=pitch, queriesSeconds=queries,
            sampleRate=rate, sampleCount=count, pitchSHA256=digest(pitch_bytes),
            queriesSHA256=digest(query_bytes), rawSHA256=digest(raw),
            sourceSHA256={str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in paths})
        reference = dict(referenceIdentity=digest(canonical(identity)), **identity, frequenciesHz=values)
        rows = []
        for time, external in zip(queries, values):
            oracle = stages.sampled_f0(pitch, time, rate, count)
            error = abs(oracle - external) if oracle is not None and external is not None else None
            passed = (oracle is None and external is None) or (error is not None and error <= stage_probe.F0_BUDGET_HZ)
            rows.append(dict(time=time, oracle=oracle, external=external, absoluteErrorHz=error, passed=passed))
        verify.check(all(r['passed'] for r in rows), 'External F0 differs from independent equations')
        expected = dict(schemaVersion=1, case=case, reference=reference, oracle=rows,
                        maximumErrorHz=stage_probe.F0_BUDGET_HZ)
        verify.same(verify.read_json(directory / (name + '.json')), expected, 'F0 stage derived answers differ')
        results.append(dict(name=name, comparisons=len(rows), failed=[],
            maximumErrorHz=max((r['absoluteErrorHz'] or 0 for r in rows), default=0)))
        files.update(name + suffix for suffix in ('.json', '.Pitch', '.raw.txt', '.queries.txt'))
    verify.check(set(summary['files']) == files, 'F0 catalog coverage differs')
    verify.same(summary['results'], results, 'F0 summary differs')
    verify.same(summary['cases'], len(results), 'F0 case count differs')
    verify.same(summary['comparisons'], sum(r['comparisons'] for r in results), 'F0 query count differs')
    verify.same(summary['inputReferenceAudit'], None, 'Unexpected F0 reference audit')
    return dict(cases=len(results), queries=summary['comparisons'], files=len(files))


def verify_matching(directory, reference_directory):
    directory, summary = verify_directory(directory, 'matching')
    # This bounded regeneration runs only our Decimal equations and validates the
    # retained reference catalog. It cannot launch Praat or native Swift code.
    with tempfile.TemporaryDirectory(prefix='pulse-stage-replay-', dir=ROOT / '.build') as temporary:
        output = Path(temporary)
        with contextlib.redirect_stdout(io.StringIO()):
            results, audit = stage_probe.probe_matching(output, reference_directory)
        expected = {p.name for p in output.iterdir()}
        verify.check(set(summary['files']) == expected, 'Matching stage catalog coverage differs')
        for name in expected:
            verify.check(verify.read_bytes(directory / name) == (output / name).read_bytes(),
                         'Matching stage differs from independent regenerated equations/input')
    verify.same(summary['inputReferenceAudit'], audit, 'Matching input audit differs')
    verify.same(summary['results'], results, 'Matching results differ')
    verify.same(summary['cases'], len(results), 'Matching case count differs')
    verify.same(summary['comparisons'], sum(r['comparisons'] for r in results), 'Matching comparison count differs')
    verify.check(not any(r['failed'] for r in results), 'Independent matching comparison failed')
    return dict(cases=len(results), comparisons=summary['comparisons'], files=len(expected))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--f0-directory', required=True)
    parser.add_argument('--matching-directory', required=True)
    parser.add_argument('--reference-directory', required=True)
    args = parser.parse_args()
    print(canonical(dict(f0=verify_f0(args.f0_directory),
        matching=verify_matching(args.matching_directory, args.reference_directory))).decode())
