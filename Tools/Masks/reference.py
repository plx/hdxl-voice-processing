#!/usr/bin/env python3
"""Generate independently reproducible masking candidates below .build only."""
import argparse
import hashlib
import math
import os
from pathlib import Path
import platform
import re
import struct
import subprocess
import tempfile

from catalog import ROOT, COMPARISON, cases, source_samples, wave64
from common import canonical, load_json
from setup import verify_tool
import oracle

HERE = Path(__file__).resolve().parent
LOCK = ROOT / 'Tools/Reference/toolchain.json'
MAX_BYTES = 32 * 1024 * 1024
MAX_CELLS = 1_000_000


def sha(data):
    return hashlib.sha256(data).hexdigest()


def implementation_hash():
    paths = ['Tools/Masks/catalog.py', 'Tools/Masks/reference.py', 'Tools/Masks/oracle.py',
             'Tools/Masks/speech-activity.praat', 'Tools/Reference/common.py',
             'Tools/Reference/setup.py', 'Tools/Reference/toolchain.json']
    return sha(canonical({path: sha((ROOT/path).read_bytes()) for path in paths}))


def finite(text):
    value = float(text)
    if not math.isfinite(value): raise ValueError('Nonfinite reference output')
    return value


def integer(text, maximum):
    value = finite(text)
    if not value.is_integer() or not 1 <= value <= maximum:
        raise ValueError('Invalid reference dimension')
    return int(value)


def matrix(raw, class_name):
    lines = raw.decode('utf-8').splitlines()
    if len(lines) < 13 or lines[:3] != ['File type = "ooTextFile"', f'Object class = "{class_name} 2"', '']:
        raise ValueError('Unexpected short-text matrix header')
    header = lines[3:13]
    columns, rows = integer(header[2], 10000), integer(header[7], 8192)
    if columns*rows > MAX_CELLS or len(lines) != 13 + columns*rows:
        raise ValueError('Matrix scalar count exceeds budget or does not match dimensions')
    xmin,xmax,hop,first,ymin,ymax,step,yfirst = [finite(header[i]) for i in (0,1,3,4,5,6,8,9)]
    if xmin >= xmax or ymin >= ymax or hop <= 0 or step <= 0:
        raise ValueError('Invalid reference axes')
    values = [finite(value) for value in lines[13:]]
    return {'minimumTime': xmin, 'maximumTime': xmax, 'frameCount': columns, 'hop': hop,
            'firstCenter': first, 'frequencyBinCount': rows, 'frequencyStep': step,
            'firstFrequency': yfirst, 'maximumFrequency': ymax}, [values[i*columns:(i+1)*columns] for i in range(rows)]


def textgrid(raw):
    lines = raw.decode('utf-8').splitlines()
    if lines[:3] != ['File type = "ooTextFile"', 'Object class = "TextGrid"', '']:
        raise ValueError('Unexpected TextGrid header')
    xmin, xmax = finite(lines[3]), finite(lines[4])
    if lines[5] != '<exists>' or xmin != 0 or xmax <= 0:
        raise ValueError('Unexpected TextGrid domain')
    count = integer(lines[6], 3)
    index = 7
    tiers = []
    for _ in range(count):
        if lines[index] != '"IntervalTier"' or lines[index+1] not in ('"VAD"', '"silences"', '"union"'):
            raise ValueError('Unknown reference tier')
        name = lines[index+1][1:-1]
        if finite(lines[index+2]) != xmin or finite(lines[index+3]) != xmax:
            raise ValueError('Tier domain mismatch')
        intervals = integer(lines[index+4], 20000)
        index += 5
        parts = []
        cursor = xmin
        for _ in range(intervals):
            start, end = finite(lines[index]), finite(lines[index+1])
            label = lines[index+2]
            if start != cursor or end <= start or end > xmax or label not in ('"speech"', '"non-speech"'):
                raise ValueError('Invalid interval partition')
            parts.append({'startSeconds': start, 'endSeconds': end, 'isSpeech': label == '"speech"'})
            cursor = end
            index += 3
        if cursor != xmax: raise ValueError('Incomplete interval partition')
        tiers.append({'name': name, 'intervals': parts})
    if index != len(lines): raise ValueError('Trailing TextGrid data')
    return tiers


def read_bounded(path):
    if path.stat().st_size > MAX_BYTES: raise ValueError('Reference export exceeds byte budget')
    return path.read_bytes()


def invoke(binary, lock, wave, prefix, profile, timeout=60, expect_timeout=False):
    p = profile
    arguments = [wave, prefix, p['hopSeconds'], p['longWindowSeconds'], p['shortWindowSeconds'],
        p['minimumFrequencyHz'], p['maximumFrequencyHz'], p['flatnessThreshold'],
        -50 if p['relativeIntensityThresholdDB'] is None else p['relativeIntensityThresholdDB'],
        p['minimumNonSpeechSeconds'], p['minimumSpeechSeconds']]
    command = [str(binary), *lock['options'], str(HERE/'speech-activity.praat'), *map(str, arguments)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', timeout=timeout,
            env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    except subprocess.TimeoutExpired as error:
        if not expect_timeout or error.stdout != b'stages-complete\n' or error.stderr:
            raise
        return {'timedOut': True, 'timeoutSeconds': timeout, 'completedStages': 'spectrogram-and-flatness'}
    if expect_timeout:
        raise ValueError('Pinned short-interval nontermination was not reproduced')
    warning = result.stderr.strip()
    if result.returncode or result.stdout != 'stages-complete\ncomplete\n':
        raise ValueError(f'Reference failed: {result.returncode}: {result.stderr[:500]}')
    if warning and not re.fullmatch(r'Warning: The loudest and softest part in your sound differ by only [0-9.eE+\-]+ dB\.', warning):
        raise ValueError(f'Unexpected reference warning: {warning[:500]}')
    return {'timedOut': False, 'stdoutSHA256': sha(result.stdout.encode()), 'warning': warning}


def compare(actual, expected, budget):
    if len(actual) != len(expected): raise ValueError('Oracle shape mismatch')
    fraction = max((abs(a-e)/(budget['absolute'] + budget['relative']*abs(e)) for a,e in zip(actual,expected)), default=0)
    if fraction > 1: raise ValueError(f'Independent temporal oracle disagrees: {fraction} budgets')
    return fraction


def evaluate(case, binary, lock, scratch, output):
    samples, rate = source_samples(case)
    encoded = wave64(samples, rate)
    input_path = scratch/'input.wav'
    input_path.write_bytes(encoded)
    prefix = scratch/'result'
    receipt = invoke(binary, lock, input_path, prefix, case['profile'])
    raw = {stage: read_bounded(Path(str(prefix)+'-'+stage+'.txt'))
           for stage in ('spectrogram-before', 'spectrogram-after', 'flatness', 'textgrid')}
    axes, spectra = matrix(raw['spectrogram-before'], 'Spectrogram')
    flat_axes, flat_rows = matrix(raw['flatness'], 'Matrix')
    if flat_axes['frameCount'] != axes['frameCount'] or flat_axes['firstCenter'] != axes['firstCenter'] or len(flat_rows) != 1:
        raise ValueError('Flatness axes differ from the input spectrogram')
    flatness = flat_rows[0]
    math_flatness = oracle.flatness(spectra, axes, case['profile'])
    oracle_fraction = compare(flatness, math_flatness, COMPARISON['temporalFlatness'])
    intensity = oracle.reference_intensity(spectra, axes) if case['profile']['relativeIntensityThresholdDB'] is not None else []
    n = axes['frameCount']
    indices = sorted({0, min(1,n-1), n//4, n//2, 3*n//4, max(0,n-2), n-1})
    retained = [{'frameIndex': index, 'powers': [row[index] for row in spectra]} for index in indices]
    local_path = None
    if 'path' not in case['source']:
        local_path = 'inputs/'+case['name']+'.wav'
        path = output/local_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(encoded)
    return {'name': case['name'], 'source': case['source'], 'profile': case['profile'],
        'input': {'sampleRate': rate, 'sampleCount': len(samples), 'localPath': local_path,
                  'normalizedFloat64LESHA256': sha(struct.pack(f'<{len(samples)}d', *samples)),
                  'encodedReferenceInputSHA256': sha(encoded)},
        'axes': axes, 'spectra': retained, 'flatness': flatness, 'referenceIntensityDB': intensity,
        'intensityExpectedSource': 'independent-piecewise-linear-integration-of-external-spectral-powers',
        'tiers': textgrid(raw['textgrid']), 'externalReceipt': receipt,
        'externalOutputSHA256': {key: sha(value) for key,value in raw.items()},
        'independentFlatnessMaximumBudgetFraction': oracle_fraction}


def anomalies(binary, lock, scratch):
    """Retain known external failures as negative evidence, never numeric success."""
    base = cases()[0]
    records = []
    for name in ('row-one-mutation', 'short-interval-timeout', 'short-interval-early-return'):
        count = 16000 if name == 'row-one-mutation' else 960
        profile = {**base['profile'], 'relativeIntensityThresholdDB': None}
        if name == 'row-one-mutation': profile['minimumFrequencyHz'] = 1.
        if name == 'short-interval-timeout':
            profile.update(flatnessThreshold=1., minimumNonSpeechSeconds=.001)
        case = {'name': name, 'profile': profile,
                'source': {'kind': 'tone-envelope', 'sampleRate': 16000, 'sampleCount': count}}
        samples, rate = source_samples(case)
        encoded = wave64(samples, rate)
        wave = scratch/(name+'.wav')
        wave.write_bytes(encoded)
        prefix = scratch/name
        receipt = invoke(binary, lock, wave, prefix, profile,
                         timeout=5 if name == 'short-interval-timeout' else 60,
                         expect_timeout=name == 'short-interval-timeout')
        raw = {stage: read_bounded(Path(str(prefix)+'-'+stage+'.txt'))
               for stage in ('spectrogram-before', 'spectrogram-after', 'flatness')}
        axes, before = matrix(raw['spectrogram-before'], 'Spectrogram')
        _, after = matrix(raw['spectrogram-after'], 'Spectrogram')
        _, flat_rows = matrix(raw['flatness'], 'Matrix')
        record = {**case, 'encodedInputSHA256': sha(encoded), 'receipt': receipt,
                  'externalOutputSHA256': {key: sha(value) for key,value in raw.items()}}
        if name == 'row-one-mutation':
            changed = [i+1 for i,(a,b) in enumerate(zip(before,after)) if a != b]
            pure = oracle.flatness(before, axes, profile)
            mutated = oracle.flatness(before, axes, profile, emulate_row_one_mutation=True)
            error = max(abs(a-b) for a,b in zip(flat_rows[0],pure))
            fraction = compare(flat_rows[0], mutated, COMPARISON['temporalFlatness'])
            if changed != [1] or error <= 1e-6: raise ValueError('Pinned row-1 anomaly changed')
            record.update(changedSpectrogramRows=changed, immutableInputMaximumAbsoluteDifference=error,
                          mutationOracleMaximumBudgetFraction=fraction, nativeDisposition='invalidConfiguration')
        elif name == 'short-interval-early-return':
            grid = read_bounded(Path(str(prefix)+'-textgrid.txt'))
            tiers = textgrid(grid)
            expected = [{'name': 'VAD', 'intervals': [{'startSeconds': 0., 'endSeconds': .06, 'isSpeech': True}]}]
            if tiers != expected: raise ValueError('Pinned short-input early return changed')
            record.update(tiers=tiers, nativeDisposition='insufficientData')
            record['externalOutputSHA256']['textgrid'] = sha(grid)
        else:
            record['nativeDisposition'] = 'insufficientData'
        records.append(record)
    return {'schemaVersion': 1, 'decisionIssue': 109, 'cases': records}


def generate(output, selected=None):
    output = output.resolve()
    if not output.is_relative_to((ROOT/'.build').resolve()):
        raise ValueError('Generate candidates below .build; promotion is a separate reviewed action')
    if output.exists() and any(output.iterdir()): raise ValueError('Candidate directory must be absent or empty')
    lock = load_json(LOCK)
    if platform.python_version() != lock['pythonVersion']: raise ValueError('Pinned Python version required')
    binary = verify_tool(ROOT/'.build/reference-tool'/lock['version']/lock['executablePath'], lock)
    catalog = cases()
    if selected:
        catalog = [case for case in catalog if case['name'] in selected]
        if {case['name'] for case in catalog} != set(selected): raise ValueError('Unknown reference case')
    output.mkdir(parents=True, exist_ok=True)
    generator = implementation_hash()
    index = []
    with tempfile.TemporaryDirectory(prefix='masks-reference-', dir=ROOT/'.build') as temporary:
        scratch = Path(temporary)
        for case in catalog:
            result = evaluate(case, binary, lock, scratch, output)
            record = {'schemaVersion': 1, 'generatorSHA256': generator,
                      'comparisonPolicy': COMPARISON, 'referenceToolchain': lock, **result}
            data = canonical(record)+b'\n'
            filename = case['name']+'.json'
            (output/filename).write_bytes(data)
            index.append({'name': case['name'], 'file': filename, 'sha256': sha(data)})
            print(f'{case["name"]}: {len(result["flatness"])} frames; oracle {result["independentFlatnessMaximumBudgetFraction"]:.6g} budgets', flush=True)
        negative = None
        if selected is None:
            data = canonical(anomalies(binary, lock, scratch))+b'\n'
            (output/'reference-anomalies.json').write_bytes(data)
            negative = {'file': 'reference-anomalies.json', 'sha256': sha(data)}
            print('Verified all three pinned-reference anomalies', flush=True)
    manifest = {'schemaVersion': 1, 'generatorSHA256': generator, 'referenceToolchain': lock,
                'comparisonPolicy': COMPARISON, 'cases': index, 'negativeCases': negative}
    (output/'manifest.json').write_bytes(canonical(manifest)+b'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', action='append')
    args = parser.parse_args()
    generate(args.output, args.case)
