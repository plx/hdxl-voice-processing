#!/usr/bin/env python3
"""Generate bounded independent CPPS candidates in an absent .build directory."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import tempfile

from catalog import ROOT, COMPARISON, cases, object_text, pcm, encoded_pcm
from common import canonical, load_json
from setup import verify_tool
import oracle

HERE = Path(__file__).resolve().parent
LOCK = ROOT / 'Tools/Reference/toolchain.json'
STAGES = ('1', '2', '3')
MAX_BYTES = 32 * 1024 * 1024


def sha(value): return hashlib.sha256(value).hexdigest()


def implementation_hash():
    paths = ['Tools/CPPS/catalog.py', 'Tools/CPPS/reference.py', 'Tools/CPPS/oracle.py',
             'Tools/CPPS/probe.praat', 'Tools/CPPS/pcm.praat', 'Tools/Reference/common.py',
             'Tools/Reference/setup.py', 'Tools/Reference/toolchain.json']
    return sha(canonical({path: sha((ROOT/path).read_bytes()) for path in paths}))


def number(token):
    if token == '--undefined--': return None
    value = float(token)
    if not math.isfinite(value): raise ValueError('Nonfinite reference token')
    return value


def integer(token, maximum):
    if not token.isascii() or not token.isdigit() or not 1 <= int(token) <= maximum:
        raise ValueError('Invalid reference index/dimension')
    return int(token)


def parse(raw, export_all):
    if len(raw.encode()) > MAX_BYTES: raise ValueError('Reference output exceeds byte budget')
    lines = raw.splitlines()
    if len(lines) < 5 or lines[0] != 'begin\tcpps-probe-v1' or lines[-1] != 'end\tcpps-probe-v1':
        raise ValueError('Truncated/unexpected CPPS reference output')
    axes = None
    scalar_seen = False
    metrics = {stage: [] for stage in STAGES}
    cells = {stage: {} for stage in STAGES}
    for line in lines[1:-1]:
        fields = line.split('\t')
        if fields[0] == 'axes' and len(fields) == 6 and axes is None:
            n, bins = integer(fields[1], 30000), integer(fields[2], 8193)
            first, hop, qstep = map(number, fields[3:])
            if any(v is None for v in (first, hop, qstep)) or first < 0 or hop <= 0 or qstep <= 0:
                raise ValueError('Invalid grid geometry')
            axes = {'frameCount': n, 'binCount': bins, 'firstCenterSeconds': first,
                    'hopSeconds': hop, 'quefrencyStepSeconds': qstep}
        elif fields[0] == 'cpps' and len(fields) == 2 and not scalar_seen:
            scalar, scalar_seen = number(fields[1]), True
        elif fields[0] == 'frame' and len(fields) == 9 and fields[1] in STAGES:
            stage = fields[1]
            index = integer(fields[2], 30000)
            if index != len(metrics[stage]) + 1: raise ValueError('Nonsequential frame index')
            metrics[stage].append(list(map(number, fields[3:])))
        elif fields[0] == 'cell' and len(fields) == 5 and fields[1] in STAGES:
            stage = fields[1]
            key = integer(fields[2], 8193) - 1, integer(fields[3], 30000) - 1
            value = number(fields[4])
            if key in cells[stage] or (value is not None and value < 0):
                raise ValueError('Repeated/negative power cell')
            cells[stage][key] = value
        else: raise ValueError('Unexpected reference field')
    if axes is None or not scalar_seen: raise ValueError('Missing axes/scalar')
    n, bins = axes['frameCount'], axes['binCount']
    columns = list(range(n)) if export_all else sorted({0, n//2, n-1})
    if len(columns) * bins > 100_000: raise ValueError('Matrix scalar budget exceeded')
    expected = {(row, col) for row in range(bins) for col in columns}
    for stage in STAGES:
        if set(cells[stage]) != expected or len(metrics[stage]) != n:
            raise ValueError('Incomplete matrix/frame coverage')
        for index, row in enumerate(metrics[stage]):
            time = axes['firstCenterSeconds'] + index * axes['hopSeconds']
            if row[0] is None or abs(row[0]-time) > COMPARISON['axisAbsolute']:
                raise ValueError('Frame time differs from grid')
            if all(value is not None for value in row):
                if abs(row[5] - (row[3] - row[1]*row[4] - row[2])) > COMPARISON['decibelAbsolute']:
                    raise ValueError('Independent CPP components disagree')
    values = [row[-1] for row in metrics['3']]
    if scalar is not None and all(value is not None for value in values):
        if abs(scalar - math.fsum(values)/n) > COMPARISON['decibelAbsolute']:
            raise ValueError('Scalar differs from equal frame mean')
    return {'axes': axes, 'cppsDB': scalar, 'matrixColumns': columns,
            'matrices': {stage: [cells[stage][row, col] for row in range(bins) for col in columns]
                         for stage in STAGES}, 'metrics': metrics}


def oracle_fraction(case, data):
    if case['source']['kind'] != 'power-object': return None
    n, bins = data['axes']['frameCount'], data['axes']['binCount']
    source, profile = case['source'], case['profile']
    original = data['matrices']['1']
    if any(value is None for value in original): raise ValueError('Undefined constructed input')
    metrics = data['metrics']['1']
    prepared = [math.exp(max(0, 10*math.log10(value + 1e-30)
        - (metrics[i % n][1]*(i//n*source['qStep']) + metrics[i % n][2])) * math.log(10)/10)
        for i, value in enumerate(original)] if profile['subtractTrendBeforeSmoothing'] else original
    smoothed = oracle.smooth(prepared, n, bins, profile['timeWindowSeconds'],
        profile['quefrencyWindowSeconds'], profile['hopSeconds'], source['qStep'],
        source['firstCenter'], source['duration'])
    fractions = []
    budget = COMPARISON['power']
    for stage, expected in [('2', prepared), ('3', smoothed)]:
        actual = data['matrices'][stage]
        if any(value is None for value in actual): raise ValueError('Undefined smoothing probe')
        fractions.append(max(abs(a-e)/(budget['absolute'] + budget['relative']*abs(e))
                             for a, e in zip(actual, expected)))
    result = max(fractions)
    if result > 1: raise ValueError('Independent basis integration disagrees with external output')
    return result


def evaluate(case, binary, lock, scratch):
    profile = case['profile']
    path = scratch / 'input.PowerCepstrogram'
    common = [profile['timeWindowSeconds'], profile['quefrencyWindowSeconds'],
              'yes' if profile['subtractTrendBeforeSmoothing'] else 'no', profile['pitchTolerance']]
    isolated = case['source']['kind'] == 'power-object'
    if isolated:
        encoded = object_text(case)
        path.write_bytes(encoded)
        identity = {'encodedSHA256': sha(encoded)}
        arguments = [HERE/'probe.praat', path, *common, 'yes']
    else:
        _, record = pcm(case)
        input_path = scratch / 'input.wav'
        encoded = encoded_pcm(case)
        input_path.write_bytes(encoded)
        identity = {**record, 'encodedSHA256': sha(encoded)}
        arguments = [HERE/'pcm.praat', input_path, path, HERE/'probe.praat',
                     profile['constructionFloorHz'], profile['hopSeconds'], profile['maximumFrequencyHz'],
                     profile['preEmphasisFromHz'], *common]
    completed = subprocess.run([str(binary), *lock['options'], *map(str, arguments)],
        capture_output=True, text=True, encoding='utf-8', timeout=180,
        env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
    if completed.returncode or completed.stderr.strip():
        raise ValueError(f'Reference failed ({completed.returncode}): {completed.stderr[:1000]}')
    data = parse(completed.stdout, isolated)
    return {'case': case, 'input': identity, 'comparisonPolicy': COMPARISON,
            'referenceOutputSHA256': sha(completed.stdout.encode()), 'data': data,
            'independentOracleMaximumBudgetFraction': oracle_fraction(case, data)}


def generate(output, selected=None):
    output = Path(output).resolve()
    if output.exists() or not output.is_relative_to((ROOT/'.build').resolve()):
        raise ValueError('Use an absent candidate directory under .build')
    lock = load_json(LOCK)
    binary = verify_tool(ROOT/'.build/reference-tool'/lock['version']/lock['executablePath'], lock)
    catalog = cases()
    if selected:
        catalog = [case for case in catalog if case['name'] in selected]
        if len(catalog) != len(set(selected)): raise ValueError('Unknown/repeated requested case')
    output.mkdir(parents=True)
    files = {}
    with tempfile.TemporaryDirectory(prefix='cpps-', dir=ROOT/'.build') as directory:
        for case in catalog:
            record = evaluate(case, binary, lock, Path(directory))
            filename = case['name'] + '.json'
            data = canonical(record)
            (output/filename).write_bytes(data)
            files[filename] = sha(data)
            print(case['name'], record['data']['cppsDB'], flush=True)
    manifest = {'schemaVersion': 1, 'toolchain': lock, 'generatorSHA256': implementation_hash(),
        'pythonVersion': platform.python_version(), 'seed': 7002, 'comparisonPolicy': COMPARISON,
        'catalog': catalog, 'files': files, 'partialCatalog': bool(selected)}
    (output/'manifest.json').write_bytes(canonical(manifest))
    print('CPPS_CANDIDATES_COMPLETE', len(files), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--case', action='append')
    args = parser.parse_args()
    generate(args.output, args.case)
