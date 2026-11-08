#!/usr/bin/env python3
"""Generate/replay bounded pulse histories; native outputs are never inputs."""
import argparse
from pathlib import Path
import time

import generate
import reference
import trace_oracle
import verify
from reference import ROOT, HERE, canonical, digest, finite


def sources():
    names = ('trace_oracle.py', 'trace_reference.py', 'verify.py', 'stages.py', 'sequences.py',
             'generate.py', 'reference.py', 'probe.praat')
    paths = [*[HERE / name for name in names], ROOT / 'Tools/Reference/common.py',
             ROOT / 'Tools/Reference/setup.py', ROOT / 'Tools/Reference/toolchain.json']
    return {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in paths}


def assemble(case, oracle, record):
    pcm = oracle['inputSamples']
    expected = record['data']['pulseTimesSeconds']
    actual = [p['timeSeconds'] for p in oracle['landmarks']]
    verify.check(len(actual) == len(expected), f'{case["name"]}: oracle/reference raw count differs')
    errors = [abs(a - b) * case['sampleRate'] for a, b in zip(actual, expected)]
    verify.check(max(errors, default=0.) <= trace_oracle.COMPARISON['timeSamples'],
                 f'{case["name"]}: oracle/reference position differs')
    external = {a['pulseIndex']: a['rmsAmplitude'] for a in record['data']['amplitudes']}
    amplitude_errors = []
    for value in oracle['amplitudes']:
        if value['rmsAmplitude'] is None:
            continue
        verify.check(value['pulseIndex'] in external, 'Oracle invented an external amplitude')
        wanted = external[value['pulseIndex']]
        budget = trace_oracle.COMPARISON['amplitudeAbsolute'] + trace_oracle.COMPARISON['amplitudeRelative'] * abs(wanted)
        fraction = abs(value['rmsAmplitude'] - wanted) / budget
        verify.check(fraction <= 1, 'Oracle/reference amplitude differs')
        amplitude_errors.append(fraction)
    comparable = not case['zeroRanges'] and not case['allUnvoiced'] and not case['unvoicedFrames'] and case['gain'] != 0
    source_errors = None
    source_residuals = None
    if comparable:
        known = oracle['knownSourceLandmarks']
        verify.check(len(actual) == len(known), 'Exact-template source pulse count differs')
        source_errors = [abs(pulse - known[i]['timeSeconds']) * case['sampleRate'] for i, pulse in enumerate(actual)]
        source_residuals = [abs((pulse - known[i]['timeSeconds']) * case['sampleRate'] - case['knownSeedBiasSamples'])
                            for i, pulse in enumerate(actual)]
        verify.check(max(source_residuals, default=0.) <= trace_oracle.COMPARISON['timeSamples'],
                     'Exact-template source timing differs')
    body = dict(schemaVersion=1, case=case, oracle=oracle, reference=record,
        independentExternalAmplitudeAudit=generate.amplitude_audit(pcm, case['sampleRate'], record),
        comparison=dict(maximumPositionErrorSamples=max(errors, default=0.),
            amplitudeComparisons=len(amplitude_errors), maximumAmplitudeBudgetFraction=max(amplitude_errors, default=0.),
            knownSourceComparisons=len(source_errors) if source_errors is not None else 0,
            maximumKnownSourceErrorSamples=max(source_errors, default=0.) if source_errors is not None else None,
            declaredSeedBiasSamples=case['knownSeedBiasSamples'],
            maximumKnownSourceResidualSamples=max(source_residuals, default=0.) if source_residuals is not None else None),
        generatorSources=sources(),
        scope='Independent Decimal histories and connected-component eligibility; exact-template source timing; not Gaussian or physiological timing bounds')
    return dict(fixtureIdentity=digest(canonical(body)), **body)


def generate_candidates(output):
    output = Path(output).resolve()
    verify.check(not output.exists() and output.is_relative_to((ROOT / '.build').resolve()),
                 'Use an absent output directory under .build')
    output.mkdir(parents=True)
    files, trials = {}, []
    for case in trace_oracle.cases():
        start = time.perf_counter()
        oracle = trace_oracle.trace(case)
        settings = {k: case[k] for k in ('minimumSeconds', 'maximumSeconds', 'maximumAdjacentFactor')}
        record, wave, pitch, raw = reference.evaluate(oracle['inputSamples'], case['sampleRate'], oracle['pitch'],
            precision=case['inputPrecision'], period_settings=settings)
        payload = assemble(case, oracle, record)
        for suffix, data in {'.json': canonical(payload), '.wav': wave, '.Pitch': pitch, '.raw.txt': raw.encode()}.items():
            name = case['name'] + suffix
            (output / name).write_bytes(data)
            files[name] = digest(data)
        trials.append(dict(name=case['name'], seconds=time.perf_counter() - start))
        print(case['name'], len(oracle['landmarks']), len(oracle['attempts']), oracle['runCount'], flush=True)
    manifest = dict(schemaVersion=1, catalog=trace_oracle.cases(), comparison=trace_oracle.COMPARISON,
                    files=files, generatorSources=sources())
    (output / 'manifest.json').write_bytes(canonical(manifest))
    (output / 'execution.json').write_bytes(canonical(dict(schemaVersion=1, trials=trials,
        scope='Independent history calculation and external processes; not native timing')))
    return manifest


def verify_candidates(directory):
    directory = Path(directory)
    verify.check(directory.is_dir() and not directory.is_symlink(), 'Unsafe/missing history directory')
    manifest = verify.read_json(directory / 'manifest.json')
    verify.check(isinstance(manifest, dict) and
                 set(manifest) == {'schemaVersion', 'catalog', 'comparison', 'files', 'generatorSources'},
                 'Unknown history manifest fields')
    verify.same(manifest['schemaVersion'], 1, 'Unknown history schema')
    cases = trace_oracle.cases()
    verify.same(manifest['catalog'], cases, 'History catalog differs')
    verify.same(manifest['comparison'], trace_oracle.COMPARISON, 'History comparison policy differs')
    verify.same(manifest['generatorSources'], sources(), 'Stale history generator identity')
    names = {c['name'] + s for c in cases for s in ('.json', '.wav', '.Pitch', '.raw.txt')}
    verify.check(isinstance(manifest['files'], dict) and set(manifest['files']) == names,
                 'History manifest coverage differs')
    verify.check({p.name for p in directory.iterdir()} == names | {'manifest.json', 'execution.json'},
                 'History directory coverage differs')
    for name in names:
        verify.check(digest(verify.read_bytes(directory / name)) == manifest['files'][name], 'History artifact hash differs')
    execution = verify.read_json(directory / 'execution.json')
    verify.check(isinstance(execution, dict) and set(execution) == {'schemaVersion', 'trials', 'scope'},
                 'Unknown history execution fields')
    verify.same(execution['schemaVersion'], 1, 'Unknown execution schema')
    verify.same(execution['scope'], 'Independent history calculation and external processes; not native timing',
                'History execution scope differs')
    verify.check(isinstance(execution['trials'], list) and len(execution['trials']) == len(cases),
                 'History execution coverage differs')
    for case, trial in zip(cases, execution['trials']):
        verify.check(isinstance(trial, dict) and set(trial) == {'name', 'seconds'} and trial['name'] == case['name']
            and finite(trial['seconds']) and trial['seconds'] > 0, 'Invalid history execution trial')
    points = attempts = periods = pairs = amplitudes = 0
    for case in cases:
        name, rate, count = (case[k] for k in ('name', 'sampleRate', 'sampleCount'))
        oracle = trace_oracle.trace(case)
        wave = verify.read_bytes(directory / (name + '.wav'))
        pitch = verify.read_bytes(directory / (name + '.Pitch'))
        verify.check(wave == reference.pcm_wave(oracle['inputSamples'], rate), 'History PCM changed')
        verify.check(pitch == reference.encode_pitch(oracle['pitch'], rate, count), 'History F0 changed')
        raw = verify.read_bytes(directory / (name + '.raw.txt')).decode('utf-8')
        settings = {k: case[k] for k in ('minimumSeconds', 'maximumSeconds', 'maximumAdjacentFactor')}
        record = reference.make_record(wave, pitch, raw, oracle['pitch'], rate, count, case['inputPrecision'], settings)
        verify.same(verify.read_json(directory / (name + '.json')), assemble(case, oracle, record),
                    'History differs from independent equations, graph, or raw transcript')
        points += len(oracle['landmarks']); attempts += len(oracle['attempts'])
        periods += sum(not r['rejections'] for r in oracle['periods'])
        pairs += sum(not r['rejections'] for r in oracle['periodPairs'])
        amplitudes += sum(r['rmsAmplitude'] is not None for r in oracle['amplitudes'])
    return dict(cases=len(cases), files=len(names), rawPoints=points, attempts=attempts,
                eligiblePeriods=periods, eligiblePairs=pairs, availableAmplitudes=amplitudes)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    result = verify_candidates(args.directory) if args.verify else generate_candidates(args.directory)
    print(canonical(result if args.verify else dict(cases=len(result['catalog']), files=len(result['files']))).decode())
