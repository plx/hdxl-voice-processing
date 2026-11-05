#!/usr/bin/env python3
"""Explicit pinned Praat intermediate generation; no native implementation is used."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tempfile

from cepstrum_catalog import ROOT, STAGES, COMPARISON, cases, float64_wave, prepared_frame, source_samples
from common import canonical, load_json, number
from setup import verify_tool

HERE = Path(__file__).resolve().parent
LOCK = ROOT / 'Tools/Reference/toolchain.json'
# These limits are set before any native cepstrum exists. Independent full-Praat
# and decomposed-Praat routes retain independent commands and arithmetic; report
# their residuals without silently substituting one route for the other.
ROUTE_ABSOLUTE_TOLERANCE = 1e-5
ROUTE_RELATIVE_TOLERANCE = 2e-5


def sha(data):
    return hashlib.sha256(data).hexdigest()


def implementation_hash():
    paths = ['Tools/Cepstrum/cepstrum_catalog.py', 'Tools/Cepstrum/reference.py',
             'Tools/Cepstrum/interval.praat', 'Tools/Cepstrum/frame.praat',
             'Tools/Reference/common.py', 'Tools/Reference/setup.py',
             'Tools/Reference/toolchain.json']
    return sha(canonical({p: sha((ROOT / p).read_bytes()) for p in paths}))


def integer(token):
    if not token.isascii() or not token.isdigit():
        raise ValueError('Invalid nonnegative reference index')
    return int(token)


def finite(token):
    value = number(token)
    if value is None:
        raise ValueError('Required finite reference metadata is undefined')
    return value


def parse_interval(raw, case, input_count, input_rate):
    lines = [line.split('\t') for line in raw.splitlines()]
    if len(lines) < 5 or lines[0] != ['begin', 'cepstral-interval-v1'] or lines[-1] != ['end', 'cepstral-interval-v1']:
        raise ValueError('Missing interval reference delimiters')
    if len(lines[1]) != 6 or lines[1][0] != 'axes':
        raise ValueError('Missing cepstral axes')
    count, first, hop, bins, qstep = (integer(lines[1][1]), finite(lines[1][2]),
        finite(lines[1][3]), integer(lines[1][4]), finite(lines[1][5]))
    if not 1 <= count <= 30000 or not 2 <= bins <= 32769:
        raise ValueError('Cepstrogram reference exceeds bounds')
    cells, centers, resampled, resample_axis = {}, {}, [], None
    for line in lines[2:-1]:
        if len(line) == 3 and line[0] == 'frame-center' and resample_axis is None:
            key = integer(line[1])
            if key in centers: raise ValueError('Repeated frame center')
            centers[key] = finite(line[2])
        elif len(line) == 4 and line[0] == 'cell' and resample_axis is None:
            key = integer(line[1]), integer(line[2])
            if key in cells: raise ValueError('Repeated reference matrix cell')
            cells[key] = number(line[3])
        elif len(line) == 5 and line[0] == 'resampled-axis' and resample_axis is None:
            resample_axis = {'sampleCount': integer(line[1]), 'sampleRate': finite(line[2]),
                             'firstCenterSeconds': finite(line[3]), 'domainEndSeconds': finite(line[4])}
            if not 1 <= resample_axis['sampleCount'] <= 30000:
                raise ValueError('Resample reference exceeds bounds')
        elif len(line) == 3 and line[0] == 'resampled' and resample_axis is not None:
            if integer(line[1]) != len(resampled): raise ValueError('Nonsequential resampled data')
            resampled.append(finite(line[2]))
        else:
            raise ValueError('Malformed or out-of-order interval reference')
    if not resample_axis or len(resampled) != resample_axis['sampleCount']:
        raise ValueError('Incomplete resample coverage')
    rate = 2 * case['maximumFrequencyHz']
    dt = 1 / rate
    duration = len(resampled) * dt
    width = 2 * (3 / case['pitchFloorHz'])
    expected_count = math.floor((duration - width) / case['hopSeconds']) + 1
    expected_first = resample_axis['firstCenterSeconds'] - .5 * dt + .5 * duration - .5 * expected_count * case['hopSeconds'] + .5 * case['hopSeconds']
    m = math.floor(width / dt + .5)
    n = max(2, 1 << (m - 1).bit_length())
    if (resample_axis['sampleRate'] != rate or count != expected_count or bins != n // 2 + 1
            or hop != case['hopSeconds'] or qstep != dt
            or abs(first - expected_first) > 1e-12
            or abs(resample_axis['domainEndSeconds'] - input_count / input_rate) > 1e-12):
        raise ValueError('Reference axes disagree with the pinned recipe')
    exports = min(count, 5)
    selected = [0] if exports == 1 else [(count - 1) * j // (exports - 1) for j in range(exports)]
    if cells.keys() != {(i, k) for i in selected for k in range(bins)}:
        raise ValueError('Incomplete selected-frame coverage')
    if centers.keys() != set(selected) or any(abs(centers[i] - (first + i * hop)) > 1e-12 for i in selected):
        raise ValueError('Missing or inconsistent frame-center coordinates')
    return {'frameCount': count, 'firstCenterSeconds': first, 'hopSeconds': hop,
            'quefrencyBinCount': bins, 'quefrencyOriginSeconds': 0,
            'quefrencyStepSeconds': qstep, 'frequencyStepHz': rate / n,
            'transformLength': n, 'physicalWidthSeconds': width,
            'resampled': resample_axis}, resampled, {i: {'centerSeconds': centers[i], 'power': [cells[i, k] for k in range(bins)]} for i in selected}


def parse_frame(raw, bins, count):
    lines = [line.split('\t') for line in raw.splitlines()]
    if (not lines or lines[0] != ['begin', 'cepstral-frame-v2', str(count)]
            or lines[-1] != ['end', 'cepstral-frame-v2'] or len(lines) != count + 2 * bins + 3
            or lines[count + 1] != ['bins', str(bins)]):
        raise ValueError('Missing or excessive frame reference data')
    names = ('spectrumReal', 'spectrumImaginary', 'powerSpectrum', 'logPowerSpectrum',
             'signedCepstrum', 'powerCepstrum')
    result = {name: [] for name in names}
    windowed = []
    for k, line in enumerate(lines[1:count + 1]):
        if len(line) != 3 or line[:2] != ['windowed', str(k)]:
            raise ValueError('Missing or out-of-order windowed sample')
        windowed.append(finite(line[2]))
    result['windowed'] = windowed + [0.] * (2 * (bins - 1) - count)
    offset = count + 2
    for k, line in enumerate(lines[offset:offset + bins]):
        if len(line) != 6 or line[:2] != ['spectrum', str(k)]:
            raise ValueError('Missing or out-of-order spectrum bin')
        values = [number(x) for x in line[2:]]
        re, im, power, logarithm = values
        if any(x is None for x in (re, im, power)) or power < 0:
            raise ValueError('Nonfinite or negative spectral data')
        if k in (0, bins - 1) and im != 0:
            raise ValueError('Nonreal spectral endpoint')
        if not math.isclose(power, 2 * (re * re + im * im), rel_tol=1e-12, abs_tol=0):
            raise ValueError('Power disagrees with complex spectrum')
        operand = power + (0 if k == bins - 1 else 1e-300)
        if operand == 0:
            if logarithm is not None: raise ValueError('Unfloored zero is not undefined')
        elif logarithm is None or abs(logarithm - math.log(operand)) > 1e-12:
            raise ValueError('Log-power convention changed')
        for name, value in zip(names[:4], values): result[name].append(value)
    unavailable = result['logPowerSpectrum'][-1] is None
    for k, line in enumerate(lines[offset + bins:-1]):
        if len(line) != 4 or line[:2] != ['cepstrum', str(k)]:
            raise ValueError('Missing or out-of-order cepstral bin')
        value, power = map(number, line[2:])
        if unavailable:
            if value is not None or power is not None:
                raise ValueError('Unfloored singularity became a finite cepstrum')
        elif value is None or power is None or power < 0 or not math.isclose(power, value * value, rel_tol=1e-12, abs_tol=0):
            raise ValueError('Power cepstrum disagrees with signed inverse')
        result['signedCepstrum'].append(value)
        result['powerCepstrum'].append(power)
    return result


def compare_routes(actual, expected):
    if len(actual) != len(expected): raise ValueError('Cepstral route coverage differs')
    differences, fractions, availability_disagreements = [], [], 0
    for left, right in zip(actual, expected):
        if left is None or right is None:
            if left != right: availability_disagreements += 1
            continue
        difference = abs(left - right)
        differences.append(difference)
        fractions.append(difference / (ROUTE_ABSOLUTE_TOLERANCE + ROUTE_RELATIVE_TOLERANCE * abs(right)))
    return {'finiteBins': len(differences), 'undefinedBins': len(actual) - len(differences),
            'availabilityDisagreements': availability_disagreements,
            'maximumAbsoluteDifference': max(differences, default=0),
            'maximumToleranceFraction': max(fractions, default=0),
            'absoluteTolerance': ROUTE_ABSOLUTE_TOLERANCE,
            'relativeTolerance': ROUTE_RELATIVE_TOLERANCE}


def invoke(binary, lock, script, arguments):
    result = subprocess.run([str(binary), *lock['options'], str(HERE / script), *map(str, arguments)],
        capture_output=True, text=True, encoding='utf-8', timeout=120,
        env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    if result.returncode or result.stderr.strip() or len(result.stdout.encode()) > 4 * 1024 * 1024:
        raise ValueError(f'Pinned {script} failed, warned, or exceeded its export budget: {result.stderr[:300]}')
    return result.stdout


def generate(output, selected=None, calibration=False):
    output = output.resolve()
    if not output.is_relative_to((ROOT / '.build').resolve()):
        raise ValueError('Candidates must be generated below .build; promotion is a separate reviewed action')
    lock = load_json(LOCK)
    if platform.python_version() != lock['pythonVersion']:
        raise ValueError('Pinned Python version required')
    binary = verify_tool(ROOT / '.build/reference-tool' / lock['version'] / lock['executablePath'], lock)
    if output.exists() and any(output.iterdir()):
        raise ValueError('Candidate output must be absent or empty')
    output.mkdir(parents=True, exist_ok=True)
    selected_cases = [case for case in cases() if selected is None or case['name'] in selected]
    if not selected_cases or selected and {case['name'] for case in selected_cases} != set(selected):
        raise ValueError('Unknown or empty case selection')
    results = []
    with tempfile.TemporaryDirectory(prefix='cepstrum-reference-') as temporary:
        wave = Path(temporary) / 'input.wav'
        frame_wave = Path(temporary) / 'frame.wav'
        for case in selected_cases:
            values, rate = source_samples(case)
            encoded = float64_wave(values, rate)
            wave.write_bytes(encoded)
            raw = invoke(binary, lock, 'interval.praat', [wave, case['pitchFloorHz'],
                case['hopSeconds'], case['maximumFrequencyHz'], case['preEmphasisFromHz']])
            axes, resampled, powers = parse_interval(raw, case, len(values), rate)
            frames = []
            for index, frame_record in powers.items():
                expected = frame_record['power']
                center = frame_record['centerSeconds']
                prepared = prepared_frame(resampled, axes['resampled']['firstCenterSeconds'], case, center)
                frame_wave.write_bytes(float64_wave(prepared['conditioned'], int(axes['resampled']['sampleRate'])))
                raw_frame = invoke(binary, lock, 'frame.praat', [frame_wave])
                stages = parse_frame(raw_frame, axes['quefrencyBinCount'], prepared['observedFrameCount'])
                window_difference = max(abs(a-b) for a,b in zip(prepared['windowed'], stages['windowed']))
                comparison = compare_routes(stages['powerCepstrum'], expected)
                finite_logs = [x for x in stages['logPowerSpectrum'] if x is not None]
                log_range = max(finite_logs) - min(finite_logs)
                if not calibration and (comparison['maximumToleranceFraction'] > 1 or comparison['availabilityDisagreements']):
                    raise ValueError(f"Independent routes differ for {case['name']}, frame {index}: {comparison}")
                frames.append({'index': index, 'centerSeconds': center, **prepared, **stages,
                    'intervalPowerCepstrum': expected, 'routeComparison': comparison,
                    'referenceLogRange': log_range,
                    'comparisonClass': 'deepMinimum' if log_range >= COMPARISON['deepMinimumLogRange'] else 'ordinary',
                    'mathematicalWindowMaximumDifference': window_difference,
                    'frameReferenceSHA256': sha(raw_frame.encode())})
            record = {'schemaVersion': 1, 'calibrationOnly': calibration, 'case': case,
                'input': {'sampleRate': rate, 'sampleCount': len(values),
                    'peakMagnitude': max(map(abs, values)),
                    'normalizedFloat64LESHA256': sha(struct.pack(f'<{len(values)}d', *values)),
                    'encodedReferenceInputSHA256': sha(encoded),
                    'samples': values if 'path' not in case['source'] else None},
                'axes': axes, 'frames': frames, 'intervalReferenceSHA256': sha(raw.encode()),
                'generatorSHA256': implementation_hash(), 'referenceToolchain': lock, 'stages': STAGES,
                'comparisonPolicy': COMPARISON}
            path = output / (case['name'] + '.json')
            path.write_bytes(canonical(record) + b'\n')
            results.append({'name': case['name'], 'path': path.name, 'sha256': sha(path.read_bytes())})
            print(f"reference {case['name']}: {axes['frameCount']} frames, {len(frames)} fully exported", flush=True)
    (output / 'manifest.json').write_bytes(canonical({'schemaVersion': 1, 'calibrationOnly': calibration, 'generatorSHA256': implementation_hash(),
        'referenceToolchain': lock, 'comparisonPolicy': COMPARISON, 'cases': results}) + b'\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', action='append', dest='cases')
    parser.add_argument('--calibrate', action='store_true', help='Retain route discrepancies as explicitly unapproved calibration evidence')
    args = parser.parse_args()
    generate(args.output.resolve(), args.cases, args.calibrate)


if __name__ == '__main__':
    main()
