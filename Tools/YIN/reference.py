#!/usr/bin/env python3
"""Generate bounded independent YIN references, never from native output."""
import argparse
from collections import Counter
import hashlib
import math
from pathlib import Path
import platform
import struct

from catalog import ROOT, cases, source_samples, target_hz, wave64
from common import canonical, load_json
import oracle

CONTRACT_COMMITS = ['6c1c179', 'b2960d4', '0b3f9b6']
SOURCES = ['Tools/YIN/oracle.py', 'Tools/YIN/catalog.py', 'Tools/YIN/reference.py',
           'Tools/Reference/common.py', 'Tools/Reference/toolchain.json']


def sha(data):
    return hashlib.sha256(data).hexdigest()


def implementation_hash():
    return sha(canonical({path: sha((ROOT / path).read_bytes()) for path in SOURCES}))


def reference_identity():
    return {'name': 'independent-python-fixed-time-yin', 'version': 1,
            'pythonVersion': load_json(ROOT / 'Tools/Reference/toolchain.json')['pythonVersion'],
            'implementationSHA256': implementation_hash(), 'contractFreezeCommits': CONTRACT_COMMITS,
            'methodDOI': '10.1121/1.1458024', 'upstreamImplementationParity': False}


def metrics(case, rows, tracking=None):
    full = [i for i, row in enumerate(rows) if row['observedSampleCount'] == row['requiredSampleCount']]
    available = voiced = truth_count = known_available = gross = octave = voiced_gross = 0
    cents, fine = [], []
    reasons = Counter()
    for i, row in enumerate(rows):
        selected = row['selectedCandidateIndex'] if tracking is None else tracking[i]['selectedCandidateIndex']
        if row['reason'] is not None:
            reasons[row['reason']] += 1
        if selected is not None:
            available += 1
        if row['status'] == 'voiced':
            voiced += 1
        target = target_hz(case, row['startSample'], row['observedSampleCount'])
        if i not in full or target is None:
            continue
        truth_count += 1
        if selected is None:
            continue
        known_available += 1
        actual = row['candidates'][selected]['frequencyHz']
        error = abs(1200 * math.log2(actual / target))
        cents.append(error)
        is_gross = abs(actual / target - 1) > oracle.COMPARISON['grossRelativeHz']
        gross += is_gross
        voiced_gross += is_gross and row['status'] == 'voiced'
        octave += is_gross and any(abs(actual / (target * factor) - 1) <=
                                  oracle.COMPARISON['octaveRelativeHz'] for factor in (.5, 2.))
        if not is_gross:
            fine.append(error)
    no_pitch = case['source']['kind'] in ('silence', 'constant', 'fricative', 'noise')
    return {
        'potentialFrameCount': len(rows), 'fullSupportFrameCount': len(full),
        'partialFrameCount': len(rows) - len(full), 'availableFrameCount': available,
        'voicedFrameCount': voiced, 'availableCoverageIncludingPartial': available / len(rows) if rows else 0.,
        'voicedCoverageIncludingPartial': voiced / len(rows) if rows else 0.,
        'voicedCoverageOfFullSupport': voiced / len(full) if full else 0.,
        'unavailableReasons': dict(sorted(reasons.items())),
        'knownTargetFullSupportCount': truth_count, 'knownTargetAvailableCount': known_available,
        'availableGrossErrorCount': gross, 'voicedGrossErrorCount': voiced_gross,
        'availableOctaveErrorCount': octave, 'fineErrorCount': len(fine),
        'meanFineAbsoluteCents': math.fsum(fine) / len(fine) if fine else None,
        'maximumFineAbsoluteCents': max(fine, default=None),
        'maximumAvailableAbsoluteCents': max(cents, default=None),
        'noPitchFalseVoicedCount': voiced if no_pitch else None,
        'truthBasis': 'unknown-real-speech' if case['source']['kind'] == 'licensed-speech'
                     else 'known-source-law-at-support-midpoint-or-explicitly-undefined',
    }


def check_clean_acceptance(case, statistics):
    group = case['acceptanceGroup']
    if group in ('clean-tone', 'clean-harmonic'):
        budget = oracle.COMPARISON['toneMaximumCents' if group == 'clean-tone' else 'harmonicMaximumCents']
        if (statistics['voicedCoverageOfFullSupport'] < oracle.COMPARISON['cleanMinimumVoicedCoverage']
                or statistics['availableGrossErrorCount'] or statistics['availableOctaveErrorCount']
                or statistics['maximumAvailableAbsoluteCents'] is None
                or statistics['maximumAvailableAbsoluteCents'] > budget):
            raise ValueError(f'Precommitted clean-source acceptance failed: {case["name"]}: {statistics}')
    elif group in ('no-pitch', 'insufficient') and statistics['voicedFrameCount']:
        raise ValueError(f'Unexpected voiced result: {case["name"]}')


def evaluate(case):
    samples = source_samples(case)
    profile = case['profile']
    rows = oracle.stream(samples, profile)
    tracking = oracle.track(rows)
    raw_metrics = metrics(case, rows)
    check_clean_acceptance(case, raw_metrics)
    # Speech PCM remains in its existing separately licensed corpus, without duplication.
    local = None if 'path' in case['source'] else 'inputs/' + case['name'] + '.wav'
    encoded = wave64(samples, profile['sampleRate'])
    record = {
        'schemaVersion': 1, **case, 'reference': reference_identity(),
        'profileSHA256': sha(canonical(profile)), 'comparisonPolicy': oracle.COMPARISON,
        'input': {'localPath': local, 'sampleRate': profile['sampleRate'], 'sampleCount': len(samples),
                  'normalizedFloat64LESHA256': sha(struct.pack(f'<{len(samples)}d', *samples)),
                  'encodedInputSHA256': sha(encoded)},
        'frames': rows, 'tracker': {'definition': 'causal-yin-candidate-continuity',
                                  'schemaVersion': 1, 'continuityWeight': .05, 'frames': tracking},
        'rawMetrics': raw_metrics, 'trackedMetrics': metrics(case, rows, tracking),
    }
    return record, encoded


def generate(output):
    output = output.resolve()
    if not output.is_relative_to((ROOT / '.build').resolve()):
        raise ValueError('Generate candidates below .build; promotion is a separate reviewed action')
    if output.exists() and any(output.iterdir()):
        raise ValueError('Candidate directory must be absent or empty')
    identity = reference_identity()
    if platform.python_version() != identity['pythonVersion']:
        raise ValueError('Pinned Python version required')
    output.mkdir(parents=True, exist_ok=True)
    files = {}
    summary = []
    for case in cases():
        record, encoded = evaluate(case)
        filename = case['name'] + '.json'
        raw = canonical(record) + b'\n'
        (output / filename).write_bytes(raw)
        files[filename] = sha(raw)
        if record['input']['localPath']:
            path = output / record['input']['localPath']
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(encoded)
            files[record['input']['localPath']] = sha(encoded)
        summary.append({'name': case['name'], 'raw': record['rawMetrics'],
                        'tracked': record['trackedMetrics']})
        print(f'{case["name"]}: {len(record["frames"])} retained frames', flush=True)
    manifest = {'schemaVersion': 1, 'reference': identity, 'comparisonPolicy': oracle.COMPARISON,
                'cases': [case['name'] for case in cases()], 'files': files, 'metrics': summary}
    (output / 'manifest.json').write_bytes(canonical(manifest) + b'\n')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    arguments = parser.parse_args()
    generate(arguments.output)
