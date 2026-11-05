#!/usr/bin/env python3
"""Offline verification of CPP inputs, external trials, mathematical oracle and exceptions."""
import argparse
import math
from pathlib import Path
import re

from cpp_catalog import (ROOT, COMPARISON, SEEDS, THEIL_REFERENCE_EXCEPTIONS,
                         cases, profiles, power_cepstrum_text)
from common import canonical, load_json
from reference import FIELDS, LOCK, implementation_hash, sha, summarize

GOLDEN = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/CPP'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def validate_trial(trial, case, profile, seed):
    require(type(trial) is dict and trial.get('seed') == seed, 'Missing or reordered seed trial')
    if trial.get('failure'):
        require(case['name'] == 'very-large-power' and profile['fitMethod'] == 'completeTheilSen',
                'Unexpected external query failure')
        require(set(trial) == {'seed', 'failure', 'exitCode', 'stdoutSHA256',
                              'normalizedStderrSHA256', 'message'}, 'Malformed query failure')
        require(trial['failure'] is True and trial['exitCode'] == -6,
                'Known reference failure changed')
        require(trial['stdoutSHA256'] == sha(b'') and isinstance(trial['message'], str),
                'Unexpected reference failure output')
        message = trial['message']
        assertion = 'at line 193:\n   r[lo] >= r[hi]' if seed == 7002 else 'at line 369:\n   r[pivot] >= r[0]'
        require('"median_common.h"' in message and assertion in message
                and '$REPOSITORY/Tools/CPP/fit.praat' in message
                and str(ROOT) not in message and len(message) <= 4096,
                'Unrecognized or unsanitized reference failure')
        require(trial['normalizedStderrSHA256'] == sha(message.encode()), 'Failure digest mismatch')
    else:
        require(set(trial) == {'seed', 'rawSHA256', *FIELDS}, 'Malformed successful trial')
        require(digest(trial['rawSHA256']), 'Invalid raw output digest')
        require(all(type(trial[field]) in (int, float) and math.isfinite(trial[field])
                    for field in FIELDS), 'Nonfinite reference observation')


def verify(directory=GOLDEN):
    require(directory.is_dir() and not directory.is_symlink(), 'Missing or symlinked fixture directory')
    catalog = cases()
    expected_profiles = profiles()
    lock = load_json(LOCK)
    generator = implementation_hash()
    manifest_path = directory / 'manifest.json'
    require(not manifest_path.is_symlink(), 'Symlinked manifest')
    manifest = load_json(manifest_path)
    require(set(manifest) == {'schemaVersion', 'calibrationOnly', 'generatorSHA256',
        'referenceToolchain', 'comparisonPolicy', 'profiles', 'referenceSeeds',
        'theilReferenceExceptions', 'cases'}, 'Invalid manifest fields')
    require(type(manifest['schemaVersion']) is int and manifest['schemaVersion'] == 1 and manifest['calibrationOnly'] is False,
            'Unsupported or unapproved calibration manifest')
    require(manifest['generatorSHA256'] == generator and canonical(manifest['referenceToolchain']) == canonical(lock),
            'Stale generator or reference toolchain')
    require(canonical(manifest['comparisonPolicy']) == canonical(COMPARISON) and canonical(manifest['profiles']) == canonical(expected_profiles)
            and manifest['referenceSeeds'] == SEEDS
            and manifest['theilReferenceExceptions'] == THEIL_REFERENCE_EXCEPTIONS,
            'Comparison policy/profile/seed/exception mismatch')
    require(len(manifest['cases']) == len(catalog), 'Incomplete catalog')
    expected_files = {'manifest.json'} | {case['name'] + '.json' for case in catalog}
    require({p.name for p in directory.iterdir()} == expected_files, 'Missing or extra fixture files')
    unavailable = 0
    comparisons = 0
    exceptions = 0
    trials_count = 0
    failures = 0
    for case, entry in zip(catalog, manifest['cases']):
        path = directory / (case['name'] + '.json')
        require(not path.is_symlink(), 'Symlinked fixture')
        raw = path.read_bytes()
        data = load_json(path)
        require(set(data) == {*case.keys(), 'schemaVersion', 'calibrationOnly', 'generatorSHA256',
                'referenceToolchain', 'comparisonPolicy', 'inputSHA256', 'upstreamUnavailable', 'results'}
                | (set() if data.get('upstreamUnavailable') else {'objectSHA256'}), 'Invalid case fields')
        require(type(data['schemaVersion']) is int and data['schemaVersion'] == 1 and data['calibrationOnly'] is False
                and data['generatorSHA256'] == generator and canonical(data['referenceToolchain']) == canonical(lock)
                and canonical(data['comparisonPolicy']) == canonical(COMPARISON), 'Unapproved or stale case identity')
        require(canonical({key: data[key] for key in case}) == canonical(case), 'Input identity mismatch')
        require(data['inputSHA256'] == sha(canonical(case['power'])), 'Input digest mismatch')
        missing = all(value is None for value in case['power'])
        require(data['upstreamUnavailable'] is missing, 'Availability mismatch')
        require(canonical(entry) == canonical({'name': case['name'], 'file': path.name,
                'sha256': sha(raw), 'upstreamUnavailable': missing}), 'Manifest/file identity mismatch')
        require(raw == canonical(data) + b'\n', 'Noncanonical fixture bytes')
        if missing:
            unavailable += 1
            require(data['results'] == [], 'Unavailable input contains measurements')
            continue
        require(data['objectSHA256'] == sha(power_cepstrum_text(case)), 'Reference object mismatch')
        require(len(data['results']) == len(expected_profiles), 'Incomplete profile coverage')
        prior = []
        for profile, row in zip(expected_profiles, data['results']):
            require(canonical(row.get('profile')) == canonical(profile), 'Reordered or invalid CPP profile')
            seeds = SEEDS if profile['fitMethod'] == 'completeTheilSen' else SEEDS[:1]
            require(len(row['trials']) == len(seeds), 'Incomplete reference seed coverage')
            for trial, seed in zip(row['trials'], seeds):
                validate_trial(trial, case, profile, seed)
                trials_count += 1
                failures += bool(trial.get('failure'))
            peak = next((value['expected'] for value in prior
                         if value['profile']['interpolation'] == profile['interpolation']), None)
            expected = summarize(case, profile, row['trials'], peak)
            require(canonical(row) == canonical(expected), 'Reference summary/oracle/diagnostic mismatch')
            prior.append(expected)
            comparisons += 1
            exceptions += expected['knownReferenceException']
    report = {'cases': len(catalog), 'upstreamUnavailable': unavailable,
              'profileComparisons': comparisons, 'knownReferenceExceptions': exceptions,
              'externalTrials': trials_count, 'knownFailedTrials': failures,
              'generatorSHA256': generator}
    require((len(catalog), unavailable, comparisons, exceptions, trials_count, failures)
            == (216, 14, 1414, 32, 2222, 6), 'Reference coverage changed')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=GOLDEN)
    args = parser.parse_args()
    print(canonical(verify(args.directory)).decode())
