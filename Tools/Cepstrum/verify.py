#!/usr/bin/env python3
"""Offline cepstral fixture identity, finite-stage and reference-route verification."""
import argparse
import math
from pathlib import Path
import struct

from cepstrum_catalog import ROOT, STAGES, COMPARISON, cases, source_samples, float64_wave
from reference import LOCK, compare_routes, implementation_hash, sha
from common import load_json

GOLDEN = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/Cepstrum'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def finite(value):
    return type(value) in (float, int) and math.isfinite(value)


def digest(value):
    return type(value) is str and len(value) == 64 and all(x in '0123456789abcdef' for x in value)


def verify(directory=GOLDEN):
    directory = Path(directory).resolve()
    require(not (directory / 'manifest.json').is_symlink(), 'Manifest must not be a symbolic link')
    manifest = load_json(directory / 'manifest.json')
    require(set(manifest) == {'schemaVersion', 'calibrationOnly', 'generatorSHA256',
        'referenceToolchain', 'comparisonPolicy', 'cases'}, 'Unknown or missing manifest field')
    lock = load_json(LOCK)
    generator = implementation_hash()
    require(type(manifest['schemaVersion']) is int and manifest['schemaVersion'] == 1 and manifest['calibrationOnly'] is False,
            'Unapproved calibration or unknown manifest version')
    require(manifest['generatorSHA256'] == generator and manifest['referenceToolchain'] == lock
            and manifest['comparisonPolicy'] == COMPARISON, 'Stale reference implementation/toolchain/budgets')
    catalog = cases()
    require([r['name'] for r in manifest['cases']] == [r['name'] for r in catalog], 'Case coverage changed')
    expected_files = {'manifest.json'} | {case['name'] + '.json' for case in catalog}
    require({p.name for p in directory.iterdir()} == expected_files, 'Unexpected or missing fixture file')
    counts = {'cases': 0, 'frames': 0, 'deepMinimumFrames': 0, 'undefinedCepstralBins': 0}
    for item, case in zip(manifest['cases'], catalog):
        name = case['name']
        require(set(item) == {'name', 'path', 'sha256'} and item['path'] == name + '.json', 'Unsafe case path')
        path = directory / item['path']
        require(not path.is_symlink() and digest(item['sha256']) and sha(path.read_bytes()) == item['sha256'], 'Fixture hash mismatch')
        record = load_json(path)
        require(set(record) == {'schemaVersion', 'calibrationOnly', 'case', 'input', 'axes', 'frames',
            'intervalReferenceSHA256', 'generatorSHA256', 'referenceToolchain', 'stages', 'comparisonPolicy'}, 'Unknown or missing record field')
        require(type(record['schemaVersion']) is int and record['schemaVersion'] == 1 and record['calibrationOnly'] is False and record['case'] == case,
                'Fixture recipe or approval mismatch')
        require(record['generatorSHA256'] == generator and record['referenceToolchain'] == lock
                and record['stages'] == STAGES and record['comparisonPolicy'] == COMPARISON,
                'Fixture stage/provenance/budget mismatch')
        require(digest(record['intervalReferenceSHA256']), 'Invalid reference-output digest')
        samples, rate = source_samples(case)
        require(record['input'] == {'sampleRate': rate, 'sampleCount': len(samples),
            'peakMagnitude': max(map(abs, samples)),
            'normalizedFloat64LESHA256': sha(struct.pack(f'<{len(samples)}d', *samples)),
            'encodedReferenceInputSHA256': sha(float64_wave(samples, rate)),
            'samples': samples if 'path' not in case['source'] else None}, 'Reference input identity mismatch')
        axes = record['axes']
        fs = 2 * case['maximumFrequencyHz']; dt = 1 / fs
        output_count = len(samples) if fs == rate else math.floor(len(samples) / rate * fs + .5)
        x1 = .5 * dt if fs == rate or fs == 2 * rate else .5 * (len(samples) / rate - (output_count - 1) / fs)
        width = 2 * (3 / case['pitchFloorHz'])
        m = math.floor(width / dt + .5); n = max(2, 1 << (m - 1).bit_length()); bins = n // 2 + 1
        count = math.floor((output_count * dt - width) / case['hopSeconds']) + 1
        first = x1 - .5 * dt + .5 * output_count * dt - .5 * count * case['hopSeconds'] + .5 * case['hopSeconds']
        expected_axes = {'frameCount': count, 'firstCenterSeconds': first, 'hopSeconds': case['hopSeconds'],
            'quefrencyBinCount': bins, 'quefrencyOriginSeconds': 0, 'quefrencyStepSeconds': dt,
            'frequencyStepHz': fs / n, 'transformLength': n, 'physicalWidthSeconds': width,
            'resampled': {'sampleCount': output_count, 'sampleRate': fs, 'firstCenterSeconds': x1,
                          'domainEndSeconds': len(samples) / rate}}
        require(axes == expected_axes, 'Reference axes differ from the pinned geometry')
        selected = [0] if count == 1 else [(count - 1) * j // (min(count, 5) - 1) for j in range(min(count, 5))]
        require([f['index'] for f in record['frames']] == selected, 'Selected frame coverage mismatch')
        for frame in record['frames']:
            require(set(frame) == {'index', 'centerSeconds', 'firstResampledIndex', 'observedFrameCount',
                'transformLength', 'frameMean', 'conditioned', *STAGES, 'intervalPowerCepstrum',
                'routeComparison', 'mathematicalWindowMaximumDifference', 'frameReferenceSHA256',
                'referenceLogRange', 'comparisonClass'}, 'Unknown or missing frame field')
            center = math.fma(frame['index'], case['hopSeconds'], first)
            start = math.floor(((center - width / 2) - x1) / dt + 1 + .5) - 1
            require(frame['centerSeconds'] == center and frame['firstResampledIndex'] == start
                and frame['observedFrameCount'] == m and frame['transformLength'] == n,
                'Frame grid differs from fused/nearest-sample contract')
            require(digest(frame['frameReferenceSHA256']), 'Invalid intermediate reference digest')
            conditioned = frame['conditioned']
            require(len(conditioned) == m and all(map(finite, conditioned)), 'Invalid conditioned input')
            mean = math.fsum(conditioned) / m
            require(frame['frameMean'] == mean, 'Invalid frame mean')
            coefficients = [(math.exp(-12 * ((2 * j + 1 - m) / m)**2) - math.exp(-12))
                / (1 - math.exp(-12)) for j in range(m)]
            mathematical_window = [(x - mean) * w for x, w in zip(conditioned, coefficients)] + [0.] * (n - m)
            for stage in STAGES:
                values = frame[stage]
                require(len(values) == (n if stage == 'windowed' else bins), 'Incorrect intermediate length')
                require(all(x is None or finite(x) for x in values), 'Nonfinite intermediate sentinel')
            require(all(map(finite, frame['windowed'])) and frame['windowed'][m:] == [0.] * (n - m), 'Invalid window padding')
            difference = max(abs(a-b) for a,b in zip(mathematical_window, frame['windowed']))
            # Floating evaluation order differs by a few ulps between public commands
            # and this independently evaluated Gaussian equation.
            scale = max(map(abs, conditioned)) or 1
            require(difference <= 2e-14 * scale and frame['mathematicalWindowMaximumDifference'] == difference, 'Window equation mismatch')
            for k in range(bins):
                re, im, power, logarithm = (frame[s][k] for s in ('spectrumReal', 'spectrumImaginary', 'powerSpectrum', 'logPowerSpectrum'))
                require(all(map(finite, (re, im, power))) and power >= 0, 'Invalid spectrum')
                require(k not in (0, bins - 1) or im == 0, 'Nonreal spectral endpoint')
                require(math.isclose(power, 2 * (re*re + im*im), rel_tol=1e-12, abs_tol=0), 'Power convention changed')
                operand = power + (0 if k == bins - 1 else 1e-300)
                require(logarithm is None if operand == 0 else logarithm is not None and abs(logarithm - math.log(operand)) <= 1e-12,
                    'Log floor convention changed')
                signed, cepstrum = frame['signedCepstrum'][k], frame['powerCepstrum'][k]
                singular = frame['logPowerSpectrum'][-1] is None
                require(signed is None and cepstrum is None if singular else signed is not None and cepstrum is not None
                    and cepstrum >= 0 and math.isclose(cepstrum, signed*signed, rel_tol=1e-12, abs_tol=0), 'Cepstral square/status mismatch')
            logs = [x for x in frame['logPowerSpectrum'] if x is not None]
            log_range = max(logs) - min(logs)
            classification = 'deepMinimum' if log_range >= COMPARISON['deepMinimumLogRange'] else 'ordinary'
            require(frame['referenceLogRange'] == log_range and frame['comparisonClass'] == classification, 'Numerical conditioning classification changed')
            comparison = compare_routes(frame['powerCepstrum'], frame['intervalPowerCepstrum'])
            require(comparison == frame['routeComparison'] and not comparison['availabilityDisagreements']
                    and comparison['maximumToleranceFraction'] <= 1, 'Independent reference routes disagree')
            counts['frames'] += 1; counts['deepMinimumFrames'] += classification == 'deepMinimum'
            counts['undefinedCepstralBins'] += comparison['undefinedBins']
        counts['cases'] += 1
    return counts


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=GOLDEN)
    args = parser.parse_args()
    print(verify(args.directory))
