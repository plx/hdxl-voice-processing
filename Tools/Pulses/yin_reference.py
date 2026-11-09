#!/usr/bin/env python3
"""Separate independent-YIN-to-external-pulse integration evidence, never native answers."""
import argparse
from pathlib import Path
import subprocess
import sys
import time

import reference
import verify
from reference import ROOT, HERE, canonical, digest, finite, load_json

CASES = ('tone-80', 'tone-123.45', 'tone-650', 'harmonic', 'missing-fundamental',
         'chirp', 'octave-jump', 'irregular-pulses', 'breathy', 'silence', 'constant',
         'float32-tone', 'float32-breathy', 'speech-bl01-vowel-a',
         'speech-bl02-consonant-rich', 'speech-bl03-all-voiced')
POLICY = dict(schemaVersion=1, definition='fullSupportRawVoicedYINToPulse-v1',
    frameSelection='complete-support-only', frequencySelection='raw-voiced-only',
    otherStatuses='zero-unvoiced', frameCenter='observed-support-midpoint',
    edgePolicy='retain-unsupported-edges', tracker='disabled',
    scope='Separate estimated-F0 integration, not supplied-oracle-F0 parity or physiological truth')
COMPARISON = dict(frequencyHz=.001, rawPulseTimeSamples=1e-6,
    rawPulseCount='exact', statusesAndFrameGrid='exact',
    amplitudeAbsolute=2e-12, amplitudeRelative=1e-10)

# Run the existing original YIN oracle in an isolated module namespace. Generic
# names such as reference/catalog must not alias the pulse tool's modules.
YIN_SOURCE = '''
import sys
sys.path.insert(0, 'Tools/YIN')
from catalog import ROOT,cases,source_samples
from reference import evaluate,sha
from common import canonical,load_json
case=next(c for c in cases() if c['name']==sys.argv[1])
record,wave=evaluate(case)
path=ROOT/'Tests/HDXLVoiceProcessingTests/Fixtures/YIN'/(case['name']+'.json')
if canonical(load_json(path))!=canonical(record): raise ValueError('Stale independent YIN fixture')
print(canonical(dict(record=record,samples=source_samples(case),fixtureSHA256=sha(path.read_bytes()))).decode())
'''


def sources():
    names = ('yin_reference.py', 'reference.py', 'probe.praat', 'verify.py')
    paths = [*[HERE / name for name in names],
             *[ROOT / 'Tools/YIN' / name for name in ('oracle.py', 'catalog.py', 'reference.py')],
             *[ROOT / 'Tools/Reference' / name for name in ('common.py', 'setup.py', 'toolchain.json')]]
    return {str(p.relative_to(ROOT)): digest(p.read_bytes()) for p in paths}


def input_case(name):
    verify.check(name in CASES, 'Unknown YIN-pulse integration case')
    process = subprocess.run([sys.executable, '-c', YIN_SOURCE, name], cwd=ROOT,
                             capture_output=True, timeout=120)
    verify.check(process.returncode == 0, 'Independent YIN source failed: ' + process.stderr.decode('utf-8'))
    verify.check(len(process.stdout) <= verify.MAX_ARTIFACT_BYTES, 'Oversized YIN source record')
    import json
    source = json.loads(process.stdout)
    record, samples = source['record'], source['samples']
    profile = record['profile']
    rows = [r for r in record['frames'] if r['observedSampleCount'] == r['requiredSampleCount']]
    verify.check(bool(rows), 'No complete YIN frame; integration requires explicit upstream support')
    frequencies = []
    for i, row in enumerate(rows):
        verify.check(row['frameIndex'] == i and row['startSample'] == i * profile['hopLength'],
                     'Nonuniform independent YIN grid')
        frequencies.append(row['candidates'][row['selectedCandidateIndex']]['frequencyHz']
                           if row['status'] == 'voiced' else 0.)
    rate, count = profile['sampleRate'], len(samples)
    pitch = dict(domainEndSeconds=count * (1 / rate),
        firstCenterSeconds=rows[0]['requiredSampleCount'] / (2 * rate),
        stepSeconds=profile['hopLength'] / rate,
        ceilingHz=profile['pitchCeilingHz'], frequenciesHz=frequencies)
    reference.validate_pitch(pitch, rate, count)
    frames = [dict(frameIndex=r['frameIndex'], startSample=r['startSample'],
                   observedSampleCount=r['observedSampleCount'], status=r['status'],
                   reason=r['reason'], frequencyHz=f)
              for r, f in zip(rows, frequencies)]
    return dict(name=name, profile=profile, samples=samples, pitch=pitch, frames=frames,
                source=record['source'], sourceMetrics=record['rawMetrics'],
                yinFixturePath='Tests/HDXLVoiceProcessingTests/Fixtures/YIN/' + name + '.json',
                yinFixtureSHA256=source['fixtureSHA256'])


def assemble(source, external):
    body = dict(schemaVersion=1, name=source['name'], policy=POLICY, comparison=COMPARISON,
                source=source, external=external, generatorSources=sources())
    return dict(fixtureIdentity=digest(canonical(body)), **body)


def generate(output):
    output = Path(output).resolve()
    verify.check(not output.exists() and output.is_relative_to((ROOT / '.build').resolve()),
                 'Use an absent integration output directory under .build')
    output.mkdir(parents=True)
    files, trials = {}, []
    for name in CASES:
        start = time.perf_counter()
        source = input_case(name)
        external, wave, pitch, raw = reference.evaluate(source['samples'], source['profile']['sampleRate'],
            source['pitch'], precision=source['profile']['inputPrecision'])
        for suffix, data in {'.json': canonical(assemble(source, external)), '.wav': wave,
                             '.Pitch': pitch, '.raw.txt': raw.encode()}.items():
            filename = name + suffix
            (output / filename).write_bytes(data)
            files[filename] = digest(data)
        trials.append(dict(name=name, seconds=time.perf_counter() - start))
        print(name, len(source['frames']), external['data']['pulseCount'], flush=True)
    manifest = dict(schemaVersion=1, cases=list(CASES), policy=POLICY, comparison=COMPARISON,
                    files=files, generatorSources=sources())
    (output / 'manifest.json').write_bytes(canonical(manifest))
    (output / 'execution.json').write_bytes(canonical(dict(schemaVersion=1, trials=trials,
        scope='Independent YIN oracle and external pulse execution; not native timing')))
    return dict(cases=len(CASES), files=len(files))


def verify_candidates(directory):
    directory = Path(directory)
    verify.check(directory.is_dir() and not directory.is_symlink(), 'Unsafe integration directory')
    manifest = verify.read_json(directory / 'manifest.json')
    verify.check(isinstance(manifest, dict) and set(manifest) ==
                 {'schemaVersion', 'cases', 'policy', 'comparison', 'files', 'generatorSources'},
                 'Unknown integration manifest fields')
    for key, expected in dict(schemaVersion=1, cases=list(CASES), policy=POLICY,
                              comparison=COMPARISON, generatorSources=sources()).items():
        verify.same(manifest[key], expected, 'Integration manifest changed: ' + key)
    names = {name + suffix for name in CASES for suffix in ('.json', '.wav', '.Pitch', '.raw.txt')}
    verify.check(isinstance(manifest['files'], dict) and set(manifest['files']) == names,
                 'Incomplete integration manifest')
    verify.check({p.name for p in directory.iterdir()} == names | {'manifest.json', 'execution.json'},
                 'Incomplete integration directory')
    for name in names:
        verify.check(digest(verify.read_bytes(directory / name)) == manifest['files'][name],
                     'Integration artifact hash changed')
    frames = pulses = 0
    for name in CASES:
        source = input_case(name)
        rate, count = source['profile']['sampleRate'], len(source['samples'])
        wave, pitch, raw = [verify.read_bytes(directory / (name + suffix)) for suffix in ('.wav', '.Pitch', '.raw.txt')]
        verify.check(wave == reference.pcm_wave(source['samples'], rate), 'Integration waveform changed')
        verify.check(pitch == reference.encode_pitch(source['pitch'], rate, count), 'Integration F0 changed')
        record = reference.make_record(wave, pitch, raw.decode('utf-8'), source['pitch'], rate, count,
                                       source['profile']['inputPrecision'], dict(reference.PERIOD_DEFAULTS))
        verify.same(verify.read_json(directory / (name + '.json')), assemble(source, record),
                    'Integration differs from original YIN or external transcript')
        frames += len(source['frames']); pulses += record['data']['pulseCount']
    execution = verify.read_json(directory / 'execution.json')
    verify.check(isinstance(execution, dict) and set(execution) == {'schemaVersion', 'trials', 'scope'},
                 'Unknown integration execution record')
    verify.same(execution['schemaVersion'], 1, 'Unknown integration execution schema')
    verify.same(execution['scope'], 'Independent YIN oracle and external pulse execution; not native timing',
                'Wrong integration execution scope')
    verify.check(isinstance(execution['trials'], list) and len(execution['trials']) == len(CASES),
                 'Incomplete integration execution trials')
    for name, trial in zip(CASES, execution['trials']):
        verify.check(isinstance(trial, dict) and set(trial) == {'name', 'seconds'} and trial['name'] == name
                     and finite(trial['seconds']) and trial['seconds'] > 0, 'Invalid integration trial')
    return dict(cases=len(CASES), files=len(names), fullYINFrames=frames, rawPulses=pulses)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    result = verify_candidates(args.directory) if args.verify else generate(args.directory)
    print(canonical(result).decode())
