#!/usr/bin/env python3
"""Offline verification of identities, source data, geometry and CPPS relationships."""
import argparse
import math
from pathlib import Path
import re

from catalog import ROOT, COMPARISON, cases, object_text, pcm, power, encoded_pcm
from common import canonical, load_json
from reference import implementation_hash, oracle_fraction, sha, STAGES


def check(condition, message):
    if not condition: raise ValueError(message)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def verify_record(record, case):
    check(set(record) == {'case', 'input', 'comparisonPolicy', 'referenceOutputSHA256', 'data',
                         'independentOracleMaximumBudgetFraction'}, 'Unknown/missing record fields')
    check(record['case'] == case and record['comparisonPolicy'] == COMPARISON, 'Catalog/budget differs')
    check(re.fullmatch('[0-9a-f]{64}', record['referenceOutputSHA256']) is not None, 'Invalid reference receipt')
    source, p, data = case['source'], case['profile'], record['data']
    check(set(data) == {'axes', 'cppsDB', 'matrixColumns', 'matrices', 'metrics'}, 'Unknown data fields')
    isolated = source['kind'] == 'power-object'
    if isolated:
        check(record['input'] == {'encodedSHA256': sha(object_text(case))}, 'Constructed input differs')
        frames, bins, first, qstep = source['frameCount'], source['binCount'], source['firstCenter'], source['qStep']
    else:
        _, input_record = pcm(case)
        check(record['input'] == {**input_record, 'encodedSHA256': sha(encoded_pcm(case))},
              'Independently governed PCM input differs')
        if 'missingAcquisition' in source:
            samples, _ = pcm(case)
            missing = source['missingAcquisition']
            check(all(value == 0 for value in samples[missing['startSample']:missing['startSample']+missing['sampleCount']]),
                  'Known corpus dropout transformation differs')
        rate = 2 * p['maximumFrequencyHz']
        count = math.floor(input_record['sampleCount'] / input_record['sampleRate'] * rate + .5)
        width = 6 / p['constructionFloorHz']
        # Multiplication by the sampled grid step is part of the pinned operation
        # order; division invents a different frame at binary64 boundaries.
        frames = math.floor((count * (1 / rate) - width) / p['hopSeconds']) + 1
        first = (input_record['sampleCount'] / input_record['sampleRate'] - (frames-1)*p['hopSeconds']) / 2
        transform = 1 << (math.floor(width * rate + .5) - 1).bit_length()
        bins, qstep = transform//2+1, 1/rate
    expected_axes = {'frameCount': frames, 'binCount': bins, 'firstCenterSeconds': first,
                     'hopSeconds': p['hopSeconds'], 'quefrencyStepSeconds': qstep}
    check(set(data['axes']) == set(expected_axes), 'Axis keys differ')
    for key, value in expected_axes.items():
        check(finite(data['axes'][key]) and abs(data['axes'][key]-value) <=
              (0 if key in ('frameCount', 'binCount') else COMPARISON['axisAbsolute']), 'Axis geometry differs')
    columns = list(range(frames)) if isolated else sorted({0, frames//2, frames-1})
    check(data['matrixColumns'] == columns, 'Matrix coverage differs')
    check(set(data['matrices']) == set(STAGES) and set(data['metrics']) == set(STAGES), 'Stage coverage differs')
    for stage in STAGES:
        values, rows = data['matrices'][stage], data['metrics'][stage]
        check(len(values) == bins*len(columns), 'Matrix shape differs')
        # All cases in this fixed catalog have finite external output. A new
        # undefined case needs an explicit catalog/availability policy change.
        check(all(finite(v) and v >= 0 for v in values), 'Invalid/undefined power value')
        check(len(rows) == frames, 'Frame count differs')
        for index, row in enumerate(rows):
            check(len(row) == 6 and all(finite(v) for v in row), 'Invalid/undefined CPP metrics')
            check(row[0] is not None and abs(row[0]-(first+index*p['hopSeconds'])) <= COMPARISON['axisAbsolute'],
                  'Frame time differs')
            if all(v is not None for v in row):
                check(abs(row[5]-(row[3]-row[1]*row[4]-row[2])) <= COMPARISON['decibelAbsolute'],
                      'CPP peak/background relationship differs')
                check(1/p['pitchCeilingHz']-qstep <= row[4] <= 1/p['pitchFloorHz']+qstep,
                      'Peak lies outside search bounds')
    scalar = data['cppsDB']
    check(finite(scalar), 'Invalid/undefined aggregate')
    cpp = [row[-1] for row in data['metrics']['3']]
    if all(v is not None for v in cpp):
        check(scalar is not None and abs(scalar-math.fsum(cpp)/frames) <= COMPARISON['decibelAbsolute'],
              'Aggregate differs from equal frame mean')
    if isolated:
        check(data['matrices']['1'] == power(case), 'External input differs from original equation')
    check(record['independentOracleMaximumBudgetFraction'] == oracle_fraction(case, data),
          'Independent integration receipt differs')


def verify(directory):
    directory = Path(directory)
    manifest_path = directory/'manifest.json'
    manifest = load_json(manifest_path)
    check(set(manifest) == {'schemaVersion', 'toolchain', 'generatorSHA256', 'pythonVersion',
        'seed', 'comparisonPolicy', 'catalog', 'files', 'partialCatalog'}, 'Unknown/missing manifest fields')
    check(manifest_path.read_bytes() == canonical(manifest), 'Manifest is not canonical')
    check(manifest['schemaVersion'] == 1 and manifest['partialCatalog'] is False, 'Incomplete catalog')
    lock = load_json(ROOT/'Tools/Reference/toolchain.json')
    check(manifest['toolchain'] == lock and manifest['pythonVersion'] == lock['pythonVersion'], 'Toolchain differs')
    check(manifest['generatorSHA256'] == implementation_hash() and manifest['seed'] == 7002, 'Generator identity differs')
    check(manifest['comparisonPolicy'] == COMPARISON and manifest['catalog'] == cases(), 'Policy/catalog differs')
    expected = {case['name']+'.json' for case in cases()}
    check(set(manifest['files']) == expected, 'Manifest file coverage differs')
    check({path.name for path in directory.iterdir()} == expected | {'manifest.json'}, 'Directory file coverage differs')
    for case in cases():
        filename = case['name']+'.json'
        path = directory/filename
        check(path.stat().st_size <= 16*1024*1024, 'Record exceeds byte budget')
        data = path.read_bytes()
        check(sha(data) == manifest['files'][filename], 'Record digest differs')
        record = load_json(path)
        check(data == canonical(record), 'Record is not canonical')
        verify_record(record, case)
    return len(expected)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=ROOT/'Tests/HDXLVoiceProcessingTests/Fixtures/CPPS')
    args = parser.parse_args()
    print('Verified CPPS cases:', verify(args.directory))
