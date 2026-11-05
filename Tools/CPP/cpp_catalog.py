"""Original CPP probes and inputs from independently generated power cepstra."""
import hashlib
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Tools/Reference'))
from common import load_json

# Frozen before the native CPP implementation. These compare the same input bins,
# not differing FFT/conditioning implementations. PCM comparisons have separate
# propagated/empirical budgets and may not inherit these isolated-kernel limits.
COMPARISON = {'schemaVersion': 1, 'cppDBAbsolute': 1e-8,
              'peakDBAbsolute': 1e-8, 'quefrencySecondsAbsolute': 1e-12,
              'interceptDBAbsolute': 1e-8, 'slopeDBPerSecondAbsolute': 1e-6,
              'residualDBAbsolute': 1e-8}
SEEDS = [7002, 271828, 314159]
METHODS = ['leastSquares', 'praat7002Robust', 'completeTheilSen']
INTERPOLATIONS = ['none', 'parabolic']
# Independently audited before native comparisons, decision #107. The pinned
# randomized reference does not reliably return the complete pairwise median on
# these constructed inputs. This explicit allowlist is not a tolerance relaxation.
THEIL_REFERENCE_EXCEPTIONS = [
    'flat-background', 'lower-search-edge', 'near-floor', 'near-tied-plateau',
    'outlier-background', 'plateau-2', 'plateau-5', 'plateau-8', 'single-broad',
    'single-sharp', 'straight-background', 'two-peaks-close', 'two-peaks-far',
    'upper-search-edge', 'very-large-power', 'zero-power',
]


def profiles():
    result = []
    for method in METHODS:
        for interpolation in INTERPOLATIONS:
            result.append({'name': method + '-' + interpolation,
                           'pitchFloorHz': 60, 'pitchCeilingHz': 330,
                           'interpolation': interpolation,
                           'fitStartSeconds': .001, 'fitEndSeconds': .05,
                           'fitMethod': method, 'trend': 'straight',
                           'powerFloor': 1e-30})
    result.append({**result[3], 'name': 'murton-recipe-praat7-unsmoothed',
                   'fitEndSeconds': 0})
    return result


def constructed_cases():
    n, step = 513, .0001
    def recipe(name, db, **extra):
        return {'name': name, 'binCount': n, 'quefrencyStepSeconds': step,
                'frameConfiguration': {'sampleRate': 10000, 'pitchFloorHz': 60},
                'source': {'kind': 'original-constructed-cepstrum', 'recipe': name},
                'power': [10 ** (value / 10) for value in db], **extra}
    line = [20 - 100 * k * step for k in range(n)]
    result = [recipe('straight-background', line), recipe('flat-background', [20.] * n)]
    for name, centers, width in [
            ('single-sharp', [80], .45), ('single-broad', [80.3], 3),
            ('two-peaks-close', [80, 84], .1), ('two-peaks-far', [80, 96], .1),
            ('lower-search-edge', [31.2], .8), ('upper-search-edge', [165.8], .8),
            ('dense-rhamonics', list(range(35, 170, 5)), .8),
            ('subharmonic-competition', [40, 80, 120, 160], 1.5)]:
        background = [20.] * n if name.startswith('two-peaks') else line
        result.append(recipe(name, [background[k] + sum(
            12 * math.exp(-((k - center) / width) ** 2) for center in centers)
            for k in range(n)]))
    for width in [2, 5, 8]:
        result.append(recipe('plateau-' + str(width),
            [32. if 80 <= k < 80 + width else 20. for k in range(n)]))
    result.append(recipe('outlier-background', [value + (30 if k % 11 == 0 else 0)
                                               for k, value in enumerate(line)]))
    result.append(recipe('dense-ripple', [value + 6 * math.sin(k * .73) + 3 * math.cos(k * .19)
                                        for k, value in enumerate(line)]))
    result.append(recipe('near-tied-plateau', [30 + 1e-12 * (k - 80) if 80 <= k <= 83
                                            else 20 for k in range(n)]))
    result.append(recipe('near-floor', [-310 + 12 * math.exp(-((k - 80.3) / 2) ** 2)
                                      for k in range(n)]))
    result.append(recipe('very-large-power', [3000 - 100 * k * step
        + 12 * math.exp(-((k - 80.3) / 2) ** 2) for k in range(n)]))
    result.append({**recipe('zero-power', [0.] * n), 'power': [0.] * n})
    return result


def cases():
    result = constructed_cases()
    directory = ROOT / 'Tests/HDXLVoiceProcessingTests/Fixtures/Cepstrum'
    # The committed #33 manifest and each file are already provenance-verified.
    # Retain their exact bytes/hash here as a separate input identity.
    for path in sorted(directory.glob('*.json')):
        if path.name == 'manifest.json':
            continue
        data = load_json(path)
        for frame in data['frames']:
            power = frame['intervalPowerCepstrum']
            result.append({'name': path.stem + '-frame-' + str(frame['index']),
                'binCount': len(power), 'quefrencyStepSeconds': data['axes']['quefrencyStepSeconds'],
                'frameConfiguration': {'sampleRate': 2 * data['case']['maximumFrequencyHz'],
                                       'pitchFloorHz': data['case']['pitchFloorHz']},
                'source': {'kind': 'pinned-praat-power-cepstrum',
                    'path': str(path.relative_to(ROOT)),
                    'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                    'manifestSHA256': hashlib.sha256((directory / 'manifest.json').read_bytes()).hexdigest(),
                    'frameIndex': frame['index'], 'comparisonClass': frame['comparisonClass']},
                'power': power})
    return result


def resolved_fit(profile, count, step):
    start, end = profile['fitStartSeconds'], profile['fitEndSeconds']
    maximum = (count - 1) * step
    if start >= end:
        start, end = 0, maximum
    else:
        start, end = max(start, 0), min(end, maximum)
    first, last = max(1, math.ceil(start / step)), min(count - 1, math.floor(end / step))
    return {'domainStartSeconds': start, 'domainEndSeconds': end,
            'firstBin': first, 'lastBin': last, 'binCount': max(0, last - first + 1)}


def power_cepstrum_text(case):
    count, step = case['binCount'], case['quefrencyStepSeconds']
    # Public Praat text object format, not a copy of reference implementation code.
    header = ['File type = "ooTextFile"', 'Object class = "PowerCepstrum 2"', '',
              '0', repr((count - 1) * step), str(count), repr(step), '0',
              '1', '1', '1', '1', '1']
    if any(value is None or not math.isfinite(value) or value < 0 for value in case['power']):
        raise ValueError('Cannot serialize unavailable or invalid input')
    return ('\n'.join(header + [format(value, '.17g') for value in case['power']]) + '\n').encode()
