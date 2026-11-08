#!/usr/bin/env python3
"""Offline replay of pulse candidates; never estimates F0 or creates raw answers."""
import argparse
from pathlib import Path

import catalog
import generate
import pitch_reference
import reference
from reference import ROOT, canonical, digest, finite, load_json, pcm_wave

MAX_ARTIFACT_BYTES = 16 * 1024 * 1024
MANIFEST_KEYS = {'schemaVersion', 'catalog', 'files', 'generatorSources', 'toolchain',
                 'amplitudeComparison', 'partialCatalog', 'results'}


def check(condition, message):
    if not condition:
        raise ValueError(message)


def same(actual, expected, message):
    # Canonical comparison keeps booleans distinct from integers and rejects NaN.
    check(canonical(actual) == canonical(expected), message)


def read_bytes(path):
    check(not path.is_symlink() and path.is_file() and path.stat().st_size <= MAX_ARTIFACT_BYTES,
          f'Unsafe, missing or oversized artifact: {path.name}')
    return path.read_bytes()


def read_json(path):
    encoded = read_bytes(path)
    value = load_json(path)
    check(encoded == canonical(value), f'Noncanonical JSON: {path.name}')
    return value


def suffixes(case):
    return ('.json', '.wav', '.Pitch', '.raw.txt') + (
        ('.f0.raw.txt',) if case['pitchSource'] == 'praatRawCC' else ())


def verify_case(directory, case, sources):
    name, rate, count = case['name'], case['sampleRate'], case['sampleCount']
    samples, known = catalog.source(case)
    wave = read_bytes(directory / (name + '.wav'))
    check(wave == pcm_wave(samples, rate), 'Waveform differs from exact catalog source')
    f0_record = None
    if case['pitchSource'] == 'suppliedContour':
        pitch = catalog.supplied_pitch(case)
    else:
        f0_raw = read_bytes(directory / (name + '.f0.raw.txt')).decode('utf-8')
        f0_record = pitch_reference.make_record(wave, f0_raw, rate, count)
        pitch = f0_record['pitch']
    encoded_pitch = read_bytes(directory / (name + '.Pitch'))
    raw = read_bytes(directory / (name + '.raw.txt')).decode('utf-8')
    record = reference.make_record(wave, encoded_pitch, raw, pitch, rate, count,
                                   case['inputPrecision'], dict(reference.PERIOD_DEFAULTS))
    if f0_record is not None:
        same(record['data']['pulseTimesSeconds'], f0_record['directPulseTimesSeconds'],
             'Injected F0 pulse positions differ from the original reference F0 route')
    audit = generate.amplitude_audit(samples, rate, record)
    expected = generate.assemble(case, known, record, f0_record, audit, sources)
    same(read_json(directory / (name + '.json')), expected,
         'Fixture differs from regenerated input, parsed raw output or independent amplitude audit')
    return generate.case_result(case, record, audit)


def verify(directory, *, allow_partial=False):
    directory = Path(directory)
    check(not directory.is_symlink() and directory.is_dir(), 'Unsafe/missing candidate directory')
    manifest = read_json(directory / 'manifest.json')
    check(isinstance(manifest, dict) and set(manifest) == MANIFEST_KEYS, 'Unexpected manifest fields')
    check(type(manifest['schemaVersion']) is int and manifest['schemaVersion'] == 1, 'Unknown schema')
    check(type(manifest['partialCatalog']) is bool, 'Invalid partial-catalog state')
    check(allow_partial or not manifest['partialCatalog'], 'Incomplete pulse catalog')
    check(isinstance(manifest['catalog'], list) and bool(manifest['catalog']), 'Empty/invalid catalog')
    cases = catalog.cases()
    if manifest['partialCatalog']:
        selected = manifest['catalog']
        check(all(isinstance(c, dict) and type(c.get('name')) is str for c in selected),
              'Invalid selected case')
        names = [c['name'] for c in selected]
        check(len(names) == len(set(names)), 'Repeated selected case')
        cases = [c for c in cases if c['name'] in names]
    same(manifest['catalog'], cases, 'Unknown, reordered or changed catalog case')
    sources = generate.generator_sources()
    same(manifest['generatorSources'], sources, 'Stale generator source identity')
    same(manifest['toolchain'], load_json(ROOT / 'Tools/Reference/toolchain.json'), 'Toolchain differs')
    same(manifest['amplitudeComparison'], generate.AMPLITUDE_BUDGET, 'Amplitude tolerance differs')
    expected_names = {c['name'] + suffix for c in cases for suffix in suffixes(c)}
    check(isinstance(manifest['files'], dict) and set(manifest['files']) == expected_names,
          'Manifest artifact coverage differs')
    check({p.name for p in directory.iterdir()} == expected_names | {'manifest.json', 'execution.json'},
          'Directory artifact coverage differs')
    for name in sorted(expected_names):
        check(digest(read_bytes(directory / name)) == manifest['files'][name], 'Artifact hash differs')
    results = [verify_case(directory, case, sources) for case in cases]
    same(manifest['results'], results, 'Manifest results differ from verified cases')
    execution = read_json(directory / 'execution.json')
    check(isinstance(execution, dict) and set(execution) == {'schemaVersion', 'trials', 'scope'},
          'Unknown execution record fields')
    same(execution['schemaVersion'], 1, 'Unknown execution schema')
    same(execution['scope'],
         'Source generation, external reference processes and independent audit; not native timing',
         'Execution timing scope differs')
    trials = execution['trials']
    check(isinstance(trials, list) and len(trials) == len(cases), 'Execution trial coverage differs')
    for case, trial in zip(cases, trials):
        check(isinstance(trial, dict) and set(trial) == {'name', 'seconds'} and
              trial['name'] == case['name'] and finite(trial['seconds']) and trial['seconds'] > 0,
              'Invalid execution timing or case identity')
    return {'cases': len(cases), 'files': len(expected_names), 'partialCatalog': manifest['partialCatalog'],
            'pulses': sum(r['pulses'] for r in results),
            'amplitudeComparisons': sum(r['amplitudes'] for r in results),
            'maximumAmplitudeBudgetFraction': max(r['amplitudeMaximumBudgetFraction'] for r in results),
            'outsideDomainPoints': sum(r['outsideDomainPoints'] for r in results),
            'manifestSHA256': digest(read_bytes(directory / 'manifest.json')),
            'verification': 'Offline replay; does not authenticate who produced the retained raw transcripts'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--allow-partial', action='store_true')
    args = parser.parse_args()
    print(canonical(verify(args.directory, allow_partial=args.allow_partial)).decode())
