#!/usr/bin/env python3
"""Generate independent CPP candidates with a pinned external executable."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

from cpp_catalog import (ROOT, COMPARISON, SEEDS, cases, profiles, resolved_fit,
                         power_cepstrum_text, THEIL_REFERENCE_EXCEPTIONS)
from common import canonical, load_json, number
from setup import verify_tool

HERE = Path(__file__).resolve().parent
LOCK = ROOT / 'Tools/Reference/toolchain.json'
FIELDS = ['slopeDBPerSecond', 'interceptDB', 'cppDB', 'peakDB', 'peakQuefrencySeconds']
FIT_NAMES = {'leastSquares': 'Least squares', 'praat7002Robust': 'Robust',
             'completeTheilSen': 'Robust slow'}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def implementation_hash():
    paths = ['Tools/CPP/cpp_catalog.py', 'Tools/CPP/reference.py', 'Tools/CPP/fit.praat',
             'Tools/Reference/common.py', 'Tools/Reference/setup.py', 'Tools/Reference/toolchain.json']
    return sha(canonical({path: sha((ROOT / path).read_bytes()) for path in paths}))


def parse(raw):
    lines = raw.splitlines()
    if len(lines) != 1:
        raise ValueError('Expected exactly one CPP reference row')
    fields = lines[0].split('\t')
    if len(fields) != 6 or fields[0] != 'cpp-reference-v1':
        raise ValueError('Invalid CPP reference fields')
    values = [number(value) for value in fields[1:]]
    if any(value is None for value in values):
        raise ValueError('Unexpected undefined CPP for finite supported input')
    return dict(zip(FIELDS, values))


def invoke(binary, lock, path, profile, seed, allow_failure=False):
    arguments = [str(path), str(profile['pitchFloorHz']), str(profile['pitchCeilingHz']),
                 profile['interpolation'].capitalize(), str(profile['fitStartSeconds']),
                 str(profile['fitEndSeconds']), FIT_NAMES[profile['fitMethod']], str(seed)]
    result = subprocess.run([str(binary), *lock['options'], str(HERE / 'fit.praat'), *arguments],
        capture_output=True, text=True, encoding='utf-8', timeout=60,
        env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    if result.returncode or result.stderr.strip() or len(result.stdout.encode()) > 4096:
        if allow_failure:
            # Strip checkout-specific paths from retained failure evidence.
            message = result.stderr.replace(str(path), '$INPUT').replace(str(ROOT), '$REPOSITORY')
            return {'seed': seed, 'failure': True, 'exitCode': result.returncode,
                    'stdoutSHA256': sha(result.stdout.encode()),
                    'normalizedStderrSHA256': sha(message.encode()), 'message': message}
        raise ValueError(f'CPP reference failed/warned/exceeded budget: {result.stderr[:400]}')
    return {'seed': seed, 'rawSHA256': sha(result.stdout.encode()), **parse(result.stdout)}


def residual_diagnostics(power, step, fit, slope, intercept):
    residuals = [10 * math.log10(power[i] + 1e-30) - (slope * (i * step) + intercept)
                 for i in range(fit['firstBin'], fit['lastBin'] + 1)]
    return {'rmsDB': math.sqrt(math.fsum(value * value for value in residuals) / len(residuals)),
            'meanDB': math.fsum(residuals) / len(residuals),
            'medianDB': statistics.median(residuals),
            'maximumAbsoluteDB': max(map(abs, residuals))}


def evaluate(case, binary, lock, scratch, calibration=False):
    identity = dict(case)
    power = case['power']
    if any(value is None for value in power):
        if not all(value is None for value in power):
            raise ValueError('Unexpected partially available input cepstrum')
        return {**identity, 'inputSHA256': sha(canonical(power)),
                'upstreamUnavailable': True, 'results': []}
    text = power_cepstrum_text(case)
    path = scratch / (case['name'] + '.PowerCepstrum')
    path.write_bytes(text)
    results = []
    for profile in profiles():
        fit = resolved_fit(profile, len(power), case['quefrencyStepSeconds'])
        if fit['binCount'] < 3:
            raise ValueError('Reference catalog fit requires three points')
        seeds = SEEDS if profile['fitMethod'] == 'completeTheilSen' else SEEDS[:1]
        is_theil = profile['fitMethod'] == 'completeTheilSen'
        known_failure = is_theil and case['name'] == 'very-large-power'
        trials = [invoke(binary, lock, path, profile, seed, calibration or known_failure) for seed in seeds]
        # The independent peak commands do not invoke the fit estimator. Reuse
        # their separately retained results when that estimator crashes.
        peak = next((row['expected'] for row in results
                     if row['profile']['interpolation'] == profile['interpolation']), None)
        results.append(summarize(case, profile, trials, peak, calibration))
    return {**identity, 'inputSHA256': sha(canonical(power)), 'objectSHA256': sha(text),
            'upstreamUnavailable': False, 'results': results}


def summarize(case, profile, trials, independent_peak=None, calibration=False):
    fit = resolved_fit(profile, case['binCount'], case['quefrencyStepSeconds'])
    power = case['power']
    budgets = {'slopeDBPerSecond': COMPARISON['slopeDBPerSecondAbsolute'],
               'interceptDB': COMPARISON['interceptDBAbsolute'],
               'cppDB': COMPARISON['cppDBAbsolute'], 'peakDB': COMPARISON['peakDBAbsolute'],
               'peakQuefrencySeconds': COMPARISON['quefrencySecondsAbsolute']}
    successful = [trial for trial in trials if not trial.get('failure')]
    first = successful[0] if successful else independent_peak
    if first is None:
        raise ValueError('No independent peak evidence')
    for trial in successful:
        trend = trial['slopeDBPerSecond'] * trial['peakQuefrencySeconds'] + trial['interceptDB']
        if abs(trial['cppDB'] - (trial['peakDB'] - trend)) > COMPARISON['cppDBAbsolute']:
            raise ValueError('Independent reference peak/fit/CPP queries disagree')
    expected = {field: first[field] for field in FIELDS}
    is_theil = profile['fitMethod'] == 'completeTheilSen'
    if is_theil:
        # Independently implement the published all-pair mathematical definition.
        # Retained external trial fields are NEVER replaced by this oracle.
        xs = [i * case['quefrencyStepSeconds'] for i in range(fit['firstBin'], fit['lastBin'] + 1)]
        ys = [10 * math.log10(power[i] + 1e-30) for i in range(fit['firstBin'], fit['lastBin'] + 1)]
        slope = statistics.median([(ys[j] - ys[i]) / (xs[j] - xs[i])
            for i in range(len(xs) - 1) for j in range(i + 1, len(xs))])
        intercept = statistics.median([y - slope * x for x, y in zip(xs, ys)])
        expected.update(slopeDBPerSecond=slope, interceptDB=intercept,
                        cppDB=first['peakDB'] - (slope * first['peakQuefrencySeconds'] + intercept))
    expected['backgroundDB'] = expected['slopeDBPerSecond'] * expected['peakQuefrencySeconds'] + expected['interceptDB']
    expected['residuals'] = residual_diagnostics(power, case['quefrencyStepSeconds'], fit,
        expected['slopeDBPerSecond'], expected['interceptDB'])
    compatible = len(successful) == len(trials) and all(
        abs(trial[field] - expected[field]) <= budgets[field] for trial in successful for field in FIELDS)
    known_exception = is_theil and case['name'] in THEIL_REFERENCE_EXCEPTIONS
    if not calibration and known_exception == compatible:
        raise ValueError(f'Unexpected reference compatibility classification: {case["name"]}/{profile["name"]}')
    differences = {field: max((abs(trial[field] - successful[0][field]) for trial in successful), default=0)
                   for field in FIELDS}
    return {'profile': profile, 'effectiveFit': fit, 'expected': expected,
            'expectedFitSource': 'independent-complete-pairwise-median' if is_theil else 'pinned-praat-query',
            'expectedPeakSource': 'pinned-praat-query', 'referenceCompatible': compatible,
            'knownReferenceException': known_exception, 'trials': trials,
            'maximumSeedDifferences': differences}


def generate(output, selected=None, calibration=False):
    output = output.resolve()
    if not output.is_relative_to((ROOT / '.build').resolve()):
        raise ValueError('Generate candidates below .build; promotion is a separate reviewed action')
    if output.exists() and any(output.iterdir()):
        raise ValueError('Candidate directory must be absent or empty')
    lock = load_json(LOCK)
    if platform.python_version() != lock['pythonVersion']:
        raise ValueError('Pinned Python version required')
    binary = verify_tool(ROOT / '.build/reference-tool' / lock['version'] / lock['executablePath'], lock)
    catalog = cases()
    if selected:
        catalog = [case for case in catalog if case['name'] in selected]
        if {case['name'] for case in catalog} != set(selected):
            raise ValueError('Unknown reference case')
    output.mkdir(parents=True, exist_ok=True)
    generator = implementation_hash()
    index = []
    with tempfile.TemporaryDirectory(prefix='cpp-reference-', dir=ROOT / '.build') as temporary:
        scratch = Path(temporary)
        # Independent development subprocesses only; no shared mutable Praat state.
        with ThreadPoolExecutor(max_workers=2) as pool:
            for case, result in zip(catalog, pool.map(lambda case: evaluate(case, binary, lock, scratch, calibration), catalog)):
                record = {'schemaVersion': 1, 'generatorSHA256': generator,
                          'calibrationOnly': calibration,
                          'referenceToolchain': lock, 'comparisonPolicy': COMPARISON, **result}
                data = canonical(record) + b'\n'
                filename = case['name'] + '.json'
                (output / filename).write_bytes(data)
                index.append({'name': case['name'], 'file': filename, 'sha256': sha(data),
                              'upstreamUnavailable': result['upstreamUnavailable']})
                print(f'{case["name"]}: {len(result["results"])} profiles', flush=True)
    manifest = {'schemaVersion': 1, 'calibrationOnly': calibration, 'generatorSHA256': generator, 'referenceToolchain': lock,
                'comparisonPolicy': COMPARISON, 'profiles': profiles(), 'referenceSeeds': SEEDS,
                'theilReferenceExceptions': THEIL_REFERENCE_EXCEPTIONS,
                'cases': index}
    (output / 'manifest.json').write_bytes(canonical(manifest) + b'\n')
    print(f'Generated {len(index)} CPP cases', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', action='append')
    parser.add_argument('--calibrate', action='store_true')
    args = parser.parse_args()
    generate(args.output, args.case, args.calibrate)
