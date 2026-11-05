#!/usr/bin/env python3
"""Verify masking fixture identities, inputs, dimensions and negative-case receipts offline."""
import argparse
import math
from pathlib import Path
import re
import struct

from catalog import ROOT, COMPARISON, cases, source_samples, wave64
from common import canonical, load_json
from reference import LOCK, implementation_hash, sha

GOLDEN = ROOT/'Tests/HDXLVoiceProcessingTests/Fixtures/Masks'


def require(condition, message):
    if not condition: raise ValueError(message)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def digest(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def verify_tiers(tiers, duration, enabled):
    expected = ['union', 'silences', 'VAD'] if enabled else ['VAD']
    require(type(tiers) is list and [tier['name'] for tier in tiers] == expected, 'Unexpected tier set')
    for tier in tiers:
        require(set(tier) == {'name', 'intervals'} and type(tier['intervals']) is list and tier['intervals'], 'Malformed tier')
        cursor = 0.
        for part in tier['intervals']:
            require(set(part) == {'startSeconds', 'endSeconds', 'isSpeech'}, 'Unknown interval field')
            a,b = part['startSeconds'],part['endSeconds']
            require(finite(a) and finite(b) and a == cursor and a < b <= duration+1e-12
                    and type(part['isSpeech']) is bool, 'Invalid interval partition')
            cursor = b
        require(abs(cursor-duration) <= 1e-12, 'Incomplete interval partition')


def verify(directory=GOLDEN):
    require(directory.is_dir() and not directory.is_symlink(), 'Missing or symlinked fixture directory')
    require(not any(path.is_symlink() for path in directory.rglob('*')), 'Symlinked fixture artifact')
    manifest = load_json(directory/'manifest.json')
    require(set(manifest) == {'schemaVersion', 'generatorSHA256', 'referenceToolchain', 'comparisonPolicy', 'cases', 'negativeCases'}, 'Unexpected manifest fields')
    require(type(manifest['schemaVersion']) is int and manifest['schemaVersion'] == 1, 'Unsupported manifest schema')
    generator = implementation_hash()
    lock = load_json(LOCK)
    require(manifest['generatorSHA256'] == generator, 'Stale mask generator')
    require(canonical(manifest['referenceToolchain']) == canonical(lock), 'Stale reference pin')
    require(canonical(manifest['comparisonPolicy']) == canonical(COMPARISON), 'Changed frozen budgets')
    catalog = cases()
    require([entry['name'] for entry in manifest['cases']] == [case['name'] for case in catalog], 'Missing or reordered cases')
    files = {'manifest.json', 'reference-anomalies.json'}
    frames = 0
    for entry, case in zip(manifest['cases'], catalog):
        filename = case['name']+'.json'
        require(set(entry) == {'name', 'file', 'sha256'} and entry['file'] == filename, 'Unexpected fixture entry')
        raw = (directory/filename).read_bytes()
        require(digest(entry['sha256']) and sha(raw) == entry['sha256'], 'Fixture hash mismatch')
        record = load_json(directory/filename)
        files.add(filename)
        require(set(record) == {'schemaVersion', 'generatorSHA256', 'comparisonPolicy', 'referenceToolchain',
            'name', 'source', 'profile', 'input', 'axes', 'spectra', 'flatness', 'referenceIntensityDB',
            'intensityExpectedSource', 'tiers', 'externalReceipt', 'externalOutputSHA256',
            'independentFlatnessMaximumBudgetFraction'}, 'Unexpected fixture fields')
        require(type(record['schemaVersion']) is int and record['schemaVersion'] == 1, 'Unsupported fixture schema')
        require(record['generatorSHA256'] == generator and record['name'] == case['name'], 'Wrong fixture identity')
        for key, expected in [('source', case['source']), ('profile', case['profile']), ('comparisonPolicy', COMPARISON), ('referenceToolchain', lock)]:
            require(canonical(record[key]) == canonical(expected), f'Changed {key}')
        samples, rate = source_samples(case)
        encoded = wave64(samples, rate)
        local = None if 'path' in case['source'] else 'inputs/'+case['name']+'.wav'
        expected_input = {'sampleRate': rate, 'sampleCount': len(samples), 'localPath': local,
            'normalizedFloat64LESHA256': sha(struct.pack(f'<{len(samples)}d', *samples)),
            'encodedReferenceInputSHA256': sha(encoded)}
        require(canonical(record['input']) == canonical(expected_input), 'Input provenance mismatch')
        if local:
            require((directory/local).read_bytes() == encoded, 'Original fixture PCM differs from generator')
            files.add(local)
        axes = record['axes']
        require(set(axes) == {'minimumTime', 'maximumTime', 'frameCount', 'hop', 'firstCenter',
            'frequencyBinCount', 'frequencyStep', 'firstFrequency', 'maximumFrequency'}, 'Unexpected axes')
        require(all(finite(value) for value in axes.values()), 'Nonfinite axes')
        count, bins = axes['frameCount'], axes['frequencyBinCount']
        require(type(count) is int and 1 <= count <= 10000 and type(bins) is int and 1 <= bins <= 8192, 'Invalid dimensions')
        duration = len(samples)/rate
        require(axes['minimumTime'] == 0 and abs(axes['maximumTime']-duration) <= 1e-12
            and axes['hop'] == case['profile']['hopSeconds'] and axes['frequencyStep'] > 0,
            'Invalid physical axes')
        require(0 < axes['firstCenter'] < duration and axes['firstCenter']+(count-1)*axes['hop'] < duration,
                'Frame centers outside original source')
        frames += count
        require(len(record['flatness']) == count and all(finite(value) for value in record['flatness']), 'Invalid flatness vector')
        enabled = case['profile']['relativeIntensityThresholdDB'] is not None
        require(len(record['referenceIntensityDB']) == (count if enabled else 0)
                and all(finite(value) for value in record['referenceIntensityDB']), 'Invalid intensity vector')
        require(record['intensityExpectedSource'] == 'independent-piecewise-linear-integration-of-external-spectral-powers', 'Intensity source identity changed')
        indices = sorted({0,min(1,count-1),count//4,count//2,3*count//4,max(0,count-2),count-1})
        require([row['frameIndex'] for row in record['spectra']] == indices, 'Selected spectrum indices changed')
        for row in record['spectra']:
            require(set(row) == {'frameIndex', 'powers'} and len(row['powers']) == bins
                    and all(finite(value) and value >= 0 for value in row['powers']), 'Invalid spectral power vector')
        verify_tiers(record['tiers'], duration, enabled)
        receipt = record['externalReceipt']
        require(set(receipt) == {'timedOut', 'stdoutSHA256', 'warning'} and receipt['timedOut'] is False
                and receipt['stdoutSHA256'] == sha(b'stages-complete\ncomplete\n'), 'Invalid successful reference receipt')
        warning = receipt['warning']
        require(type(warning) is str and (not warning or re.fullmatch(r'Warning: The loudest and softest part in your sound differ by only [0-9.eE+\-]+ dB\.', warning)), 'Unexpected reference warning')
        hashes = record['externalOutputSHA256']
        require(set(hashes) == {'spectrogram-before', 'spectrogram-after', 'flatness', 'textgrid'}
                and all(digest(value) for value in hashes.values()), 'Missing raw reference hashes')
        agreement = record['independentFlatnessMaximumBudgetFraction']
        require(finite(agreement) and 0 <= agreement <= 1, 'Independent flatness oracle failed')
    negative = manifest['negativeCases']
    require(type(negative) is dict and set(negative) == {'file', 'sha256'}
            and negative['file'] == 'reference-anomalies.json', 'Missing explicit negative cases')
    negative_bytes = (directory/negative['file']).read_bytes()
    require(digest(negative['sha256']) and sha(negative_bytes) == negative['sha256'], 'Negative case hash mismatch')
    evidence = load_json(directory/negative['file'])
    require(set(evidence) == {'schemaVersion', 'decisionIssue', 'cases'} and type(evidence['schemaVersion']) is int
            and evidence['schemaVersion'] == 1 and evidence['decisionIssue'] == 109, 'Invalid anomaly record')
    names = ['row-one-mutation', 'short-interval-timeout', 'short-interval-early-return']
    require([case['name'] for case in evidence['cases']] == names, 'Anomaly inventory changed')
    for anomaly in evidence['cases']:
        samples,rate = source_samples(anomaly)
        require(anomaly['encodedInputSHA256'] == sha(wave64(samples,rate)), 'Anomaly input hash changed')
        require(all(digest(value) for value in anomaly['externalOutputSHA256'].values()), 'Invalid anomaly output hash')
        if anomaly['name'] == names[0]:
            require(anomaly['changedSpectrogramRows'] == [1]
                and finite(anomaly['immutableInputMaximumAbsoluteDifference']) and anomaly['immutableInputMaximumAbsoluteDifference'] > 1e-6
                and finite(anomaly['mutationOracleMaximumBudgetFraction']) and 0 <= anomaly['mutationOracleMaximumBudgetFraction'] <= 1
                and anomaly['nativeDisposition'] == 'invalidConfiguration', 'Row-1 anomaly not reproduced')
        elif anomaly['name'] == names[1]:
            require(anomaly['receipt'] == {'timedOut': True, 'timeoutSeconds': 5, 'completedStages': 'spectrogram-and-flatness'}
                    and anomaly['nativeDisposition'] == 'insufficientData', 'Nontermination receipt changed')
        else:
            require(anomaly['tiers'] == [{'name': 'VAD', 'intervals': [{'startSeconds': 0, 'endSeconds': .06, 'isSpeech': True}]}]
                    and anomaly['nativeDisposition'] == 'insufficientData', 'Early-return anomaly changed')
    actual_files = {str(path.relative_to(directory)) for path in directory.rglob('*') if path.is_file()}
    require(actual_files == files, 'Unexpected or missing fixture artifacts')
    print(f'Mask references verified: {len(catalog)} cases, {frames} frames, 3 explicit reference anomalies.')
    return {'cases': len(catalog), 'frames': frames, 'anomalies': 3, 'files': len(files)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=GOLDEN)
    verify(parser.parse_args().directory)
