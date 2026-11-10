#!/usr/bin/env python3
"""Generate independent SWIPE-prime candidates with timing-aware YIN comparison."""
import argparse
from collections import Counter
import hashlib
import importlib.util
import math
from pathlib import Path
import platform
import struct

from swipe_catalog import ROOT, cases, source_samples, target_hz, wave64
from common import canonical, load_json
from swipe_oracle import COMPARISON, PreparedOracle

_spec = importlib.util.spec_from_file_location('swipe_comparison_yin_oracle', ROOT / 'Tools/YIN/oracle.py')
yin = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(yin)

CONTRACT_COMMITS = ['1905674', 'cb037f2']
SOURCES = ['Tools/SWIPE/' + name for name in
           ('swipe_math.py', 'swipe_oracle.py', 'swipe_catalog.py', 'swipe_reference.py')]
SOURCES += ['Tools/YIN/oracle.py', 'Tools/Reference/common.py', 'Tools/Reference/toolchain.json']


def sha(data):
    return hashlib.sha256(data).hexdigest()


def reference_identity():
    hashes = {path: sha((ROOT / path).read_bytes()) for path in SOURCES}
    return {'name': 'independent-python-swipe-prime-centered', 'version': 1,
            'pythonVersion': load_json(ROOT / 'Tools/Reference/toolchain.json')['pythonVersion'],
            'implementationSHA256': sha(canonical(hashes)), 'sourceSHA256': hashes,
            'contractFreezeCommits': CONTRACT_COMMITS, 'methodDOI': '10.1121/1.2951592',
            'upstreamImplementationParity': False}


def metrics(case, rows):
    full = [r for r in rows if r['observedSampleCount'] == r['requiredSampleCount']]
    available = sum(r['frequencyHz'] is not None for r in rows)
    voiced = sum(r['status'] == 'voiced' for r in rows)
    known = known_available = gross = octave = voiced_gross = quality_misses = 0
    cents, fine = [], []
    for row in full:
        target = target_hz(case, row['startSample'], row['observedSampleCount'])
        if target is None:
            continue
        known += 1
        if row['frequencyHz'] is None:
            continue
        known_available += 1
        actual = row['frequencyHz']
        error = abs(1200 * math.log2(actual / target))
        cents.append(error)
        is_gross = abs(actual / target - 1) > COMPARISON['grossRelativeHz']
        gross += is_gross
        voiced_gross += is_gross and row['status'] == 'voiced'
        octave += is_gross and any(abs(actual / (target * factor) - 1) <=
                                  COMPARISON['octaveRelativeHz'] for factor in (.5, 2.))
        if not is_gross:
            fine.append(error)
        if case['acceptanceGroup'] == 'clean-tone':
            quality_misses += error > COMPARISON['toneQualityGoalCents']
    no_pitch = case['source']['kind'] in ('silence', 'constant', 'fricative', 'noise')
    reasons = Counter(r['reason'] for r in rows if r['reason'] is not None)
    return {
        'potentialFrameCount': len(rows), 'fullSupportFrameCount': len(full),
        'partialFrameCount': len(rows) - len(full), 'availableFrameCount': available,
        'voicedFrameCount': voiced, 'availableCoverageIncludingPartial': available / len(rows) if rows else 0.,
        'voicedCoverageIncludingPartial': voiced / len(rows) if rows else 0.,
        'voicedCoverageOfFullSupport': voiced / len(full) if full else 0.,
        'unavailabilityAndWarningReasons': dict(sorted(reasons.items())),
        'knownTargetFullSupportCount': known, 'knownTargetAvailableCount': known_available,
        'availableGrossErrorCount': gross, 'voicedGrossErrorCount': voiced_gross,
        'availableOctaveErrorCount': octave, 'fineErrorCount': len(fine),
        'meanFineAbsoluteCents': math.fsum(fine) / len(fine) if fine else None,
        'maximumFineAbsoluteCents': max(fine, default=None),
        'maximumAvailableAbsoluteCents': max(cents, default=None),
        'toneQualityGoalExceededCount': quality_misses if case['acceptanceGroup'] == 'clean-tone' else None,
        'toneQualityGoalAvailableDenominator': known_available if case['acceptanceGroup'] == 'clean-tone' else None,
        'noPitchFalseVoicedCount': voiced if no_pitch else None,
        'truthBasis': 'unknown-real-speech' if case['source']['kind'] == 'licensed-speech'
                     else 'source-law-at-support-midpoint; mixed-jump-and-inharmonic-truth-undefined',
    }


def check_acceptance(case, statistics):
    group = case['acceptanceGroup']
    if group in ('clean-tone', 'clean-harmonic'):
        budget = COMPARISON['toneMaximumCents' if group == 'clean-tone' else 'harmonicMaximumCents']
        if (statistics['voicedCoverageOfFullSupport'] < COMPARISON['cleanMinimumVoicedCoverage']
                or statistics['availableGrossErrorCount'] or statistics['availableOctaveErrorCount']
                or statistics['maximumAvailableAbsoluteCents'] is None
                or statistics['maximumAvailableAbsoluteCents'] > budget):
            raise ValueError(f'Clean-source acceptance failed: {case["name"]}: {statistics}')
    elif group in ('no-pitch', 'insufficient') and statistics['voicedFrameCount']:
        raise ValueError(f'Unexpected voiced result: {case["name"]}')


def baseline(samples, profile):
    # YIN's support can be shorter than SWIPE's requested hop at high pitch
    # floors. Keep every SWIPE configuration, and explicitly record a denser
    # valid YIN grid instead of inventing unsupported baseline measurements.
    maximum_yin_hop = 2 * math.ceil(profile['sampleRate'] / profile['pitchFloorHz']) + 1
    hop = min(profile['hopLength'], maximum_yin_hop)
    configuration = yin.configuration(
        rate=profile['sampleRate'], floor=profile['pitchFloorHz'], ceiling=profile['pitchCeilingHz'],
        hop=hop, precision=profile['inputPrecision'],
        silence=profile['silenceRMSThreshold'], backend='scalar')
    rows = []
    # Existing independent fixed-time oracle. Retain every frame, but only the
    # scalar comparison fields; YIN's stage fixtures already live under Tools/YIN.
    for raw in yin.stream(samples, configuration):
        selected = raw['selectedCandidateIndex']
        candidate = raw['candidates'][selected] if selected is not None else None
        rows.append({key: raw[key] for key in ('frameIndex', 'startSample', 'observedSampleCount',
                                             'requiredSampleCount', 'status', 'reason')}
                    | {'frequencyHz': candidate['frequencyHz'] if candidate else None,
                       'periodicity': candidate['periodicity'] if candidate else None})
    return configuration, rows


def align(swipe_rows, yin_rows, hop, rate):
    """One-to-one nearest full-support midpoints within half a hop; never index pairing.

    YIN uses an equal or shorter hop; the supplied bound is half its actual hop.
    Twice-midpoint integers preserve
    the odd-length YIN support's half-sample displacement exactly. All unmatched
    frames, including tails, stay visible and full-estimator metrics stay separate.
    """
    eligible = {i for i, r in enumerate(yin_rows) if r['observedSampleCount'] == r['requiredSampleCount']}
    pairs, matched_swipe = [], set()
    for i, row in enumerate(swipe_rows):
        if row['observedSampleCount'] != row['requiredSampleCount']:
            continue
        center = 2 * row['startSample'] + row['observedSampleCount']
        candidates = [j for j in eligible
                      if abs(2 * yin_rows[j]['startSample'] + yin_rows[j]['observedSampleCount'] - center) <= hop]
        if not candidates:
            continue
        j = min(candidates, key=lambda j: (
            abs(2 * yin_rows[j]['startSample'] + yin_rows[j]['observedSampleCount'] - center), j))
        eligible.remove(j)
        matched_swipe.add(i)
        other = yin_rows[j]
        delta = (2 * other['startSample'] + other['observedSampleCount'] - center) / 2
        overlap = max(0, min(row['startSample'] + row['observedSampleCount'],
                             other['startSample'] + other['observedSampleCount'])
                      - max(row['startSample'], other['startSample']))
        pairs.append({'swipeFrameIndex': i, 'yinFrameIndex': j,
                      'yinMinusSWIPECenterSamples': delta, 'centerDistanceSeconds': abs(delta) / rate,
                      'supportOverlapSamples': overlap,
                      'swipeSupport': {'startSample': row['startSample'], 'sampleCount': row['observedSampleCount']},
                      'yinSupport': {'startSample': other['startSample'], 'sampleCount': other['observedSampleCount']},
                      'swipeEarliestDelaySeconds': row['requiredSampleCount'] / (2 * rate),
                      'yinEarliestDelaySeconds': other['requiredSampleCount'] / (2 * rate),
                      'swipeStatus': row['status'], 'yinStatus': other['status'],
                      'swipeFrequencyHz': row['frequencyHz'], 'yinFrequencyHz': other['frequencyHz'],
                      'swipeMinusYINCents': (1200 * math.log2(row['frequencyHz'] / other['frequencyHz'])
                                            if row['frequencyHz'] is not None and other['frequencyHz'] is not None else None)})
    matched_yin = {pair['yinFrameIndex'] for pair in pairs}
    return {'policy': 'nearestObservedFullSupportMidpointWithinHalfYINHop; tiesEarlier; oneToOne',
            'maximumCenterDistanceSeconds': hop / (2 * rate),
            'matchedFrameCount': len(pairs), 'pairs': pairs,
            'unmatchedSWIPEFrameIndices': [i for i in range(len(swipe_rows)) if i not in matched_swipe],
            'unmatchedYINFrameIndices': [i for i in range(len(yin_rows)) if i not in matched_yin],
            'agreementIsAccuracy': False, 'sameHopIsSameLatency': False}


def evaluate(case, identity):
    samples, profile = source_samples(case), case['profile']
    analyzer = PreparedOracle(profile)
    rows = analyzer.stream(samples)
    statistics = metrics(case, rows)
    check_acceptance(case, statistics)
    yin_profile, yin_rows = baseline(samples, profile)
    encoded = wave64(samples, profile['sampleRate'])
    local = None if 'path' in case['source'] else 'inputs/' + case['name'] + '.wav'
    probe_indices = sorted({0, len(analyzer.kernels) // 2, len(analyzer.kernels) - 1})
    return {
        'schemaVersion': 1, **case, 'reference': identity, 'profileSHA256': sha(canonical(profile)),
        'comparisonPolicy': COMPARISON, 'geometry': analyzer.layout,
        'kernelProbes': [{'candidateIndex': i, 'coefficients': analyzer.kernels[i]} for i in probe_indices],
        'input': {'localPath': local, 'sampleRate': profile['sampleRate'], 'sampleCount': len(samples),
                  'normalizedFloat64LESHA256': sha(struct.pack(f'<{len(samples)}d', *samples)),
                  'encodedInputSHA256': sha(encoded)},
        'frames': rows, 'metrics': statistics,
        'yinComparison': {'profile': yin_profile, 'profileSHA256': sha(canonical(yin_profile)),
                          'hopPolicy': 'minimumOfSWIPERequestedHopAndYINRequiredSupport',
                          'hopAdjusted': yin_profile['hopLength'] != profile['hopLength'],
                          'frames': yin_rows, 'metrics': metrics(case, yin_rows),
                          'alignment': align(rows, yin_rows, yin_profile['hopLength'], profile['sampleRate'])},
    }, encoded


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
    files, summaries = {}, []
    for case in cases():
        record, encoded = evaluate(case, identity)
        name = case['name'] + '.json'
        raw = canonical(record) + b'\n'
        (output / name).write_bytes(raw)
        files[name] = sha(raw)
        if record['input']['localPath']:
            path = output / record['input']['localPath']
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(encoded)
            files[record['input']['localPath']] = sha(encoded)
        summaries.append({'name': case['name'], 'swipe': record['metrics'],
                          'yin': record['yinComparison']['metrics'],
                          'matchedFrameCount': record['yinComparison']['alignment']['matchedFrameCount']})
        print(f'{case["name"]}: {len(record["frames"])} SWIPE / '
              f'{len(record["yinComparison"]["frames"])} YIN frames', flush=True)
    manifest = {'schemaVersion': 1, 'reference': identity, 'comparisonPolicy': COMPARISON,
                'cases': [c['name'] for c in cases()], 'files': files, 'metrics': summaries}
    (output / 'manifest.json').write_bytes(canonical(manifest) + b'\n')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    arguments = parser.parse_args()
    generate(arguments.output)
